#!/usr/bin/env node
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { loadConfig } from "./config.js";
import { createServer } from "./server.js";

async function main() {
  const config = loadConfig();
  const { server, client } = createServer(config);
  const close = () => { client.close(); void server.close().finally(() => process.exit(0)); };
  process.once("SIGINT", close);
  process.once("SIGTERM", close);
  await server.connect(new StdioServerTransport());
  console.error(`LÖVE2D MCP 2.1.0 ready; local bridge ${config.host}:${config.port}`);
}
main().catch(error => { console.error(error instanceof Error ? error.message : "Startup failed"); process.exitCode = 1; });
