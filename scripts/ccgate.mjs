// ccgate — Claude Code ile modele özel bir gateway arasındaki model adı çevirici.
//
// Sorun: Claude Code'un otomatik compaction yolu, oturum modelini kendi
// kataloğunda arar. Gateway modeli (ör. deepseek-v4.1-flash) katalogda yok →
// compaction düşer; kullanıcı "automatic compaction failed" görür.
//
// Çözüm: Claude Code katalog adlarını görür (claude-sonnet-4-6 ...), ccgate
// gövdedeki modeli gateway'in anladığı ada çevirip iletir.
//
// Env: CCG_UP (gateway kökü), CCG_TOKEN, CCG_PORT.
import http from "node:http";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

// Gateway kimliği: env yoksa ~/.claude/ccgate.json {up, token}.
function fileConfig() {
  try {
    const p = path.join(process.env.HOME || process.env.USERPROFILE || os.homedir(), ".claude", "ccgate.json");
    return JSON.parse(fs.readFileSync(p, "utf8"));
  } catch {
    return {};
  }
}
const cfg = fileConfig();

// UP sonundaki /v1 atılır: istek yolu zaten /v1/... geliyor.
const UP = (process.env.CCG_UP || cfg.up || "https://evren-llmapi.ssyz.org.tr")
  .replace(/\/+$/, "")
  .replace(/\/v1$/, "");
const TOKEN = process.env.CCG_TOKEN || cfg.token || "";
const PORT = Number(process.env.CCG_PORT || cfg.port || 18800);

// Claude Code'un tanıdığı ad -> gateway modeli. Sıra: en özel eşleşme önce.
export const MAP = {
  "claude-opus-4-6": "mimo-v2.6-pro",
  "claude-sonnet-4-6": "deepseek-v4.1-flash",
  "claude-haiku-4-5": "glm-5.3",
};
export const DEFAULT_MODEL = "deepseek-v4.1-flash";

// Katalog adı + [1m]/[1M] eki + bilinmeyen ad → gateway modeli.
export function resolveModel(name) {
  const bare = String(name || "").replace(/\[[^\]]*\]$/, "").trim();
  if (MAP[bare]) return MAP[bare];
  const family = /opus/i.test(bare) ? "claude-opus-4-6" : /haiku/i.test(bare) ? "claude-haiku-4-5" : null;
  return family ? MAP[family] : bare || DEFAULT_MODEL;
}

// Claude Code taban URL'ye bir kez daha /v1 ekliyor; iki kez gelirse tekile indir.
export function upstreamPath(url) {
  return url.replace(/^\/v1(\/v1)+/, "/v1");
}

export function rewriteBody(body) {
  return body.replace(/"model"\s*:\s*"([^"]*)"/g, (_, m) => `"model":"${resolveModel(m)}"`);
}

const DEBUG = process.env.CCG_DEBUG === "1";
const server = http.createServer(async (req, res) => {
  if (DEBUG) console.log("REQ", req.method, req.url);
  if (req.method === "GET" && /\/models/.test(req.url)) {
    res.writeHead(200, { "content-type": "application/json" });
    return res.end(JSON.stringify({
      data: Object.keys(MAP).map((id) => ({ id, type: "model", display_name: id, created_at: "2026-01-01T00:00:00Z" })),
      has_more: false,
    }));
  }
  const chunks = [];
  for await (const c of req) chunks.push(c);
  const raw = Buffer.concat(chunks).toString("utf8");
  const body = raw.includes('"model"') ? rewriteBody(raw) : raw;
  try {
    const upstream = await fetch(UP + upstreamPath(req.url), {
      method: req.method,
      headers: {
        "content-type": "application/json",
        authorization: `Bearer ${TOKEN}`,
        "anthropic-version": req.headers["anthropic-version"] || "2023-06-01",
      },
      body: req.method === "GET" || req.method === "HEAD" ? undefined : body,
    });
    if (DEBUG) console.log("RES", upstream.status, req.url);
    res.writeHead(upstream.status, { "content-type": upstream.headers.get("content-type") || "application/json" });
    res.end(Buffer.from(await upstream.arrayBuffer()));
  } catch (err) {
    res.writeHead(502, { "content-type": "application/json" });
    res.end(JSON.stringify({ type: "error", error: { type: "api_error", message: String(err.message) } }));
  }
});

if (process.argv[1] && /ccgate\.mjs$/.test(process.argv[1])) {
  server.listen(PORT, "127.0.0.1", () => console.log(`ccgate on 127.0.0.1:${PORT} -> ${UP}`));
}
