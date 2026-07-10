# ADR 014: Linux provider external authentication

## Context

OpenAI Codex and Anthropic Claude Code own their browser login callbacks. The
macOS app opens those trusted CLIs in Terminal and verifies the resulting local
CLI auth state; OpenBurnBar never receives an OAuth code, verifier, callback
URL, or token. Linux previously had no equivalent native start/status/cancel
workflow, and the generic `openburnbar://` parser correctly rejected every URL
containing query or fragment material.

## Decision

Linux provider login is a daemon-owned, typed external-auth flow:

- `daemon.provider.external_auth.status` resolves the provider's browser-login
  method from `BurnBarProviderAuthRegistry` and returns only UI-safe capability,
  installation, connection, identity-label, and lifecycle state.
- `daemon.provider.external_auth.start` accepts the exact registry-returned
  provider/method pair. Only `openai/openai-codex-oauth` and
  `anthropic/anthropic-claude-code-login` are executable in this packet.
- `daemon.provider.external_auth.cancel` targets the daemon-issued flow ID.
- The daemon resolves a trusted CLI, writes a mode-0700 fixed-command launcher,
  and opens an allowlisted system terminal. A private two-phase
  started/accepted handshake prevents the CLI from spawning until the daemon
  validates the terminal attempt. The daemon enforces one five-minute flow,
  reaps the whole process group on cancellation or timeout, and verifies
  completion with `CLIAuthDiscovery`.
- Codex and Claude retain their normal `~/.codex` and `~/.claude` authority.
  OpenBurnBar does not copy credentials into provider slots or invent an
  isolated multi-account profile without a durable Linux profile-path schema.
- The Tauri and TypeScript boundaries expose no executable/config paths, argv,
  environment, terminal output, callback material, or credential fields.

The generic deep-link parser remains navigation-only. Provider OAuth callbacks
must not be added to it.

## Consequences

The Linux renderer can provide native status, refresh, sign-in, reconnect,
cancel, retry, focus, and assistive announcements without owning process or
credential state. Active polling is bound to the exact provider, method, and
flow. Route changes and renderer restarts can resume a daemon-owned flow, and a
persisted bounded grace period tolerates credentials becoming visible shortly
after the CLI exits. Missing CLI/terminal, unsupported methods, cancellation,
timeout, process failure, verification failure, and daemon restart are distinct
typed outcomes.

Only the full first-party config capability can invoke these RPCs. Read-only,
run-client, and CLI-support capability profiles remain denied.

Adding isolated provider accounts later requires a separate durable switcher
profile schema and explicit config-directory ownership. It must not reuse a
credential-slot field or leak a filesystem path into renderer state.

## Verification

Required source checks:

```bash
node tools/ipc/generate-burnbarrpc-canon.mjs --check
swift test --package-path OpenBurnBarCore --filter CLIAuthDiscoveryTests
swift test --package-path OpenBurnBarDaemon --filter BurnBarProviderExternalAuth
cargo test --manifest-path apps/linux-desktop/src-tauri/Cargo.toml --lib
npm test --prefix apps/linux-desktop -- --run \
  src/state/providerExternalAuthStore.test.ts \
  src/surfaces/settings/ProviderExternalAuthPanel.test.tsx \
  src/tauriBridge.test.ts \
  src/bridgeRpcBehavior.test.ts
npm run build --prefix apps/linux-desktop
```

Installed promotion additionally requires successful, cancelled, timed-out,
missing-CLI, terminal-close, daemon-restart, and retry flows on supported GNOME,
KDE, X11, and wlroots environments, with credential-shaped evidence scans.
