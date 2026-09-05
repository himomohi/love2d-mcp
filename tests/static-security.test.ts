import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const bridgeUrl = new URL("../game/mcp_bridge.lua", import.meta.url);

test("Lua bridge binds to loopback by default and never wildcard-binds", async () => {
  const source = await readFile(bridgeUrl, "utf8");
  assert.match(source, /host = "127\.0\.0\.1"/);
  assert.doesNotMatch(source, /bind\("\*"/);
});

test("run_lua is disabled by default and does not expose love, os, io, package, or debug", async () => {
  const source = await readFile(bridgeUrl, "utf8");
  assert.match(source, /allow_run_lua = false/);
  const envStart = source.indexOf("local env = {");
  const envEnd = source.indexOf("setfenv(func, env)", envStart);
  const env = source.slice(envStart, envEnd);
  assert.doesNotMatch(env, /\blove\s*=/);
  assert.doesNotMatch(env, /\bos\s*=/);
  assert.doesNotMatch(env, /\bio\s*=/);
  assert.doesNotMatch(env, /\bpackage\s*=/);
  assert.doesNotMatch(env, /\bdebug\s*=/);
});

test("bridge bounds response serialization and optional Lua execution", async () => {
  const source = await readFile(bridgeUrl, "utf8");
  assert.match(source, /max_response_bytes = 1024 \* 1024/);
  assert.match(source, /max_serialize_items = 1000/);
  assert.match(source, /lua_instruction_limit = 500000/);
  assert.match(source, /debug\.sethook\(instruction_guard/);
});
