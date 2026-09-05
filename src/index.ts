#!/usr/bin/env node

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { CallToolRequestSchema, ListToolsRequestSchema } from "@modelcontextprotocol/sdk/types.js";
import { z } from "zod/v4";
import { loadConfig } from "./config.js";
import { BridgeError, Love2DClient } from "./love2d-client.js";

const config = loadConfig();
const love2dClient = new Love2DClient(config);

const server = new Server(
  {
    name: "love2d-mcp",
    version: "2.0.0",
  },
  {
    capabilities: { tools: {} },
  }
);

const objectIdSchema = z.object({ id: z.string().min(1).max(256) });
const propertySchema = z.object({
  id: z.string().min(1).max(256),
  property: z.string().min(1).max(128),
  value: z.union([z.string(), z.number(), z.boolean(), z.null()]),
});
const actionSchema = z.object({
  action: z.string().min(1).max(128),
  params: z.record(z.string(), z.unknown()).optional().default({}),
});
const luaSchema = z.object({ code: z.string().min(1).max(64 * 1024) });

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: "ping",
      description: "Check whether the local LÖVE2D bridge is reachable and authenticated",
      inputSchema: { type: "object", properties: {} },
    },
    {
      name: "get_status",
      description: "Get bridge capabilities, security mode, client count, and game metadata",
      inputSchema: { type: "object", properties: {} },
    },
    {
      name: "list_objects",
      description: "List sanitized objects in the current game scene",
      inputSchema: { type: "object", properties: {} },
    },
    {
      name: "get_object",
      description: "Get sanitized details for one game object",
      inputSchema: {
        type: "object",
        properties: { id: { type: "string", minLength: 1, maxLength: 256 } },
        required: ["id"],
      },
    },
    {
      name: "set_object_property",
      description: "Mutate an object through the game's explicit, allowlisted property setter callback",
      inputSchema: {
        type: "object",
        properties: {
          id: { type: "string" },
          property: { type: "string" },
          value: { type: ["string", "number", "boolean", "null"] },
        },
        required: ["id", "property", "value"],
      },
    },
    {
      name: "invoke_action",
      description: "Invoke a game-defined allowlisted development action",
      inputSchema: {
        type: "object",
        properties: {
          action: { type: "string" },
          params: { type: "object", additionalProperties: true },
        },
        required: ["action"],
      },
    },
    {
      name: "run_lua",
      description:
        "Execute Lua in a restricted bridge sandbox. Disabled by default and only available when the game explicitly enables it.",
      inputSchema: {
        type: "object",
        properties: { code: { type: "string", maxLength: 65536 } },
        required: ["code"],
      },
    },
  ],
}));

function textResult(value: unknown) {
  return {
    content: [{ type: "text" as const, text: JSON.stringify(value, null, 2) }],
  };
}

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: rawArgs } = request.params;
  const args = rawArgs ?? {};

  try {
    switch (name) {
      case "ping":
      case "get_status":
      case "list_objects":
        return textResult(await love2dClient.sendCommand(name));

      case "get_object": {
        const parsed = objectIdSchema.parse(args);
        return textResult(await love2dClient.sendCommand(name, parsed));
      }

      case "set_object_property": {
        const parsed = propertySchema.parse(args);
        return textResult(await love2dClient.sendCommand(name, parsed));
      }

      case "invoke_action": {
        const parsed = actionSchema.parse(args);
        return textResult(await love2dClient.sendCommand(name, parsed));
      }

      case "run_lua": {
        const parsed = luaSchema.parse(args);
        return textResult(await love2dClient.sendCommand(name, parsed));
      }

      default:
        throw new Error(`Unknown tool: ${name}`);
    }
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    const prefix = error instanceof BridgeError && error.code ? `[${error.code}] ` : "";
    return {
      content: [{ type: "text" as const, text: `Error: ${prefix}${message}` }],
      isError: true,
    };
  }
});

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error(`LÖVE2D MCP server ready; bridge=${config.host}:${config.port}`);
}

main().catch((error) => {
  console.error("Fatal error:", error instanceof Error ? error.message : error);
  process.exit(1);
});
