import net from "node:net";
import { randomUUID } from "node:crypto";
import type { AppConfig } from "./config.js";

export interface BridgeResponse {
  request_id?: string;
  ok?: boolean;
  result?: unknown;
  error?: string;
  code?: string;
  [key: string]: unknown;
}

function createRequest(token: string, command: string, payload: Record<string, unknown> = {}) {
  return { request_id: randomUUID(), token, command, ...payload };
}

function parseResponseLine(line: string): BridgeResponse {
  const parsed: unknown = JSON.parse(line);
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error("Bridge returned a non-object JSON response");
  }
  return parsed as BridgeResponse;
}

export class BridgeError extends Error {
  readonly code?: string;

  constructor(message: string, code?: string) {
    super(message);
    this.name = "BridgeError";
    this.code = code;
  }
}

export class Love2DClient {
  private readonly config: AppConfig;

  constructor(config: AppConfig) {
    this.config = config;
  }

  async sendCommand(command: string, payload: Record<string, unknown> = {}): Promise<BridgeResponse> {
    const request = createRequest(this.config.token, command, payload);
    const encoded = `${JSON.stringify(request)}\n`;

    return await new Promise<BridgeResponse>((resolve, reject) => {
      const socket = net.createConnection({
        host: this.config.host,
        port: this.config.port,
      });

      let settled = false;
      let buffer = "";
      let receivedBytes = 0;

      const finish = (error?: Error, response?: BridgeResponse) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        socket.removeAllListeners();
        socket.destroy();
        if (error) reject(error);
        else resolve(response!);
      };

      const timer = setTimeout(() => {
        finish(new BridgeError(`Bridge request timed out after ${this.config.timeoutMs}ms`, "TIMEOUT"));
      }, this.config.timeoutMs);
      timer.unref?.();

      socket.setNoDelay(true);

      socket.once("connect", () => {
        socket.write(encoded, (err) => {
          if (err) finish(err);
        });
      });

      socket.on("data", (chunk) => {
        receivedBytes += chunk.length;
        if (receivedBytes > this.config.maxResponseBytes) {
          finish(
            new BridgeError(
              `Bridge response exceeded ${this.config.maxResponseBytes} bytes`,
              "RESPONSE_TOO_LARGE"
            )
          );
          return;
        }

        buffer += chunk.toString("utf8");
        const newline = buffer.indexOf("\n");
        if (newline < 0) return;

        const line = buffer.slice(0, newline).trim();
        if (!line) {
          finish(new BridgeError("Bridge returned an empty response", "EMPTY_RESPONSE"));
          return;
        }

        try {
          const response = parseResponseLine(line);
          if (response.request_id !== request.request_id) {
            finish(new BridgeError("Bridge response request_id did not match the request", "REQUEST_ID_MISMATCH"));
            return;
          }
          if (response.ok === false || response.error) {
            finish(new BridgeError(String(response.error ?? "Bridge command failed"), response.code));
            return;
          }
          finish(undefined, response);
        } catch (error) {
          finish(error instanceof Error ? error : new Error(String(error)));
        }
      });

      socket.once("error", (error) => finish(error));
      socket.once("end", () => {
        if (!settled) finish(new BridgeError("Bridge closed the connection before responding", "CONNECTION_CLOSED"));
      });
    });
  }
}
