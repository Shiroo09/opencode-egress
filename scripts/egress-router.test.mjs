// egress-router.test.mjs — hermetic functional test, Node stdlib only.
// Spins up a fake echo target + two fake CONNECT proxies, drives the real
// router as a child process, and asserts rotation / failover / persistence.
import net from "node:net";
import http from "node:http";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import assert from "node:assert";

const ECHO_PORT = 18909;
const UP_A = 18911;
const UP_B = 18912;
const ROUTER_PORT = 18888;
const CONTROL_PORT = 18899;

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "egress-router-test-"));
const stateFile = path.join(tmp, "state.json");
const routerJs = fileURLToPath(new URL("./egress-router.mjs", import.meta.url));

function startEcho() {
  return new Promise((resolve) => {
    const s = net.createServer((sock) => sock.pipe(sock));
    s.listen(ECHO_PORT, "127.0.0.1", () => resolve(s));
  });
}

// Minimal CONNECT proxy: dial the requested target, reply 200, pipe.
function startFakeProxy(port) {
  return new Promise((resolve) => {
    const s = net.createServer((client) => {
      let buf = Buffer.alloc(0);
      const onData = (c) => {
        buf = Buffer.concat([buf, c]);
        if (!buf.includes("\r\n\r\n")) return;
        client.off("data", onData);
        const line = buf.toString("latin1").split("\r\n", 1)[0];
        const m = line.match(/^CONNECT\s+(\S+)\s+HTTP/i);
        if (!m) {
          client.end("HTTP/1.1 400 Bad Request\r\n\r\n");
          return;
        }
        const [h, p] = m[1].split(":");
        const up = net.connect({ host: h, port: Number(p) }, () => {
          const idx = buf.indexOf("\r\n\r\n") + 4;
          if (buf.length > idx) up.write(buf.slice(idx));
          client.write("HTTP/1.1 200 Connection Established\r\n\r\n");
          client.pipe(up);
          up.pipe(client);
        });
        up.on("error", () => client.end("HTTP/1.1 502 Bad Gateway\r\n\r\n"));
      };
      client.on("data", onData);
    });
    s.listen(port, "127.0.0.1", () => resolve(s));
  });
}

function api(method, p, body) {
  return new Promise((resolve, reject) => {
    const req = http.request(
      { host: "127.0.0.1", port: CONTROL_PORT, path: p, method },
      (res) => {
        let b = "";
        res.on("data", (c) => (b += c));
        res.on("end", () => resolve({ status: res.statusCode, body: b }));
      }
    );
    req.on("error", reject);
    if (body) req.write(JSON.stringify(body));
    req.end();
  });
}

function viaRouter(payload) {
  return new Promise((resolve, reject) => {
    const s = net.connect({ host: "127.0.0.1", port: ROUTER_PORT }, () => {
      s.write(`CONNECT 127.0.0.1:${ECHO_PORT} HTTP/1.1\r\nHost: 127.0.0.1:${ECHO_PORT}\r\n\r\n`);
    });
    let buf = Buffer.alloc(0);
    let established = false;
    const t = setTimeout(() => reject(new Error("viaRouter timeout")), 8000);
    s.on("data", (c) => {
      buf = Buffer.concat([buf, c]);
      if (!established && buf.includes("\r\n\r\n")) {
        const head = buf.toString("latin1").split("\r\n\r\n")[0];
        if (!/ 200\b/.test(head.split("\r\n")[0])) {
          clearTimeout(t);
          reject(new Error(`no 200: ${head.split("\r\n")[0]}`));
          return;
        }
        established = true;
        buf = Buffer.alloc(0);
        s.write(payload);
        return;
      }
      if (established && buf.length >= payload.length) {
        clearTimeout(t);
        s.destroy();
        resolve(buf.toString());
      }
    });
    s.on("error", (e) => {
      clearTimeout(t);
      reject(e);
    });
  });
}

