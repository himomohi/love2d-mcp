import net from "node:net";
import { randomUUID } from "node:crypto";
import type { AppConfig } from "./config.js";

export interface BridgeResponse {
  request_id: string;
  ok: boolean;
  result?: unknown;
  error?: string;
  code?: string;
}
export class BridgeError extends Error {
  readonly code: string;
  constructor(message: string, code = "BRIDGE_ERROR") {
    super(message); this.name = "BridgeError"; this.code = code;
  }
}
type Pending = {
  resolve: (value: BridgeResponse) => void;
  reject: (error: Error) => void;
  timer: ReturnType<typeof setTimeout>;
  cleanup: () => void;
};

/** Persistent, bounded, request-correlated transport. Never automatically replays a command. */
export class Love2DClient {
  private socket: net.Socket | undefined;
  private pending = new Map<string, Pending>();
  private buffer: Buffer = Buffer.alloc(0);
  private readonly config: AppConfig;

  constructor(config: AppConfig) {
    const host = config.host === "localhost" ? "127.0.0.1" : config.host;
    if (host !== "127.0.0.1" && host !== "::1") throw new BridgeError("Only loopback connections are allowed", "INVALID_HOST");
    this.config = { ...config, host };
  }

  private fail(error: Error, socket = this.socket): void {
    if (socket !== this.socket) return;
    this.socket = undefined;
    this.buffer = Buffer.alloc(0);
    socket?.destroy();
    for (const p of this.pending.values()) { clearTimeout(p.timer); p.cleanup(); p.reject(error); }
    this.pending.clear();
  }

  close(): void { this.fail(new BridgeError("Bridge client closed", "CLIENT_CLOSED")); }

  private getSocket(): net.Socket {
    if (this.socket && !this.socket.destroyed) return this.socket;
    const socket = net.createConnection({ host: this.config.host, port: this.config.port });
    this.socket = socket;
    this.buffer = Buffer.alloc(0);
    socket.setNoDelay(true);
    // Idle sockets do not keep a CLI alive. Outstanding request timers still do.
    socket.unref();
    socket.on("data", (chunk: Buffer) => {
      if (this.socket !== socket) return;
      this.buffer = Buffer.concat([this.buffer, chunk]);
      while (this.socket === socket) {
        const end = this.buffer.indexOf(10);
        const bytes = end < 0 ? this.buffer.length : end;
        if (bytes > this.config.maxResponseBytes) {
          this.fail(new BridgeError("Bridge response exceeded size limit", "RESPONSE_TOO_LARGE"), socket); return;
        }
        if (end < 0) return;
        const line = this.buffer.subarray(0, end);
        this.buffer = this.buffer.subarray(end + 1);
        try {
          const data: unknown = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(line));
          if (!data || typeof data !== "object" || Array.isArray(data)) throw new Error("Expected response object");
          const r = data as BridgeResponse;
          if (typeof r.request_id !== "string" || !this.pending.has(r.request_id)) {
            throw new BridgeError("Bridge response request_id did not match an outstanding request", "REQUEST_ID_MISMATCH");
          }
          if (typeof r.ok !== "boolean" || (r.ok && !("result" in r)) || (!r.ok && typeof r.error !== "string")) {
            throw new BridgeError("Malformed bridge response envelope", "INVALID_RESPONSE");
          }
          const p = this.pending.get(r.request_id)!;
          this.pending.delete(r.request_id); clearTimeout(p.timer); p.cleanup();
          if (r.ok) p.resolve(r);
          else p.reject(new BridgeError(r.error!, r.code));
        } catch (error) {
          this.fail(error instanceof BridgeError ? error : new BridgeError("Invalid JSON/UTF-8 response", "INVALID_RESPONSE"), socket);
          return;
        }
      }
    });
    socket.on("error", (error: NodeJS.ErrnoException) => {
      this.fail(new BridgeError(error.code === "ECONNREFUSED"
        ? "Game bridge is not running. Start the game with the same token and port."
        : `Bridge connection failed (${error.code ?? "network error"})`, error.code ?? "CONNECTION_ERROR"), socket);
    });
    socket.on("close", () => this.fail(new BridgeError("Game disconnected; the next call can reconnect. Do not blindly retry mutations.", "CONNECTION_CLOSED"), socket));
    return socket;
  }

  async sendCommand(command: string, payload: Record<string, unknown> = {}, signal?: AbortSignal): Promise<BridgeResponse> {
    if (signal?.aborted) throw new BridgeError("Request cancelled before sending", "CANCELLED");
    if (this.pending.size >= 16) throw new BridgeError("Too many outstanding requests (maximum 16)", "BUSY");
    for (const key of ["token", "request_id", "command"]) {
      if (Object.hasOwn(payload, key)) throw new BridgeError(`Reserved payload field: ${key}`, "INVALID_REQUEST");
    }
    const request = { ...payload, request_id: randomUUID(), token: this.config.token, command };
    const encoded = JSON.stringify(request) + "\n";
    if (Buffer.byteLength(encoded) - 1 > (this.config.maxRequestBytes ?? 256 * 1024)) {
      throw new BridgeError("Bridge request exceeded size limit", "REQUEST_TOO_LARGE");
    }
    const socket = this.getSocket();
    return new Promise<BridgeResponse>((resolve, reject) => {
      const cancelled = () => this.fail(new BridgeError("Request cancelled; already-sent game changes cannot be rolled back", "CANCELLED"), socket);
      const timer = setTimeout(() => this.fail(new BridgeError(
        `Bridge request timed out after ${this.config.timeoutMs}ms; a sent mutation may already have executed`, "TIMEOUT"), socket), this.config.timeoutMs);
      this.pending.set(request.request_id, { resolve, reject, timer, cleanup: () => signal?.removeEventListener("abort", cancelled) });
      signal?.addEventListener("abort", cancelled, { once: true });
      if (signal?.aborted) { cancelled(); return; }
      socket.write(encoded, (error) => { if (error) this.fail(new BridgeError("Bridge write failed", "WRITE_FAILED"), socket); });
    });
  }
}
