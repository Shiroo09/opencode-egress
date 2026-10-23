// egress-watch — rotates the egress when OpenCode's free bucket runs out.
//
// OpenCode 2 dropped the V1 plugin hook this repo used, so the rotation moved
// out of the server and watches it over HTTP instead: subscribe to the
// service's event stream, and when a session fails with a quota error, mark the
// current egress spent, rotate the router, and re-send the last user message on
// the fresh IP. Runs for every client of the same service (TUI, OpenChamber).
//
// Discovery: ~/.local/state/opencode/service.json holds {url, password}.
// Run: node scripts/egress-watch.mjs [--verbose]
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HOME = process.env.HOME || process.env.USERPROFILE || os.homedir();
const SERVICE_FILE = path.join(HOME, ".local", "state", "opencode", "service.json");
const LOG_FILE = process.env.EGRESS_WATCH_LOG ||
  path.join(HOME, ".local", "share", "opencode", "logs", "egress-watch.log");
const ROUTER = process.env.EGRESS_ROUTER || "http://127.0.0.1:8899";
const GUARD_MS = 15000;
const ROTATING = new Set();
const LAST = new Map();

// Rendered text varies by client/locale; error.type and action.reason do not.
const PATTERNS = [
  "freeusagelimit", "free usage limit", "free usage exceeded", "quota",
  "rate limit", "rate-limit", "usage limit", "too many requests",
];

const verbose = process.argv.includes("--verbose");

function log(msg) {
  const line = `${new Date().toISOString()} ${msg}\n`;
  if (verbose) process.stdout.write(line);
  try { fs.appendFileSync(LOG_FILE, line); } catch {}
}

const norm = (s) => String(s || "").toLowerCase().replace(/[^a-z0-9]/g, "");

export function isQuotaError(errorType, message) {
  const haystack = norm(`${errorType} ${message}`);
  return PATTERNS.some((p) => haystack.includes(norm(p)));
}

function readService() {
  try {
    const j = JSON.parse(fs.readFileSync(SERVICE_FILE, "utf8"));
    if (!j.url) return null;
    return { url: j.url.replace(/\/+$/, ""), password: j.password || "" };
  } catch {
    return null;
  }
}

const authHeaders = (pw) => ({
  authorization: "Basic " + Buffer.from("opencode:" + pw).toString("base64"),
  "content-type": "application/json",
});

async function api(svc, method, p, body) {
  const res = await fetch(svc.url + p, {
    method,
    headers: authHeaders(svc.password),
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  try { return { status: res.status, data: JSON.parse(text) }; } catch { return { status: res.status, data: text }; }
}

// /status is GET; /next and /exhausted are POST.
async function routerPost(p, body) {
  const get = p === "/status";
  const res = await fetch(ROUTER + p, {
    method: get ? "GET" : "POST",
    headers: { "content-type": "application/json" },
    body: get ? undefined : JSON.stringify(body ?? {}),
  });
  return { status: res.status, data: await res.text() };
}

async function lastUserText(svc, sessionID, apiFn = api) {
  const r = await apiFn(svc, "GET", `/api/session/${sessionID}/message?limit=10`);
  const rows = Array.isArray(r.data?.data) ? r.data.data : [];
  const user = [...rows].reverse().find((m) => m.type === "user");
  return typeof user?.text === "string" && user.text.trim() ? user.text : null;
}

// Exported for the test; the HTTP surface is the contract, not the code shape.
export async function handleFailure(svc, sessionID, errorType, message, deps = {}) {
  const routerPostFn = deps.routerPost || routerPost;
  const apiFn = deps.api || api;
  const now = Date.now();
  if (ROTATING.has(sessionID)) return "busy";
  if (now - (LAST.get(sessionID) ?? 0) < GUARD_MS) return "guarded";

  ROTATING.add(sessionID);
  try {
    let active = null;
    const st = await routerPostFn("/status");
    if (st.status === 200) {
      try { active = JSON.parse(st.data).active ?? null; } catch {}
    }
    if (!active) return "router-down";

    if (active !== "direct") await routerPostFn("/exhausted", { name: active });
    const next = await routerPostFn("/next");
    if (next.status === 409) {
      log(`all egresses spent, leaving the retry to OpenCode (${errorType})`);
      return "exhausted";
    }
    if (next.status !== 200) {
      log(`router /next failed: ${next.status}`);
      return "router-error";
    }
    let to = "?";
    try { to = JSON.parse(next.data).active ?? "?"; } catch {}
    log(`rotated ${active} -> ${to} (${errorType})`);

    const text = await lastUserText(svc, sessionID, apiFn).catch(() => null);
    if (!text) {
      log("no user text to re-send; rotation is enough for a manual retry");
      return "rotated-only";
    }
    const sent = await apiFn(svc, "POST", `/api/session/${sessionID}/prompt`, { text });
    if (sent.status >= 300) {
      log(`re-send failed: ${sent.status}`);
      return "resend-failed";
    }
    log(`re-sent last message on ${to}`);
    return "rotated";
  } finally {
    LAST.set(sessionID, Date.now());
    ROTATING.delete(sessionID);
  }
}

function sessionOf(event) {
  const d = event?.data ?? event?.properties ?? {};
  return d.sessionID || d.session?.id || null;
}

function errorOf(event) {
  const d = event?.data ?? event?.properties ?? {};
  const err = d.error || d.status?.action || {};
  return { type: err.type || err.reason || "", message: err.message || d.status?.message || "" };
}

const FAIL_TYPES = new Set([
  "session.execution.failed", "session.step.failed", "session.status", "session.error",
]);

async function connect(svc) {
  const ctrl = new AbortController();
  const res = await fetch(svc.url + "/api/event", {
    headers: { authorization: authHeaders(svc.password).authorization },
    signal: ctrl.signal,
  });
  if (res.status !== 200) throw new Error(`event stream ${res.status}`);
  log("event stream connected");
  const reader = res.body.getReader();
  const decoder = new TextDecoder();
  let buf = "";
  for (;;) {
    const { value, done } = await reader.read();
    if (done) return;
    buf += decoder.decode(value, { stream: true });
    let i;
    while ((i = buf.indexOf("\n")) >= 0) {
      const line = buf.slice(0, i).trim();
      buf = buf.slice(i + 1);
      if (!line.startsWith("data:")) continue;
      let event;
      try { event = JSON.parse(line.slice(5)); } catch { continue; }
      if (!FAIL_TYPES.has(event.type)) continue;
      const sessionID = sessionOf(event);
      const { type, message } = errorOf(event);
      if (!sessionID || !isQuotaError(type, message)) continue;
      await handleFailure(svc, sessionID, type, message);
    }
  }
}

async function main() {
  for (;;) {
    const svc = readService();
    if (!svc) {
      log(`no service file at ${SERVICE_FILE}; retrying in 10s`);
      await new Promise((r) => setTimeout(r, 10000));
      continue;
    }
    try {
      await connect(svc);
    } catch (err) {
      if (!/AbortError/.test(String(err))) log(`stream dropped: ${err.message}; reconnecting in 3s`);
    }
    await new Promise((r) => setTimeout(r, 3000));
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main();
}
