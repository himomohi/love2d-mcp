import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { CallToolRequestSchema, ListToolsRequestSchema, ListResourcesRequestSchema, ReadResourceRequestSchema, type Tool, type CallToolResult } from "@modelcontextprotocol/sdk/types.js";
import { z } from "zod/v4";
import { setTimeout as delay } from "node:timers/promises";
import type { AppConfig } from "./config.js";
import { Love2DClient, BridgeError } from "./love2d-client.js";

const empty = z.strictObject({});
const id = z.string().min(1).max(256);
const snapshot = z.strictObject({ name: z.string().min(1).max(64) });
const input = z.discriminatedUnion("event", [
  z.strictObject({ event: z.literal("key_down"), key: z.string().min(1).max(32).regex(/^[a-zA-Z0-9_]+$/) }),
  z.strictObject({ event: z.literal("key_up"), key: z.string().min(1).max(32).regex(/^[a-zA-Z0-9_]+$/) }),
  z.strictObject({ event: z.literal("mouse_move"), x: z.number().min(-100000).max(100000), y: z.number().min(-100000).max(100000) }),
  z.strictObject({ event: z.literal("mouse_down"), button: z.number().int().min(1).max(5) }),
  z.strictObject({ event: z.literal("mouse_up"), button: z.number().int().min(1).max(5) }),
  z.strictObject({ event: z.literal("text"), text: z.string().max(1024) }),
  z.strictObject({ event: z.literal("reset") }),
]);
const batchable = ["ping", "get_status", "list_objects", "get_object", "list_actions", "set_object_property", "invoke_action", "get_metrics", "get_logs"] as const;
type Spec = { schema: z.ZodType; description: string; readOnly: boolean };
export const specs: Record<string, Spec> = {
  ping: { schema: empty, readOnly: true, description: "Verify local game connection and token authentication. Start here." },
  get_status: { schema: empty, readOnly: true, description: "Discover enabled capabilities, protocol version, game metadata and pause/step state. Inspect before mutations." },
  list_objects: { schema: z.strictObject({ offset: z.number().int().min(0).max(1000000).optional(), limit: z.number().int().min(1).max(500).optional(), type: z.string().min(1).max(128).optional(), query: z.string().max(256).optional() }), readOnly: true, description: "Find objects by type or ID substring; stable ID ordering, offset/limit pagination (default 100). Follow next_offset until null." },
  get_object: { schema: z.strictObject({ id }), readOnly: true, description: "Read one sanitized game object, including numeric table keys represented as strings." },
  set_object_property: { schema: z.strictObject({ id, property: z.string().min(1).max(128), value: z.union([z.string().max(65536), z.number(), z.boolean(), z.null()]) }), readOnly: false, description: "Set a scalar property through the game's allowlisted setter. Unknown/range-invalid properties must be rejected by the game. Null is passed as Lua nil." },
  list_actions: { schema: empty, readOnly: true, description: "Discover game-registered actions and their parameter types, ranges, enums and required fields. Use before invoke_action." },
  invoke_action: { schema: z.strictObject({ action: z.string().min(1).max(128), params: z.record(z.string().max(128), z.unknown()).optional() }), readOnly: false, description: "Execute one game-defined action. Parameters are validated by the bridge for registered actions. Legacy handlers validate their own inputs." },
  get_metrics: { schema: empty, readOnly: true, description: "Read FPS, Lua memory, bridge processing time and simulation step progress without arbitrary code." },
  get_logs: { schema: z.strictObject({ after: z.number().int().min(0).max(Number.MAX_SAFE_INTEGER).optional(), limit: z.number().int().min(1).max(200).optional() }), readOnly: true, description: "Read the bounded bridge/game log ring. Pass next_cursor as after for subsequent reads. Game logs require mcp.log integration; not OS console scraping." },
  send_input: { schema: input, readOnly: false, description: "Deliver game-only virtual keyboard/mouse/text input via the optional runtime adapter. Polling games must use runtime.isDown/isMouseDown. Release held keys or send reset after testing." },
  control_game: { schema: z.strictObject({ operation: z.enum(["pause", "resume", "step"]), frames: z.number().int().min(1).max(120).optional(), dt: z.number().min(0.001).max(0.05).optional() }), readOnly: false, description: "Pause/resume simulation or advance fixed steps while paused. Step waits for completion. Requires runtime.advance in the game update loop; rendering and MCP keep running." },
  capture_screenshot: { schema: empty, readOnly: true, description: "Return an actual game-window PNG image plus dimensions, never desktop/clipboard/files. Requires enabled runtime adapter and drawing. Maximum 4 MP and 2 MiB PNG; at most twice per second." },
  save_snapshot: { schema: snapshot, readOnly: false, description: "Save JSON-only game state in one of eight in-memory slots, evicting the oldest slot if full. Uses a game snapshot provider or the object getter. Does not write files." },
  diff_snapshot: { schema: snapshot, readOnly: true, description: "Compare current state with a named snapshot; reports up to 100 added/removed/changed paths with a truncation flag. Numeric array paths use Lua's 1-based indices." },
  restore_snapshot: { schema: snapshot, readOnly: false, description: "Restore a named snapshot ONLY when the game has explicitly enabled restoration and supplied a validating restore callback. Not an automatic serialization of physics or GPU state." },
  batch: { schema: z.strictObject({ commands: z.array(z.strictObject({ command: z.enum(batchable), args: z.record(z.string(), z.unknown()).optional() })).min(1).max(16), stop_on_error: z.boolean().optional() }), readOnly: false, description: "Run up to 16 supported small commands sequentially in one bridge request. Not atomic: earlier changes remain if a later command fails. Stops on first error by default; no nested batch/Lua/restore/input/capture." },
  run_lua: { schema: z.strictObject({ code: z.string().min(1).max(16384) }), readOnly: false, description: "TRUSTED DEVELOPMENT ONLY. Best-effort instruction-limited Lua over a sanitized context copy. Not a security sandbox. Requires both client env and game opt-in; hidden by default. Prefer registered actions." },
};
function record(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new BridgeError("Expected a structured game result", "INVALID_RESPONSE");
  return value as Record<string, unknown>;
}
function textResult(value: unknown, isError = false): CallToolResult {
  const structured = value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : { result: value };
  return { content: [{ type: "text", text: JSON.stringify(structured) }], structuredContent: structured, ...(isError ? { isError: true } : {}) };
}

