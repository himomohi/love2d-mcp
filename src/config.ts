export interface AppConfig {
  host: string;
  port: number;
  token: string;
  timeoutMs: number;
  maxResponseBytes: number;
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): AppConfig {
  const host = env.LOVE2D_MCP_HOST ?? "127.0.0.1";
  if (host !== "127.0.0.1" && host !== "::1" && host !== "localhost") {
    throw new Error(
      "LOVE2D_MCP_HOST must be a loopback address (127.0.0.1, ::1, or localhost). " +
        "Remote binding is intentionally blocked."
    );
  }

  const token = env.LOVE2D_MCP_TOKEN ?? "";
  if (token.length < 32) {
    throw new Error(
      "LOVE2D_MCP_TOKEN is required and must contain at least 32 characters. " +
        "Use the same token in your LÖVE2D bridge configuration."
    );
  }

  const parseFrom = (name: string, fallback: number, min: number, max: number) => {
    const raw = env[name];
    if (!raw) return fallback;
    const parsed = Number.parseInt(raw, 10);
    if (!Number.isInteger(parsed) || parsed < min || parsed > max) {
      throw new Error(`${name} must be an integer between ${min} and ${max}`);
    }
    return parsed;
  };
  return {
    host,
    token,
    port: parseFrom("LOVE2D_MCP_PORT", 12345, 1, 65535),
    timeoutMs: parseFrom("LOVE2D_MCP_TIMEOUT_MS", 5000, 100, 120000),
    maxResponseBytes: parseFrom(
      "LOVE2D_MCP_MAX_RESPONSE_BYTES",
      1024 * 1024,
      1024,
      16 * 1024 * 1024
    ),
  };
}
