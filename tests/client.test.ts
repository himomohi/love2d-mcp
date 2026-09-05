import assert from "node:assert/strict";
import net from "node:net";
import test from "node:test";
import { Love2DClient } from "../src/love2d-client.ts";

const token = "test-token-" + "x".repeat(40);

async function withServer(
  handler: (socket: net.Socket, request: any) => void,
  run: (port: number) => Promise<void>
) {
  const server = net.createServer((socket) => {
    let buffer = "";
    socket.on("data", (chunk) => {
      buffer += chunk.toString("utf8");
      const newline = buffer.indexOf("\n");
      if (newline < 0) return;
      const request = JSON.parse(buffer.slice(0, newline));
      handler(socket, request);
    });
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  if (!address || typeof address === "string") throw new Error("No test port");
  try {
    await run(address.port);
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
}

test("handles a response split across TCP chunks", async () => {
  await withServer(
    (socket, request) => {
      const body = JSON.stringify({ request_id: request.request_id, ok: true, result: { pong: true } }) + "\n";
      socket.write(body.slice(0, 12));
      setTimeout(() => socket.end(body.slice(12)), 5);
    },
    async (port) => {
      const client = new Love2DClient({
        host: "127.0.0.1",
        port,
        token,
        timeoutMs: 1000,
        maxResponseBytes: 4096,
      });
      const response = await client.sendCommand("ping");
      assert.deepEqual(response.result, { pong: true });
    }
  );
});

test("rejects mismatched request ids", async () => {
  await withServer(
    (socket) => socket.end(JSON.stringify({ request_id: "wrong", ok: true, result: {} }) + "\n"),
    async (port) => {
      const client = new Love2DClient({
        host: "127.0.0.1",
        port,
        token,
        timeoutMs: 1000,
        maxResponseBytes: 4096,
      });
      await assert.rejects(() => client.sendCommand("ping"), /request_id/);
    }
  );
});

test("enforces response size limits", async () => {
  await withServer(
    (socket, request) =>
      socket.end(
        JSON.stringify({ request_id: request.request_id, ok: true, result: "x".repeat(5000) }) + "\n"
      ),
    async (port) => {
      const client = new Love2DClient({
        host: "127.0.0.1",
        port,
        token,
        timeoutMs: 1000,
        maxResponseBytes: 512,
      });
      await assert.rejects(() => client.sendCommand("ping"), /exceeded/);
    }
  );
});
