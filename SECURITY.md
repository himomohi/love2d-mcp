# Security model

This is a **trusted local development tool**, not a network service, OS sandbox, or production-game component. Never include its token, `.env`, or active bridge in shipped games. Do not open firewall ports, tunnel the TCP listener, or bind it to a LAN address.

## Enforced defaults

The bridge binds to literal loopback (127.0.0.1 / ::1; localhost is normalized, not resolved). Every request requires a 32–256 printable-ASCII-character shared token. `setup` generates 32 random bytes as hex. Token length alone does not guarantee entropy: do not invent a predictable token. The Node client rejects reserved envelope overrides and correlates every response with an outstanding request.

Lua evaluation and snapshot restoration are disabled by default. Runtime input, control and screenshot features need explicit game-side enablement. Property and action operations call only game-registered callbacks; declaratively registered actions validate scalar types/ranges/enums before invocation. Legacy callbacks are trusted and must enforce their own allowlists. MCP annotations are descriptive hints, not access controls.

Transport, JSON parsing/encoding, output serialization, in-flight requests, connected clients, request rate, logs and snapshots have explicit limits. Invalid authentication closes the peer after a bounded error response. Unauthenticated peers expire; partial writes preserve response bytes. Requests are not automatically replayed after disconnect or timeout.

## Trust boundaries and remaining risks

* A program that can read your account's `.env`, process environment or memory can reuse the token. Loopback TCP is not encrypted and there is no OS-user authentication. Use OS account isolation/VMs for untrusted software. POSIX setup requests mode 0600; Windows ACLs must be managed by the user.
* The game and its callbacks execute with the game's OS permissions. An action can do anything its developer implemented. The bridge cannot preempt a blocking/native game callback. Do not expose filesystem, clipboard, shell, URL-launching or credential-reading callbacks.
* Logs redact the current bridge token, and sanitized object keys containing token/password/secret are masked. This is not comprehensive data-loss prevention. Only expose intentionally public development state; do not log unrelated secrets. Screenshots can reveal anything the game itself draws.
* The screenshot adapter captures the game framebuffer in memory, not the desktop. Virtual input invokes game callbacks, not OS events. Input state is shared by authenticated clients; the last authenticated disconnect clears it. Explicitly reset after a test and on focus loss.
* A timeout/cancellation may occur after a mutation executed. No rollback is implied. Batches are sequential and non-atomic. Snapshot restoration applies only the data the game deliberately validates and restores; it is not a whole-process checkpoint.
* Optional `run_lua` receives a sanitized detached context, limited libraries and a best-effort instruction guard. LuaJIT compilation is disabled for that function and the previous hook is restored. **This is not a security sandbox or a hard CPU/memory limit.** Native library work and memory allocation are not comprehensively bounded. Keep both opt-ins disabled unless all generated code is trusted; use disposable OS isolation otherwise.

## Dependencies and distribution

Install with `npm ci --ignore-scripts`; a committed lockfile records exact transitive dependencies and integrity values. CI audits production dependencies at high severity or above, but an audit is not proof of absence of malicious code or unknown vulnerabilities. Actions are SHA-pinned, checkout does not persist credentials, and CI needs read-only repository permissions.

The demo deliberately enables restoration and the visual adapter to demonstrate the toolkit. These choices do not change the library defaults. The setup helper never overwrites an existing `.env`; rotate secrets deliberately and restart both processes after rotation.

For suspected security defects, use the repository's private vulnerability-reporting channel when available. Do not post real tokens, sensitive snapshots, or private game data in public issues. No formal external security audit or vulnerability-free guarantee is claimed.
