# Security

OpenBurnBar is designed around a local-first, zero-trust-in-the-cloud model. API keys never leave the device; P2P sessions are cryptographically authenticated; and the agent control surface has multiple independent kill switches.

## Threat model

The full threat model lives in `docs/THREAT_MODEL.md`. Key boundaries:

- **Local SQLite** is canonical — cloud compromise does not expose usage history unless the user explicitly enabled sync.
- **API keys** live in the macOS Keychain. The routed-provider gateway only receives short-lived session tokens, not permanent keys.
- **P2P sessions** use Ed25519 pairing. Both macOS and Android verify signatures before accepting iroh connections.

## Permission model

- **macOS app** — sandboxed Mac App Store build with entitlements for network and file access. The direct-download Developer ID build includes additional entitlements for Computer Use (CGEvent, Accessibility).
- **VS Code extension** — workspace-trust gating restricts `apply_patch` and `run_terminal` in untrusted workspaces, even after trust.
- **Android** — scoped storage for media saves; `MANAGE_OWN_CALLS` for the self-managed call UI.

## Audit and kill switches

- **Audit chain** — Computer Use actions are content-addressed (SHA-256). Tamper detection covers every entry.
- **Panic-kill paths** — three independent ways to stop a Computer Use session:
  1. `Ctrl+Opt+Cmd+.` global hotkey
  2. Phone three-finger long-press
  3. NSWorkspace auth gate (loginwindow / SecurityAgent / screen sleep)
  4. Remote Config `computer_use_kill_switch`

## Infrastructure security

- **CodeQL** — daily security scanning via GitHub Actions.
- **Supply chain** — `scripts/ci/verify-resilience-wiring.sh` enforces no raw `fetch` in Functions.
- **Sentry** — production callable exceptions auto-capture with structured context.
- **Secrets** — `GOOGLE_SERVICES_JSON_BASE64` and `FIREBASE_PLIST_BASE64` are injected in CI; never committed.

## Related pages

- [Computer Use](../features/computer-use.md)
- [Iroh transport](../systems/iroh-transport.md)
- [Cloud functions](../systems/cloud-functions.md)
