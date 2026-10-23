// Hermetic test: fake router + fake OpenCode service, no network.
// Run: node scripts/egress-watch.test.mjs
import http from "node:http";
import assert from "node:assert";
import { tmpdir } from "node:os";
import path from "node:path";
process.env.EGRESS_WATCH_LOG = path.join(tmpdir(), "egress-watch-test.log");
const { handleFailure, isQuotaError } = await import("./egress-watch.mjs");

const calls = { exhausted: [], next: 0, prompt: [] };
let nextStatus = 200;

const router = http.createServer((req, res) => {
  let b = "";
  req.on("data", (c) => (b += c));
  req.on("end", () => {
    // The real router only answers GET /status: keep the stub strict so a
    // wrong verb here fails the test instead of passing by accident.
    if (req.url === "/status") {
      if (req.method !== "GET") { res.writeHead(405); return res.end(); }
      res.writeHead(200, { "content-type": "application/json" });
      return res.end(JSON.stringify({ active: "vps1" }));
    }
    if (req.url === "/exhausted") {
      calls.exhausted.push(JSON.parse(b || "{}"));
      res.writeHead(200); return res.end("{}");
    }
    if (req.url === "/next") {
      if (nextStatus !== 200) { res.writeHead(nextStatus); return res.end("{}"); }
      calls.next++;
      res.writeHead(200, { "content-type": "application/json" });
      return res.end(JSON.stringify({ active: "vps2" }));
    }
    res.writeHead(404); res.end();
  });
});

// Bearer-less stub: the watcher only ever calls these two paths.
const service = http.createServer((req, res) => {
  const send = (code, obj) => { res.writeHead(code, { "content-type": "application/json" }); res.end(JSON.stringify(obj)); };
  if (req.url.startsWith("/api/session/s1/message")) {
    return send(200, {
      data: [
        { type: "user", text: "eski soru" },
        { type: "assistant", error: { type: "provider.quota" } },
        { type: "user", text: "hello again" },
      ],
    });
  }
  if (req.url === "/api/session/s1/prompt") {
    let b = "";
    req.on("data", (c) => (b += c));
    req.on("end", () => { calls.prompt.push(JSON.parse(b)); send(200, { data: {} }); });
    return;
  }
  send(404, {});
});

await new Promise((r) => router.listen(18899, "127.0.0.1", r));
await new Promise((r) => service.listen(18898, "127.0.0.1", r));

// Point the module at the stubs (it reads the router URL from the env).
process.env.EGRESS_ROUTER = "http://127.0.0.1:18899";
const svc = { url: "http://127.0.0.1:18898", password: "" };

// Real HTTP against the stubs; only the router URL constant is module-level,
// so swap it through the exported dependency hook.
const deps = {
  routerPost: async (p, body) => {
    const get = p === "/status";
    const res = await fetch("http://127.0.0.1:18899" + p, {
      method: get ? "GET" : "POST", headers: { "content-type": "application/json" },
      body: get ? undefined : JSON.stringify(body ?? {}),
    });
    return { status: res.status, data: await res.text() };
  },
};

// 1. Quota wording from the screenshot rotates and re-sends.
assert.ok(isQuotaError("provider.quota", "Free usage limit reached. Subscribe to OpenCode Go"));
assert.ok(isQuotaError("provider.quota", "OpenCode stopped this reply"));
assert.ok(isQuotaError("", "free-usage-exceeded"));
assert.ok(!isQuotaError("provider.invalid-request", "Model is unavailable"));
assert.ok(!isQuotaError("", "The request contains invalid parameters"));

const r1 = await handleFailure(svc, "s1", "provider.quota", "Free usage limit reached", deps);
assert.equal(r1, "rotated", "rotates and re-sends");
assert.deepEqual(calls.exhausted, [{ name: "vps1" }], "marks the active egress spent");
assert.equal(calls.next, 1, "asked the router for the next egress");
assert.equal(calls.prompt.length, 1, "re-sent once");
assert.equal(calls.prompt[0].text, "hello again", "re-sent the last user message");

// 2. Same session inside the guard window is skipped.
const r2 = await handleFailure(svc, "s1", "provider.quota", "Free usage limit reached", deps);
assert.equal(r2, "guarded", "duplicate failure guarded");
assert.equal(calls.next, 1, "no second rotation");

// 3. Pool spent -> stand down, no re-send.
nextStatus = 409;
const r3 = await handleFailure(svc, "s2", "provider.quota", "Free usage limit reached", deps);
assert.equal(r3, "exhausted", "stands down when every egress is spent");
assert.equal(calls.prompt.length, 1, "no re-send when the pool is empty");

router.close();
service.close();
console.log("egress-watch test: all assertions passed");
