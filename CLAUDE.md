# Agent guidance

This repository is a security-hardened MCP bridge for LÖVE2D development.

## Architecture

- `src/index.ts` exposes MCP tools over stdio.
- `src/love2d-client.ts` sends authenticated newline-delimited JSON requests to the local game bridge.
- `game/mcp_bridge.lua` listens on loopback only and integrates with the running LÖVE2D game.
- Game state mutation is routed through explicit callbacks rather than unrestricted table access.

## Security rules

Do not weaken these defaults:

- loopback-only networking
- mandatory shared-token authentication
- request ID correlation
- bounded request/response/serialization sizes
- client, idle, and request-rate limits
- `run_lua` disabled by default
- no `love`, `os`, `io`, `package`, or `debug` in the optional Lua environment
- instruction-budget guard for optional Lua execution

Prefer adding a typed/allowlisted MCP tool or game action instead of expanding `run_lua`.

## Validation

Run:

```bash
npm run check
npm run build
npm pack --dry-run
```

Add regression tests for security-sensitive changes.
