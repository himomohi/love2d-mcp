export interface AppConfig {
  host: string;
  port: number;
  token: string;
  timeoutMs: number;
  maxResponseBytes: number;
  maxRequestBytes?: number;
  allowRunLua?: boolean;
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): AppConfig {
  let host = env.LOVE2D_MCP_HOST ?? "127.0.0.1";
  if (host === "localhost") host = "127.0.0.1"; // No DNS lookup for a security boundary.
  if (host !== "127.0.0.1" && host !== "::1") {
    throw new Error("LOVE2D_MCP_HOST must be a loopback address (127.0.0.1 or ::1)");
  }
  const token = env.LOVE2D_MCP_TOKEN ?? "";
  if (token.length < 32 || token.length > 256 || !/^[\x21-\x7e]+$/.test(token) || /replace-with/i.test(token)) {
    throw new Error("LOVE2D_MCP_TOKEN must be 32–256 printable ASCII characters; generate a random token, not the example placeholder");
  }
  const integer = (name: string, fallback: number, min: number, max: number) => {
    const raw = env[name];
    if (raw === undefined) return fallback;
    if (!/^\d+$/.test(raw)) throw new Error(`${name} must be an integer between ${min} and ${max}`);
    const n = Number(raw);
    if (!Number.isSafeInteger(n) || n < min || n > max) throw new Error(`${name} must be an integer between ${min} and ${max}`);
    return n;
  };
  const allow = env.LOVE2D_MCP_ALLOW_RUN_LUA ?? "false";
  if (allow !== "true" && allow !== "false") throw new Error("LOVE2D_MCP_ALLOW_RUN_LUA must be true or false");
  return {
    host, token,
    port: integer("LOVE2D_MCP_PORT", 12345, 1, 65535),
    timeoutMs: integer("LOVE2D_MCP_TIMEOUT_MS", 5000, 100, 120000),
    maxResponseBytes: integer("LOVE2D_MCP_MAX_RESPONSE_BYTES", 4 * 1024 * 1024, 1024, 16 * 1024 * 1024),
    maxRequestBytes: integer("LOVE2D_MCP_MAX_REQUEST_BYTES", 256 * 1024, 1024, 1024 * 1024),
    allowRunLua: allow === "true",
  };
}
