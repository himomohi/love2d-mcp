# Security

## Threat model

`love2d-mcp` is a developer bridge that accepts commands capable of inspecting and, when explicitly configured, mutating a running game. Treat it as a privileged local debugging interface.

The hardened fork uses these defaults:

- binds only to loopback (`127.0.0.1` by default)
- requires a shared token of at least 32 characters
- disables `run_lua` by default
- does not expose `love`, `os`, `io`, `package`, or `debug` to the Lua sandbox
- routes mutations through game-defined callbacks instead of arbitrary table writes
- limits request size, response size, serialized object depth/items/string length, client count, idle time, and request rate
- correlates every request and response with a request ID

## Token handling

Set `LOVE2D_MCP_TOKEN` in the environment used to launch both the MCP server and the LÖVE2D game. Do not commit it to source control. Generate a random token, for example:

```bash
openssl rand -hex 32
```

On PowerShell:

```powershell
$bytes = New-Object byte[] 32
[Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
-join ($bytes | ForEach-Object { $_.ToString("x2") })
```

## Enabling arbitrary Lua

Do not enable `run_lua` unless you actually need it. If enabled, expose only a narrow table through `setLuaContextProvider`. The bridge intentionally does not provide the global LÖVE API to executed code. It also uses an internal debug hook to cap executed Lua instructions; if that guard is unavailable, `run_lua` refuses to run.

## Reporting vulnerabilities

Please report security issues privately to the repository owner before publishing exploit details.
