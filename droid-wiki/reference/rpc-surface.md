# Daemon RPC surface

`OpenBurnBarDaemon` exposes a JSON-RPC 2.0 interface over a Unix domain socket. The macOS app, CLI, and VS Code/Cursor extension all connect through this surface.

## Socket

| Property | Value |
|----------|-------|
| Path | `~/.burnbar.sock` |
| Permissions | `0o600` (owner-only) |
| Auth | Keychain-backed token sent on connect |
| Protocol | JSON-RPC 2.0, newline-delimited |

The daemon creates the socket on launch and removes it on clean shutdown. If the socket exists on startup, the daemon replaces it.

## Authentication

The client reads a short-lived token from the macOS Keychain (`service: com.openburnbar.daemon.token`) and sends it as the first line after connecting. The daemon rejects connections with invalid or missing tokens.

## Request format

```json
{"jsonrpc": "2.0", "method": "health", "params": {}, "id": 1}
```

Responses follow standard JSON-RPC 2.0: `result` on success, `error` with `code` and `message` on failure.

## Available methods

| Method | Description |
|--------|-------------|
| `health` | Returns daemon version, uptime, and connection status |
| `controller` | Queries the active agent controller state |
| `questions` | Retrieves pending agent questions for operator review |
| `followups` | Retrieves follow-up prompts from recent sessions |
| `missions` | Lists active and queued missions |
| `mission-approve` | Approves a pending mission or mission step |
| `simulator-runs` | Lists recent simulator test runs |
| `simulator-replay` | Replays a recorded simulator session |

## Quick test

```bash
echo '{"jsonrpc":"2.0","method":"health","params":{},"id":1}' | nc -U ~/.burnbar.sock
```

Requires the daemon to be running (`OpenBurnBarDaemon` process or via launchd).

## Extension wiring

The VS Code and Cursor extensions connect to the same socket. They use `mission-approve` for in-editor approval flows and `questions` to surface agent questions in the sidebar panel. See `extensions/` for the extension source.

## Error codes

| Code | Meaning |
|------|---------|
| `-32700` | Parse error — malformed JSON |
| `-32600` | Invalid request — missing required fields |
| `-32601` | Method not found |
| `-32602` | Invalid params |
| `-32000` | Auth failure |
| `-32001` | Daemon internal error |
