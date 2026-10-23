// test.mjs — plugin simulation: fake router control API + mocked OpenCode
// client context. Run: node test.mjs
import http from "node:http";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import assert from "node:assert";

const CONTROL_PORT = 18999;
const tmpHome = fs.mkdtempSync(path.join(os.tmpdir(), "egress-rotate-test-"));
process.env.HOME = tmpHome;
process.env.USERPROFILE = tmpHome;
fs.mkdirSync(path.join(tmpHome, ".config", "opencode"), { recursive: true });
fs.writeFileSync(
  path.join(tmpHome, ".config", "opencode", "egress-rotate.json"),
  JSON.stringify({ routerUrl: `http://127.0.0.1:${CONTROL_PORT}`, logging: false })
);

const calls = { exhausted: [], next: 0, abort: 0, revert: 0, prompt: [] };
let nextStatus = 200;

const control = http.createServer((req, res) => {
  let b = "";
  req.on("data", (c) => (b += c));
  req.on("end", () => {
    if (req.url === "/status") {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ active: "vps1" }));
    } else if (req.url === "/exhausted") {
      calls.exhausted.push(JSON.parse(b || "{}"));
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ name: "vps1" }));
    } else if (req.url === "/next") {
      calls.next++;
      if (nextStatus === 409) {
        res.writeHead(409, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: "all egresses exhausted" }));
      } else {
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ active: "vps2" }));
      }
    } else {
      res.writeHead(404);
      res.end("{}");
    }
  });
});
await new Promise((r) => control.listen(CONTROL_PORT, "127.0.0.1", r));

const promptBodies = [];
const context = {
  client: {
    session: {
      abort: async () => calls.abort++,
      messages: async () => ({
        data: [
          {
            info: {
              id: "m1",
              role: "user",
              sessionID: "s1",
              model: { providerID: "opencode", modelID: "big-pickle" },
              agent: "build",
            },
            parts: [{ id: "p1", type: "text", text: "hello again" }],
          },
        ],
      }),
      revert: async () => calls.revert++,
      prompt: async ({ body }) => {
        promptBodies.push(body);
        calls.prompt.push(1);
      },
    },
  },
};

const { createPlugin } = await import("./index.ts");
const plugin = await createPlugin(context);

const retry = (message) => ({
  event: {
    type: "session.status",
    properties: { sessionID: "s1", status: { type: "retry", message } },
  },
});

// 1. Rate-limit retry -> exhaust + rotate + re-send with SAME model.
await plugin.event(retry("Error from provider (Console): FreeUsageLimitError: Rate limit exceeded. Please try again later."));
assert.equal(calls.exhausted.length, 1, "marks spent egress exhausted");
assert.equal(calls.exhausted[0].name, "vps1", "exhausts the active egress");
assert.equal(calls.next, 1, "rotates once");
assert.equal(calls.abort, 1, "aborts failed attempt");
assert.equal(calls.revert, 1, "reverts failed attempt");
assert.equal(promptBodies.length, 1, "re-sends the message");
assert.deepEqual(promptBodies[0].model, { providerID: "opencode", modelID: "big-pickle" }, "same model, new IP");
assert.equal(promptBodies[0].parts[0].text, "hello again", "same content");

// 2. Duplicate retry events from the same incident are guarded.
await plugin.event(retry("Free usage exceeded, retrying in 20h"));
assert.equal(calls.next, 1, "no second rotation within guard window");

// 3. Unrelated errors are ignored.
await plugin.event(retry("The request contains invalid parameters"));
assert.equal(calls.next, 1, "non-limit error ignored");

// 3b. The wording OpenCode v2 actually shows (screenshot, 2026-10-23).
//     Guard reset so the assertion is about the pattern, not the cooldown.
await plugin.event({ event: { type: "session.deleted", properties: { info: { id: "s1" } } } });
await plugin.event(retry("Free usage limit reached. Subscribe to OpenCode Go to keep going: https://opencode.ai/go"));
assert.equal(calls.next, 2, "Free usage limit reached rotates");

// 3c. Empty message but structured provider.quota reason still rotates.
await plugin.event({ event: { type: "session.deleted", properties: { info: { id: "s1" } } } });
await plugin.event({
  event: {
    type: "session.status",
    properties: {
      sessionID: "s1",
      status: { type: "retry", message: "provider stopped the reply", action: { reason: "provider.quota" } },
    },
  },
});
assert.equal(calls.next, 3, "action.reason provider.quota rotates");

// 4. All egresses spent -> plugin stands down, normal retry continues.
nextStatus = 409;
calls.next = 0;
promptBodies.length = 0;
// wait out the 15s duplicate guard by faking session churn
await plugin.event({ event: { type: "session.deleted", properties: { info: { id: "s1" } } } });
await plugin.event(retry("FreeUsageLimitError: Rate limit exceeded"));
assert.equal(calls.next, 1, "tried to rotate");
assert.equal(promptBodies.length, 0, "no re-send when pool is empty");

control.close();
fs.rmSync(tmpHome, { recursive: true, force: true });
console.log("egress-rotate plugin test: all assertions passed");
