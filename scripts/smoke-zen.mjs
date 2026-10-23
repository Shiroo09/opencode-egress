// smoke-zen.mjs — modelgate + egress-router zinciri tek seferlik doğrulama.
// Router'ı test portunda başlatır, modelgate'i NODE_USE_ENV_PROXY ile router
// arkasında ayağa kaldırır, /health ve /recent uçlarını doğrular, temizlenir.
// Çalıştır: node scripts/smoke-zen.mjs
import net from "node:net";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import assert from "node:assert";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const ROOT = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const ROUTER_PORT = 18888;
const CONTROL_PORT = 18899;
const ZEN_PORT = 18787;

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "zen-smoke-"));
const stateFile = path.join(tmp, "state.json");

const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const probe = async (url) => {
  const res = await fetch(url);
  return { status: res.status, text: await res.text() };
};

const router = spawn(
  process.execPath,
  [
    path.join(ROOT, "scripts", "egress-router.mjs"),
    "--port", String(ROUTER_PORT),
    "--control", String(CONTROL_PORT),
    "--state", stateFile,
    "--upstream", "direct=direct",
  ],
  { stdio: ["ignore", "pipe", "pipe"] }
);
const zen = spawn(process.execPath, [path.join(ROOT, "vendor", "modelgate", "zen-proxy.mjs")], {
  stdio: ["ignore", "pipe", "pipe"],
  env: {
    ...process.env,
    PORT: String(ZEN_PORT),
    NODE_USE_ENV_PROXY: "1",
    HTTPS_PROXY: `http://127.0.0.1:${ROUTER_PORT}`,
    NO_PROXY: "localhost,127.0.0.1",
  },
});
router.stderr.on("data", (c) => process.stderr.write(`[router] ${c}`));
zen.stderr.on("data", (c) => process.stderr.write(`[gate] ${c}`));

try {
  await wait(3000);

  const health = await probe(`http://127.0.0.1:${ZEN_PORT}/health`);
  assert.equal(health.status, 200, "zen /health 200");
  const hj = JSON.parse(health.text);
  assert.ok(hj.ok, "zen /health ok:true");
  console.log("health:", health.text);

  const ui = await probe(`http://127.0.0.1:${ZEN_PORT}/`);
  assert.ok(ui.text.includes("opencode-egress"), "dashboard markasi opencode-egress");
  assert.ok(!ui.text.includes("ZEN·PROXY"), "eski marka kalmadi");
  const logo = await probe(`http://127.0.0.1:${ZEN_PORT}/assets/logo.svg`);
  assert.equal(logo.status, 200, "logo.svg sunuluyor");
  console.log("dashboard: marka + logo OK");

  // models upstream'a gider; internet yoksa hata döner ama zincir yine de
  // kanıtlanır: istek router'ın /recent kaydına düşer.
  const models = await probe(`http://127.0.0.1:${ZEN_PORT}/v1/models`);
  console.log("models:", models.status, models.text.slice(0, 200));

  const recent = await probe(`http://127.0.0.1:${CONTROL_PORT}/recent?n=10`);
  const rows = JSON.parse(recent.text).rows;
  assert.ok(rows.length > 0, "router /recent en az bir istek gordu");
  assert.ok(rows.some((r) => String(r.host).includes("opencode.ai")), "istek router uzerinden gecti");
  console.log("recent:", JSON.stringify(rows).slice(0, 300));

  console.log("smoke-zen: OK — modelgate -> egress-router zinciri calisiyor");
} finally {
  router.kill();
  zen.kill();
  fs.rmSync(tmp, { recursive: true, force: true });
}