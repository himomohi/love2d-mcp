# LÖVE2D MCP — Runtime Toolkit 2.1

[한국어 안내](README.ko.md) · [Tool examples](EXAMPLES.md) · [Security model](SECURITY.md)

A local, authenticated MCP development bridge for LÖVE games. Discover game actions, inspect state, drive virtual input, step the simulation, capture the game window, and compare snapshots without enabling arbitrary Lua execution.

Fork of [shayarnett/love2d-mcp](https://github.com/shayarnett/love2d-mcp). The original MIT license and copyright are preserved. **Development only: do not ship the bridge or its token with a game.**

## Quick start

Requires Node.js **22.16+** and LÖVE **11.4+**. Install LÖVE separately; no engine binary is bundled.

```sh
git clone https://github.com/himomohi/love2d-mcp.git
cd love2d-mcp
npm ci --ignore-scripts
npm run setup
npm run build
npm run game
```

`setup` creates a random token in `.env` without printing it, preserves an existing file, and prints a ready-to-copy Codex MCP configuration containing absolute paths but no secret. Add that block to your Codex MCP configuration. Codex starts the stdio server; keep the game running in its own terminal. `npm start` is for manually starting the stdio server, not a second required process when Codex already manages it.

On Windows, when `love` is not on PATH:

```powershell
$env:LOVE2D_EXECUTABLE = 'C:\Program Files\LOVE\love.exe'
npm run game
```

On macOS, set `LOVE2D_EXECUTABLE` to `/Applications/love.app/Contents/MacOS/love` when needed. To run an integrated game instead of the demo, use `npm run game -- /absolute/path/to/game`.

The Node process and game must receive the **same token and port**. The launcher loads `.env`; launching `love` directly does not. Existing process environment values override Node's env-file values: clear stale `LOVE2D_MCP_*` variables when diagnosing a mismatch.

## Tools

Sixteen tools are advertised by default. Actual game capabilities are reported by `get_status`; an unconfigured capability returns a clear error rather than pretending to work.

| Purpose | Tools |
|---|---|
| Connection and discovery | `ping`, `get_status`, `list_actions` |
| Object inspection | `list_objects` (filter/search/pagination), `get_object` |
| Explicit mutations | `set_object_property`, `invoke_action` |
| Diagnostics | `get_metrics`, `get_logs` |
| Visual playtesting | `send_input`, `control_game`, `capture_screenshot` |
| State comparison | `save_snapshot`, `diff_snapshot`, `restore_snapshot` |
| Fewer round trips | `batch` |

Read-only MCP resources: `love2d://status` and `love2d://actions`. Tool schemas come from the same Zod definitions used for validation; ordinary results include both structured data and text. Screenshots return MCP **image content**, not a file path or a base64 text dump.

`run_lua` is the optional seventeenth tool. It requires **both** `LOVE2D_MCP_ALLOW_RUN_LUA=true` on the Node side and `allow_run_lua=true` in game initialization. It operates on a detached, sanitized context copy with a best-effort instruction budget. It is **not a security sandbox**. Leave it disabled for normal use.

## Integrate your own game

Copy **all three** files from `game/` into your game's Lua module path: `mcp_bridge.lua`, `mcp_json.lua`, `mcp_runtime.lua`. Do not replace your game's `main.lua` or `conf.lua` with the demo.

```lua
local mcp = require('mcp_bridge')
local runtime = require('mcp_runtime').attach(mcp, {
    input = true, control = true, screenshots = true,
})
local objects = { player = { type = 'player', x = 100, y = 100 } }

function love.load()
    mcp.setObjectGetter(function() return objects end)
    mcp.registerAction('move_player', {
        description = 'Move the player to a bounded test position.',
        params = {
            x = { type = 'number', min = 0, max = 800, required = true },
            y = { type = 'number', min = 0, max = 600, required = true },
        },
    }, function(p)
        objects.player.x, objects.player.y = p.x, p.y
        return { moved = true }
    end)
    mcp.init({ port = tonumber(os.getenv('LOVE2D_MCP_PORT')) or 12345 })
end

local function simulate(dt)
    if runtime.isDown('right') then objects.player.x = objects.player.x + 100 * dt end
    -- Your ordinary simulation update belongs here.
end
function love.update(dt)
    mcp.update() -- Keep this running while the simulation is paused.
    runtime.advance(dt, simulate)
end
function love.draw()
    love.graphics.circle('fill', objects.player.x, objects.player.y, 10)
end
function love.focus(focused) if not focused then runtime.resetInput() end end
function love.quit() mcp.shutdown() end
```

Merge these calls into existing callbacks instead of overwriting them. Virtual input invokes game callbacks only; polling code must use `runtime.isDown(key)` / `runtime.isMouseDown(button)`. The engine's global APIs are not monkeypatched, and no operating-system input is generated. `runtime.mousePosition()` is the virtual cursor position. Reset held input after each test; the last authenticated disconnect also clears it. Capabilities default off in `runtime.attach` unless explicitly enabled.

For property mutation, supply `setObjectSetter(id, property, value)` and reject unknown IDs, properties, types and ranges. Returning `false` denies an operation. `setActionHandler` remains for legacy integrations; prefer `registerAction` so agents can discover parameters and the bridge can validate them. Supported parameter types are `number`, `string`, `boolean`, with `required`, `min`/`max`, `maxLength`, and `enum` as appropriate.

Use `mcp.log('info', 'message')` for game diagnostics. Logs are explicitly integrated, not scraped from the OS console. For snapshots, `setSnapshotHandlers(read, restore)` provides JSON-only state and an optional validating restore function. Restoring also requires `allow_restore=true`. See the demo for a complete implementation.

## Limits and migration

Defaults: literal loopback binding, token required, four peers, 16 in-flight Node requests, 120 global bridge operations/second, 256 KiB requests, 4 MiB responses, bounded serialization, eight in-memory snapshots of at most 256 KiB each. Screenshot limits are 4 megapixels / 2 MiB PNG / two per second. Rendering must remain active.

Snapshots do not automatically capture Box2D, GPU resources, timers, audio or external files. Batch execution is sequential, **not atomic**: earlier mutations remain when a later one fails. Neither timeouts nor cancellation roll back an already-sent mutation. The client never automatically replays commands.

Upgrading from 2.0: update the Node server and all three Lua modules together. `list_objects` is now paginated; follow `next_offset`. Empty arrays and JSON null are preserved (`mcp.json.array()` / `mcp.json.null`). Ordinary MCP structured results are unwrapped from the TCP envelope. Existing registration callbacks remain available; add the runtime adapter only for visual playtesting features.

## Validation

```sh
npm run check
npm run build
npm pack --dry-run
lua5.1 tests/bridge.test.lua
lua5.4 tests/bridge.test.lua
luajit tests/bridge.test.lua
# Linux with LÖVE, Xvfb and LuaSocket installed:
node tests/e2e.mjs
```

CI covers Node on Linux/Windows, Lua 5.1/5.4/LuaJIT, and an actual Linux LÖVE game over MCP stdio/TCP. The `love2d-tested-package` artifact includes the rendered screenshot, E2E results and built package. Check the workflow for the exact commit's outcome. This is not a claim that every OS/engine/game combination has been tested.

References: [LÖVE screenshot API](https://love2d.org/wiki/love.graphics.captureScreenshot), [Codex MCP configuration](https://developers.openai.com/codex/mcp/), [MCP tools specification](https://modelcontextprotocol.io/specification/2025-11-25/server/tools).