const echo = await startEcho();
const proxyA = await startFakeProxy(UP_A);
const proxyB = await startFakeProxy(UP_B);

const child = spawn(
  process.execPath,
  [
    routerJs,
    "--port",
    String(ROUTER_PORT),
    "--control",
    String(CONTROL_PORT),
    "--state",
    stateFile,
    "--upstream",
    `vps1=127.0.0.1:${UP_A}`,
    "--upstream",
    `vps2=127.0.0.1:${UP_B}`,
    "--upstream",
    "direct=direct",
  ],
  { stdio: ["ignore", "pipe", "pipe"] }
);
child.stderr.on("data", (c) => process.stderr.write(`[router] ${c}`));
await new Promise((resolve, reject) => {
  const t = setTimeout(() => reject(new Error("router did not start")), 10000);
  child.stdout.on("data", (c) => {
    if (String(c).includes(`router on 127.0.0.1:${ROUTER_PORT}`)) {
      clearTimeout(t);
      resolve();
    }
  });
  child.on("exit", (code) => reject(new Error(`router exited ${code}`)));
});

try {
  let r = await api("GET", "/health");
  assert.equal(r.status, 200, "health");

  r = await api("GET", "/status");
  assert.equal(r.status, 200, "status");
  assert.equal(JSON.parse(r.body).active, "vps1", "starts on first upstream");

  assert.equal(await viaRouter("hello-a"), "hello-a", "data flows via vps1");

  r = await api("POST", "/next", {});
  assert.equal(JSON.parse(r.body).active, "vps2", "next -> vps2");
  assert.equal(await viaRouter("hello-b"), "hello-b", "data flows via vps2");

  // Kill vps2's proxy: the router must fail over transparently on the same
  // connection, landing on the next healthy egress in pool order (direct).
  await new Promise((res) => proxyB.close(res));
  assert.equal(await viaRouter("hello-failover"), "hello-failover", "failover on dead tunnel");
  r = await api("GET", "/status");
  assert.equal(JSON.parse(r.body).active, "direct", "active moved past dead vps2");

  // Pin back to the healthy vps1 explicitly.
  r = await api("POST", "/use", { name: "vps1" });
  assert.equal(JSON.parse(r.body).active, "vps1", "use pins egress");
  assert.equal(await viaRouter("hello-pinned"), "hello-pinned", "data flows via pinned vps1");

  // Exhaust vps1: rotation must skip it (and dead vps2) and land on direct.
  r = await api("POST", "/exhausted", { name: "vps1", cooldownMs: 3600000 });
  assert.equal(r.status, 200, "mark exhausted");
  r = await api("POST", "/next", {});
  assert.equal(JSON.parse(r.body).active, "direct", "exhausted skipped");
  assert.equal(await viaRouter("hello-direct"), "hello-direct", "direct dial works");

  // State persists across restarts.
  const saved = JSON.parse(fs.readFileSync(stateFile, "utf8"));
  assert.equal(saved.active, "direct", "state file has active");
  assert.ok(saved.exhausted.vps1 > Date.now(), "state file has exhaustion");

  // Pin back explicitly (already on vps1 path covered above; re-pin direct).
  r = await api("POST", "/use", { name: "direct" });
  assert.equal(JSON.parse(r.body).active, "direct", "use pins egress");

  // Exhaust everything: /next must refuse instead of blackholing.
  await api("POST", "/exhausted", { name: "vps1", cooldownMs: 3600000 });
  await api("POST", "/exhausted", { name: "vps2", cooldownMs: 3600000 });
  await api("POST", "/exhausted", { name: "direct", cooldownMs: 3600000 });
  r = await api("POST", "/next", {});
  assert.equal(r.status, 409, "all exhausted -> 409");

  console.log("egress-router.test: all assertions passed");
} finally {
  child.kill();
  echo.close();
  proxyA.close();
  fs.rmSync(tmp, { recursive: true, force: true });
}
