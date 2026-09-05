# Contributing

Contributions are welcome. This fork is secure-by-default: changes must not weaken loopback binding, authentication, input validation, serialization limits, or the default-disabled `run_lua` policy.

## Setup

```bash
npm install
npm run check
npm run build
```

Run the example game with the same `LOVE2D_MCP_TOKEN` used by the MCP server.

## Security invariants

A pull request must preserve these rules unless it explicitly documents and justifies a safer replacement:

- TCP bridge binds to loopback only.
- A strong shared token is required.
- Every response must correlate to a request ID.
- `run_lua` remains disabled by default.
- Restricted Lua must not expose `love`, `os`, `io`, `package`, or `debug`.
- Optional Lua execution must retain an execution budget.
- Mutations go through game-defined allowlisted callbacks.
- Request, response, serialization, client, idle, and rate limits remain bounded.
- New MCP inputs are validated on both the Node and bridge sides where applicable.

## Tests

Before opening a PR:

```bash
npm run check
npm run build
npm pack --dry-run
```

Add regression tests for protocol framing, authentication, validation, or security-sensitive behavior you change. If you modify `game/mcp_bridge.lua`, add a static or integration regression test when practical.

## Pull requests

Keep PRs focused, describe any security impact, and mention how you tested the change. Do not commit real tokens, secrets, generated build output, or `node_modules`.

All contributions are licensed under the repository's MIT License.
