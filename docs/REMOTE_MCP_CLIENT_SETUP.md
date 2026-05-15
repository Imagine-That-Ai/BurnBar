# Remote MCP Client Setup

Hosted Remote MCP is available to BurnBar Pro subscribers. Use direct HTTP MCP
where the client supports it; otherwise use the local stdio shim.

## Local Shim

```bash
npm ci --prefix tools/openburnbar-mcp-remote
npm --prefix tools/openburnbar-mcp-remote run build
node tools/openburnbar-mcp-remote/lib/index.js mcp doctor
```

The shim reads the MCP access token from macOS Keychain when available, then
falls back to a `0600` file under `~/.openburnbar`. Vault keys are not written
to client config JSON.

## Installers

```bash
openburnbar mcp install codex
openburnbar mcp install claude
openburnbar mcp install droid
openburnbar mcp install kimi
openburnbar mcp install forge
openburnbar mcp install generic
```

Each installer emits deterministic config for `openburnbar-mcp-remote mcp
serve`. The direct remote endpoint is always:

```text
https://mcp.openburnbar.com/mcp
```

## Doctor

```bash
openburnbar mcp doctor
```

Doctor checks endpoint reachability, token presence, tool listing, and local
shim readiness. A failed token check means the user needs to connect/reconnect
OpenBurnBar MCP from the app or rerun the login flow.
