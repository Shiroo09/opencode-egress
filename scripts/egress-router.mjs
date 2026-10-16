#!/usr/bin/env node
// egress-router.mjs — fixed localhost endpoint for OpenCode with automatic
// failover across N egresses (your VPS tunnels + optionally direct).
//
// OpenCode always points at 127.0.0.1:<router-port>. The router dials the
// currently active upstream for every connection:
//
//   127.0.0.1:8888 (router) -> 127.0.0.1:8891 (ssh -L to vps1 tinyproxy)
//                            -> 127.0.0.1:8892 (ssh -L to vps2 tinyproxy)
//                            -> direct (no proxy, your own address)
//
// Model traffic is TLS inside CONNECT, so the router can not see HTTP 429
// bodies. Two failover paths exist:
//   1. TCP failure (tunnel down / refused): the router advances to the next
//      healthy egress and retries the same connection. Transparent.
//   2. Rate limit ("Free usage exceeded" inside TLS): the OpenCode plugin in
//      ../plugins/egress-rotate marks the egress exhausted via the control
//      API and rotates. The next attempt leaves from the next IP, no restart.
//
// Control API (127.0.0.1:<control-port>, loopback only):
//   GET  /health              -> "ok"
//   GET  /status              -> JSON { active, upstreams: [...] }
//   POST /next                -> rotate to next usable egress
//   POST /use      {name}     -> pin one egress
//   POST /exhausted {name?, cooldownMs?} -> mark exhausted (default: active, 24h)
//
// State (active egress + exhaustion timestamps) persists to --state so an
// OpenCode restart continues from the next proxy instead of the spent one.
// Node standard library only, no dependencies.

import net from "node:net";
import http from "node:http";
import fs from "node:fs";
import path from "node:path";

const DEFAULT_COOLDOWN_MS = 24 * 60 * 60 * 1000;
const DIAL_TIMEOUT_MS = 5000;
const DOWN_RETRY_MS = 30 * 1000;

function parseArgs(argv) {
  const out = { port: 8888, control: 8899, state: null, upstreams: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--port") out.port = Number(argv[++i]);
    else if (a === "--control") out.control = Number(argv[++i]);
    else if (a === "--state") out.state = argv[++i];
    else if (a === "--upstream") out.upstreams.push(parseUpstream(argv[++i]));
    else if (a === "--help" || a === "-h") {
      console.log(
        "usage: egress-router.mjs --state <file> --upstream <name>=<host:port|direct> ... [--port 8888] [--control 8899]"
      );
      process.exit(0);
    } else {
      console.error(`unknown arg: ${a}`);
      process.exit(2);
    }
  }
  if (!out.state) {
    console.error("missing --state <file>");
    process.exit(2);
  }
  if (out.upstreams.length === 0) {
    console.error("missing --upstream <name>=<host:port|direct> (repeatable)");
    process.exit(2);
  }
  return out;
}

function parseUpstream(spec) {
  const eq = spec.indexOf("=");
  if (eq === -1) {
    console.error(`bad --upstream (want name=host:port or name=direct): ${spec}`);
    process.exit(2);
  }
  const name = spec.slice(0, eq);
  const target = spec.slice(eq + 1);
  if (target === "direct") return { name, direct: true };
  const m = target.match(/^(.+):(\d+)$/);
  if (!m) {
    console.error(`bad upstream target (want host:port or direct): ${spec}`);
    process.exit(2);
  }
  return { name, direct: false, host: m[1], port: Number(m[2]) };
}

function loadState(file, upstreamNames) {
  let s = { active: upstreamNames[0], exhausted: {}, down: {} };
  try {
    const raw = JSON.parse(fs.readFileSync(file, "utf8"));
    if (raw && typeof raw === "object") {
      if (upstreamNames.includes(raw.active)) s.active = raw.active;
      if (raw.exhausted && typeof raw.exhausted === "object") s.exhausted = raw.exhausted;
      if (raw.down && typeof raw.down === "object") s.down = raw.down;
    }
  } catch {
    // missing or corrupt: start fresh
  }
  return s;
}

function saveState(file, state) {
  try {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, JSON.stringify(state, null, 2));
  } catch (err) {
    console.error(`state save failed: ${err.message}`);
  }
}

function pruneExpired(state, now) {
  for (const k of Object.keys(state.exhausted)) {
    if (state.exhausted[k] <= now) delete state.exhausted[k];
  }
  for (const k of Object.keys(state.down)) {
    if (state.down[k] <= now) delete state.down[k];
  }
}

function usableNames(cfg, state, now) {
  pruneExpired(state, now);
  return cfg.upstreams.filter((u) => !state.exhausted[u.name] && !state.down[u.name]).map((u) => u.name);
}

function rotate(state, cfg, now) {
  pruneExpired(state, now);
  const order = cfg.upstreams.map((u) => u.name);
  const start = order.indexOf(state.active);
  for (let step = 1; step <= order.length; step++) {
    const name = order[(start + step) % order.length];
    if (!state.exhausted[name] && !state.down[name]) {
      state.active = name;
      return name;
    }
  }
  return null; // everything exhausted or down
}

