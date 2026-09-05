# Usage examples

These examples use the hardened tool model. Prefer read-only tools first, then explicit allowlisted mutations. `run_lua` is intentionally not required for normal workflows.

## Health and capabilities

Call `ping` to verify that the local bridge is reachable and authenticated. Call `get_status` to inspect whether mutations, actions, or optional Lua execution are enabled.

## Inspect the scene

`list_objects` returns a compact, sanitized object list. Use `get_object` with an ID for deeper sanitized details.

Example input for `get_object`:

```json
{ "id": "player" }
```

## Safe object mutation

The game decides which properties may be changed in its `setObjectSetter` callback. If the game allowlists `x`, `y`, and `health`, an MCP client can call `set_object_property`:

```json
{
  "id": "player",
  "property": "health",
  "value": 75
}
```

Properties not allowlisted by the game are rejected.

## Safe development actions

Use `invoke_action` for higher-level operations such as restarting a level, spawning a test fixture, or toggling a debug mode. The game must explicitly implement and allow each action.

```json
{
  "action": "restart_level",
  "params": {}
}
```

## Optional restricted Lua

Keep `run_lua` off unless a task cannot be expressed with normal tools. When enabled, expose only a narrow context:

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

Then Lua code sees that data under `context`:

```lua
return {
    health = context.player.health,
    invulnerable = context.debug_flags.invulnerable,
}
```

The sandbox does not receive global `love`, `os`, `io`, `package`, or `debug`, and execution is bounded by an instruction budget.

## Recommended agent workflow

1. `ping`
2. `get_status`
3. `list_objects`
4. `get_object` for relevant entities
5. use `set_object_property` or `invoke_action` only when needed
6. reserve `run_lua` for deliberate, opt-in debugging

This keeps ordinary AI-assisted development deterministic and avoids turning the bridge into an unrestricted remote code execution surface.
