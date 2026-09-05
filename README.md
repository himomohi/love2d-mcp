# love2d-mcp — hardened fork

A security-hardened Model Context Protocol bridge for inspecting and controlling a running **LÖVE2D** game from Codex, Claude, or another MCP client.

This fork is based on `shayarnett/love2d-mcp` and keeps the original MIT license while replacing the risky open TCP + unrestricted Lua design with secure-by-default local development controls.

## What changed

| Area | Original | Hardened fork |
|---|---|---|
| TCP bind | all interfaces (`*`) | loopback only (`127.0.0.1`) |
| Authentication | none | required 32+ character shared token |
| `run_lua` | enabled | disabled by default |
| Lua globals | entire `love` table | no `love/os/io/package/debug`; opt-in context only |
| Mutations | arbitrary Lua | explicit game-defined setter/action callbacks |
| Framing | assumes one TCP chunk = one JSON response | newline framing with partial-chunk handling |
| Limits | none | request/response/client/rate/idle/serialization limits |
| Validation | minimal | Zod MCP inputs + bridge-side validation |
| Diagnostics | 3 tools | ping/status + read/mutate/action + optional Lua |
| Tests | none | security/config/TCP framing tests |
| MCP SDK | old v1 dependency | current `@modelcontextprotocol/sdk` v1.30.x |

## MCP tools

- `ping` — verify the authenticated local bridge
- `get_status` — security mode, capabilities, metadata, client count
- `list_objects` — compact sanitized scene objects
- `get_object` — sanitized object details
- `set_object_property` — only through your allowlisted setter callback
- `invoke_action` — only through your allowlisted action callback
- `run_lua` — restricted sandbox; **off by default**

## Quick start

### 1. Install

```bash
npm install
npm run build
```

### 2. Generate one token

```bash
openssl rand -hex 32
```

Set the same value as `LOVE2D_MCP_TOKEN` for both Node and the game process.

### 3. Add the bridge to your LÖVE2D project

Copy `game/mcp_bridge.lua` into your project. Wire it from `main.lua`:

```lua
local mcp = require("mcp_bridge")

function love.load()
    mcp.setObjectGetter(function()
        return gameObjects
    end)

    mcp.setObjectSetter(function(id, property, value)
        local obj = gameObjects[id]
        if not obj then return false end
        local allowed = { x = true, y = true, health = true }
        if not allowed[property] then return false end
        obj[property] = value
        return { updated = true }
    end)

    mcp.setActionHandler(function(action, params)
        if action == "restart_level" then
            restartLevel()
            return { restarted = true }
        end
        return false
    end)

    mcp.init({ port = 12345 })
end

function love.update(dt)
    mcp.update()
end

function love.quit()
    mcp.shutdown()
end
```

`mcp.init()` reads `LOVE2D_MCP_TOKEN` from the environment and refuses to start without a strong token.

### 4. Configure your MCP client

Example configuration:

```json
{
  "mcpServers": {
    "love2d": {
      "command": "node",
      "args": ["/absolute/path/to/love2d-mcp/build/index.js"],
      "env": {
        "LOVE2D_MCP_TOKEN": "your-random-token",
        "LOVE2D_MCP_HOST": "127.0.0.1",
        "LOVE2D_MCP_PORT": "12345"
      }
    }
  }
}
```

## Optional restricted `run_lua`

If you truly need Lua execution, enable it explicitly:

```lua
mcp.setLuaContextProvider(function()
    return {
        player = gameObjects.player,
        debug_flags = debugFlags,
    }
end)

mcp.init({
    port = 12345,
    allow_run_lua = true,
})
```

Executed code receives this as `context`. It does **not** receive the global `love`, `os`, `io`, `package`, or `debug` tables. The bridge also enforces an instruction budget so an accidental infinite Lua loop is interrupted instead of hanging the game indefinitely.

## Development

```bash
npm test
npm run typecheck
npm run build
```

## Security notes

This is still a privileged developer interface. Keep it local, keep the token secret, leave `run_lua` off unless required, and never ship the bridge enabled in a production game build.

See [`SECURITY.md`](SECURITY.md) for the threat model and hardening details.

## License

MIT. Original project copyright and license are preserved in `LICENSE`.