function log(...args) {
  console.log(new Date().toISOString(), ...args);
}

// Read from socket until full HTTP headers are buffered (or limit hit).
function readHeaders(sock, firstChunk) {
  return new Promise((resolve, reject) => {
    const chunks = [firstChunk];
    let len = firstChunk.length;
    const onData = (c) => {
      chunks.push(c);
      len += c.length;
      if (len > 65536) {
        cleanup();
        reject(new Error("headers too large"));
        return;
      }
      if (Buffer.concat(chunks).includes("\r\n\r\n")) {
        cleanup();
        resolve(Buffer.concat(chunks));
      }
    };
    const onError = (err) => {
      cleanup();
      reject(err);
    };
    const cleanup = () => {
      sock.off("data", onData);
      sock.off("error", onError);
    };
    if (Buffer.concat(chunks).includes("\r\n\r\n")) {
      cleanup();
      resolve(Buffer.concat(chunks));
      return;
    }
    sock.on("data", onData);
    sock.on("error", onError);
  });
}

function parseTarget(head) {
  const line = head.toString("latin1").split("\r\n", 1)[0];
  const m = line.match(/^(\S+)\s+(\S+)\s+HTTP\/\d/i);
  if (!m) return { error: `bad request line: ${line.slice(0, 80)}` };
  const method = m[1].toUpperCase();
  const target = m[2];
  if (method === "CONNECT") {
    const hm = target.match(/^(?:\[([^\]]+)\]|([^:]+)):(\d+)$/);
    if (!hm) return { error: `bad CONNECT target: ${target}` };
    return { method, host: hm[1] ?? hm[2], port: Number(hm[3]), raw: head };
  }
  if (/^https?:\/\//i.test(target)) {
    try {
      const u = new URL(target);
      return {
        method,
        host: u.hostname,
        port: Number(u.port) || (u.protocol === "https:" ? 443 : 80),
        raw: head,
      };
    } catch {
      return { error: `bad absolute URI: ${target.slice(0, 80)}` };
    }
  }
  return { error: `unsupported origin-form ${method} without proxy context` };
}

function dial(host, port, timeoutMs) {
  return new Promise((resolve, reject) => {
    const s = net.connect({ host, port });
    const t = setTimeout(() => {
      s.destroy();
      reject(new Error(`dial timeout ${host}:${port}`));
    }, timeoutMs);
    s.once("connect", () => {
      clearTimeout(t);
      resolve(s);
    });
    s.once("error", (err) => {
      clearTimeout(t);
      reject(err);
    });
  });
}

function readResponseHead(sock, timeoutMs) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    const t = setTimeout(() => {
      cleanup();
      reject(new Error("upstream response timeout"));
    }, timeoutMs);
    const onData = (c) => {
      chunks.push(c);
      const buf = Buffer.concat(chunks);
      const idx = buf.indexOf("\r\n\r\n");
      if (idx !== -1) {
        cleanup();
        resolve({ head: buf.slice(0, idx + 4), rest: buf.slice(idx + 4) });
      }
    };
    const onError = (err) => {
      cleanup();
      reject(err);
    };
    const cleanup = () => {
      clearTimeout(t);
      sock.off("data", onData);
      sock.off("error", onError);
    };
    sock.on("data", onData);
    sock.on("error", onError);
  });
}

function pipe(a, b) {
  a.on("error", () => b.destroy());
  b.on("error", () => a.destroy());
  a.pipe(b);
  b.pipe(a);
}

async function handleClient(cfg, state, client) {
  client.on("error", () => {});
  let buf;
  try {
    const first = await new Promise((resolve, reject) => {
      client.once("data", resolve);
      client.once("error", reject);
      client.once("close", () => reject(new Error("client closed")));
    });
    buf = await readHeaders(client, first);
  } catch {
    client.destroy();
    return;
  }
  const t = parseTarget(buf);
  if (t.error) {
    client.end("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n");
    return;
  }

  const headerEnd = buf.indexOf("\r\n\r\n") + 4;
  const rest = buf.slice(headerEnd);

  const now = Date.now();
  const order = cfg.upstreams.map((u) => u.name);
  const startIdx = Math.max(0, order.indexOf(state.active));
  let lastErr = null;

  for (let step = 0; step < order.length; step++) {
    const name = order[(startIdx + step) % order.length];
    if (state.exhausted[name]) continue; // spent quota: skip without touching
    const up = cfg.upstreams.find((u) => u.name === name);
    if (state.down[name] && state.down[name] > Date.now()) continue;
    try {
      if (up.direct) {
        const upstream = await dial(t.host, t.port, DIAL_TIMEOUT_MS);
        if (t.method === "CONNECT") {
          // buf may already contain pipelined TLS bytes after the headers.
          if (rest.length) upstream.write(rest);
          client.write("HTTP/1.1 200 Connection Established\r\n\r\n");
        } else {
          upstream.write(buf); // absolute or origin form, both legal to origin
        }
        if (state.active !== name) {
          state.active = name;
          saveState(cfg.state, state);
          log(`active -> ${name} (direct)`);
        }
        pipe(client, upstream);
        return;
      }
      // via VPS tinyproxy
      const proxy = await dial(up.host, up.port, DIAL_TIMEOUT_MS);
      proxy.on("error", () => {});
      proxy.write(buf);
      if (t.method === "CONNECT") {
        const { head, rest } = await readResponseHead(proxy, DIAL_TIMEOUT_MS);
        const statusLine = head.toString("latin1").split("\r\n", 1)[0];
        if (!/^HTTP\/\d(\.\d)?\s+200\b/i.test(statusLine)) {
          lastErr = new Error(`${name}: ${statusLine.slice(0, 80)}`);
          proxy.destroy();
          state.down[name] = Date.now() + DOWN_RETRY_MS;
          continue;
        }
        client.write(head);
        if (rest.length) client.write(rest);
      } else {
        // plain HTTP through upstream proxy: blind relay
      }
      if (state.active !== name) {
        state.active = name;
        saveState(cfg.state, state);
        log(`active -> ${name}`);
      }
      delete state.down[name];
      pipe(client, proxy);
      return;
    } catch (err) {
      lastErr = err;
      state.down[name] = Date.now() + DOWN_RETRY_MS;
    }
  }

  saveState(cfg.state, state);
  log(`all egresses failed (${lastErr ? lastErr.message : "none usable"})`);
  try {
    client.end("HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n");
  } catch {
    client.destroy();
  }
}