export function createServer(config: AppConfig, client = new Love2DClient(config)) {
  const server = new Server({ name: "love2d-mcp", version: "2.1.0" }, { capabilities: { tools: {}, resources: {} } });
  server.setRequestHandler(ListToolsRequestSchema, async () => ({
    tools: Object.entries(specs).filter(([name]) => name !== "run_lua" || config.allowRunLua).map(([name, spec]): Tool => ({
      name, description: spec.description,
      inputSchema: { ...z.toJSONSchema(spec.schema, { io: "input" }), type: "object" } as Tool["inputSchema"],
      annotations: { readOnlyHint: spec.readOnly, destructiveHint: !spec.readOnly, idempotentHint: spec.readOnly, openWorldHint: !spec.readOnly },
    })),
  }));
  const resources: Record<string, { name: string; command: string }> = {
    "love2d://status": { name: "Live game capabilities", command: "get_status" },
    "love2d://actions": { name: "Registered development actions", command: "list_actions" },
  };
  server.setRequestHandler(ListResourcesRequestSchema, async () => ({ resources: Object.entries(resources).map(([uri, r]) => ({ uri, name: r.name, mimeType: "application/json" })) }));
  server.setRequestHandler(ReadResourceRequestSchema, async (request, extra) => {
    const r = Object.hasOwn(resources, request.params.uri) ? resources[request.params.uri] : undefined;
    if (!r) throw new Error("Unknown game resource");
    const result = await client.sendCommand(r.command, {}, extra.signal);
    return { contents: [{ uri: request.params.uri, mimeType: "application/json", text: JSON.stringify(result.result) }] };
  });
  server.setRequestHandler(CallToolRequestSchema, async (request, extra) => {
    try {
      const name = request.params.name;
      const spec = Object.hasOwn(specs, name) ? specs[name] : undefined;
      if (!spec || (name === "run_lua" && !config.allowRunLua)) throw new BridgeError("Tool unavailable or disabled", "TOOL_DISABLED");
      const args = spec.schema.parse(request.params.arguments ?? {}) as Record<string, unknown>;
      if (name === "batch") {
        const parsed = args.commands as { command: string; args?: Record<string, unknown> }[];
        args.commands = parsed.map(c => ({ ...specs[c.command]!.schema.parse(c.args ?? {}) as Record<string, unknown>, command: c.command }));
      }
      const signal = AbortSignal.any([extra.signal, AbortSignal.timeout(config.timeoutMs)]);
      let response = await client.sendCommand(name, args, signal);
      if (name === "capture_screenshot") {
        let result = record(response.result);
        const ticket = z.string().min(1).parse(result.ticket);
        while (result.status === "pending") {
          await delay(40, undefined, { signal });
          response = await client.sendCommand("poll_screenshot", { ticket }, signal);
          result = record(response.result);
        }
        if (result.status !== "ready") throw new BridgeError(String(result.error ?? "Screenshot failed"), "CAPTURE_FAILED");
        const image = z.object({ data: z.string().max(2796204).regex(/^[A-Za-z0-9+/]+={0,2}$/), mimeType: z.literal("image/png"), width: z.number().int().positive(), height: z.number().int().positive() }).parse(result);
        const png = Buffer.from(image.data, "base64");
        if (png.length < 24 || png.length > 2097152 || png.subarray(0, 8).toString("hex") !== "89504e470d0a1a0a" || png.readUInt32BE(16) !== image.width || png.readUInt32BE(20) !== image.height || image.width * image.height > 4194304) {
          throw new BridgeError("Invalid or oversized PNG from game", "INVALID_IMAGE");
        }
        return { content: [{ type: "image" as const, mimeType: "image/png", data: image.data }, { type: "text" as const, text: JSON.stringify({ width: image.width, height: image.height }) }], structuredContent: { width: image.width, height: image.height, mimeType: "image/png" } };
      }
      if (name === "control_game" && args.operation === "step") {
        let state = record(response.result);
        while (typeof state.steps_remaining === "number" && state.steps_remaining > 0) {
          await delay(40, undefined, { signal });
          response = await client.sendCommand("get_metrics", {}, signal);
          state = record(record(response.result).runtime);
        }
        return textResult(state);
      }
      const partialFailure = name === "batch" && Array.isArray(record(response.result).results) && (record(response.result).results as { ok: boolean }[]).some(r => !r.ok);
      return textResult(response.result, partialFailure);
    } catch (error) {
      const code = error instanceof BridgeError ? error.code : error instanceof z.ZodError ? "INVALID_ARGUMENT" : "TOOL_ERROR";
      const message = error instanceof z.ZodError ? "Invalid arguments: " + error.issues.map(i => `${i.path.join(".")}: ${i.message}`).join("; ") : error instanceof Error ? error.message : "Tool failed";
      return textResult({ code, error: message.split(config.token).join("[redacted]") }, true);
    }
  });
  server.onclose = () => client.close();
  return { server, client };
}
