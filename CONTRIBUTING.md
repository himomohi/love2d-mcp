# Contributing

Use Node.js 22.16+, `npm ci --ignore-scripts`, and `npm run check`. Commit dependency lock changes intentionally; do not run dependency install scripts by default. Preserve the original MIT license.

The server lives in `src/server.ts`, its persistent TCP client in `src/love2d-client.ts`, and configuration in `src/config.ts`. The game bridge is split across `game/mcp_bridge.lua`, `game/mcp_json.lua`, and optional `game/mcp_runtime.lua`. The demo uses explicit action/property/restore allowlists.

For changed Lua behavior, run `tests/bridge.test.lua` under Lua 5.1, 5.4 and LuaJIT. Tests use mock network/graphics adapters; `node tests/e2e.mjs` separately drives a **real LÖVE game** under Xvfb via the official MCP SDK. Do not describe mocked image tests as real-render validation. CI uploads the actual PNG and built package.

Keep loopback/authentication, request correlation, bounded buffers, default-disabled eval/restore, and explicit capability opt-ins. Do not add general shell/filesystem/clipboard access. Adding a typed registered action is preferable to expanding Lua evaluation. State clearly when a mutation is not atomic or may already have executed after a timeout.

Update English/Korean documentation and tool descriptions when behavior changes. Never commit `.env`, credentials, generated builds, screenshots containing private data, or `node_modules`. Maintain focused tests for observable behavior, not only source-code regex checks.