function startControl(cfg, state) {
  const server = http.createServer((req, res) => {
    const url = new URL(req.url, "http://127.0.0.1");
    const send = (code, obj) => {
      const body = typeof obj === "string" ? obj : JSON.stringify(obj);
      res.writeHead(code, { "Content-Type": "application/json" });
      res.end(body);
    };
    const readBody = () =>
      new Promise((resolve) => {
        let b = "";
        req.on("data", (c) => (b += c));
        req.on("end", () => {
          try {
            resolve(b ? JSON.parse(b) : {});
          } catch {
            resolve({});
          }
        });
      });

    (async () => {
      const now = Date.now();
      if (req.method === "GET" && (url.pathname === "/health" || url.pathname === "/status")) {
        pruneExpired(state, now);
        if (url.pathname === "/health") {
          res.writeHead(200, { "Content-Type": "text/plain" });
          res.end("ok");
          return;
        }
        send(200, {
          active: state.active,
          upstreams: cfg.upstreams.map((u) => ({
            name: u.name,
            via: u.direct ? "direct" : `${u.host}:${u.port}`,
            exhaustedUntil: state.exhausted[u.name] ?? null,
            downUntil: state.down[u.name] ?? null,
          })),
        });
        return;
      }
      if (req.method === "POST" && url.pathname === "/next") {
        const name = rotate(state, cfg, now);
        saveState(cfg.state, state);
        if (!name) {
          send(409, { error: "all egresses exhausted or down", active: state.active });
          return;
        }
        log(`control /next -> ${name}`);
        send(200, { active: name });
        return;
      }
      if (req.method === "POST" && url.pathname === "/use") {
        const body = await readBody();
        if (!cfg.upstreams.some((u) => u.name === body.name)) {
          send(404, { error: `unknown egress: ${body.name}` });
          return;
        }
        state.active = body.name;
        delete state.down[body.name];
        saveState(cfg.state, state);
        log(`control /use -> ${body.name}`);
        send(200, { active: state.active });
        return;
      }
      if (req.method === "POST" && url.pathname === "/exhausted") {
        const body = await readBody();
        const name = body.name ?? state.active;
        if (!cfg.upstreams.some((u) => u.name === name)) {
          send(404, { error: `unknown egress: ${name}` });
          return;
        }
        const cooldown = Number(body.cooldownMs) || DEFAULT_COOLDOWN_MS;
        state.exhausted[name] = now + cooldown;
        saveState(cfg.state, state);
        log(`marked exhausted: ${name} for ${Math.round(cooldown / 3600000)}h`);
        send(200, { name, exhaustedUntil: state.exhausted[name] });
        return;
      }
      send(404, { error: "unknown endpoint" });
    })().catch((err) => {
      try {
        send(500, { error: err.message });
      } catch {}
    });
  });
  server.listen(cfg.control, "127.0.0.1", () => {
    log(`control on 127.0.0.1:${cfg.control}`);
  });
  return server;
}

const cfg = parseArgs(process.argv.slice(2));
const state = loadState(cfg.state, cfg.upstreams.map((u) => u.name));
pruneExpired(state, Date.now());

const proxyServer = net.createServer((sock) => handleClient(cfg, state, sock));
proxyServer.on("error", (err) => {
  console.error(`router listen failed on 127.0.0.1:${cfg.port}: ${err.message}`);
  process.exit(1);
});
proxyServer.listen(cfg.port, "127.0.0.1", () => {
  log(`router on 127.0.0.1:${cfg.port} active=${state.active} upstreams=${cfg.upstreams.map((u) => u.name).join(",")}`);
});
startControl(cfg, state);

for (const sig of ["SIGINT", "SIGTERM"]) {
  process.on(sig, () => {
    saveState(cfg.state, state);
    process.exit(0);
  });
}
