// ccgate model eşlemesi testi. Çalıştır: node scripts/ccgate.test.mjs
import assert from "node:assert";
const { resolveModel, rewriteBody, upstreamPath } = await import("./ccgate.mjs");

assert.equal(upstreamPath("/v1/messages"), "/v1/messages");
assert.equal(upstreamPath("/v1/v1/messages?beta=true"), "/v1/messages?beta=true", "cift /v1 tekile iner");

assert.equal(resolveModel("claude-sonnet-4-6"), "deepseek-v4.1-flash");
assert.equal(resolveModel("claude-sonnet-4-6[1m]"), "deepseek-v4.1-flash", "1m eki yok sayilir");
assert.equal(resolveModel("claude-opus-4-6"), "deepseek-v4.1-flash");
assert.equal(resolveModel("opus"), "deepseek-v4.1-flash", "aile takma adi");
assert.equal(resolveModel("claude-haiku-4-5"), "qwen3.8-flash-next", "kucuk slot bos donmemeli");
assert.equal(resolveModel("gemini-4-argon"), "gemini-4-argon", "bilinmeyen ad oldugu gibi");
assert.equal(resolveModel(""), "deepseek-v4.1-flash", "bos ad varsayilana");

assert.equal(
  rewriteBody('{"model":"claude-sonnet-4-6","messages":[]}'),
  '{"model":"deepseek-v4.1-flash","messages":[]}'
);
assert.equal(
  rewriteBody('{"model":"claude-opus-4-6","nested":{"model":"claude-haiku-4-5"}}'),
  '{"model":"deepseek-v4.1-flash","nested":{"model":"qwen3.8-flash-next"}}',
  "ic ice model alanlari da cevrilir"
);
assert.equal(rewriteBody('{"messages":[]}'), '{"messages":[]}', "model yoksa dokunulmaz");

console.log("ccgate test: all assertions passed");
