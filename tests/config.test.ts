import assert from "node:assert/strict";
import test from "node:test";
import { loadConfig } from "../src/config.ts";

test("requires a strong token", () => {
  assert.throws(() => loadConfig({ LOVE2D_MCP_TOKEN: "short" }), /at least 32/);
});

test("blocks non-loopback hosts", () => {
  assert.throws(
    () => loadConfig({ LOVE2D_MCP_TOKEN: "x".repeat(32), LOVE2D_MCP_HOST: "0.0.0.0" }),
    /loopback/
  );
});

test("accepts a loopback configuration", () => {
  const config = loadConfig({
    LOVE2D_MCP_TOKEN: "x".repeat(32),
    LOVE2D_MCP_HOST: "127.0.0.1",
    LOVE2D_MCP_PORT: "23456",
  });
  assert.equal(config.host, "127.0.0.1");
  assert.equal(config.port, 23456);
});
