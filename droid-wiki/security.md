# Security

Full threat model: [`docs/THREAT_MODEL.md`](../docs/THREAT_MODEL.md)  
Public security policy: [`SECURITY.md`](../SECURITY.md)

---

## Trust boundaries

The app, daemon, and extension all run as the logged-in user. There are no privileged helper tools. The trust boundary between components is a UNIX domain socket with filesystem ACL enforcement.

```
macOS App (AgentLens)  ←──── UNIX socket (JSON-RPC) ────→  Daemon (launchd)
       ↕                                                          ↕
  macOS Keychain                                           macOS Keychain
  Local SQLite (GRDB)                        optional: Firebase, iCloud
```

---

## Daemon socket

- Path: `~/Library/Application Support/OpenBurnBar/openburnbar-daemon.sock`
- Permissions: `0o600` — owning user only
- Auth: every RPC request carries a short-lived auth token
- Token delivery: passed via launchd `EnvironmentVariables`, not CLI arguments, to prevent exposure via `ps aux`
- The launchd plist itself is written with `0o600` permissions

---

## Secrets

- All provider API keys, Hermes/OpenClaw bearer tokens, and daemon auth tokens live in **macOS Keychain** with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
- No secrets in UserDefaults, environment variables, files, or logs
- The SQLCipher database key is Keychain-only; if the Keychain entry is lost the database is unrecoverable without a user-created recovery bundle (`DatabaseEncryptionService.exportRecoveryBundle`)

---

## Sandbox strategy

| Build channel | Sandboxed | Key differences |
|---------------|-----------|----------------|
| Mac App Store | Yes | Reads `~/` via entitlement; no Computer Use Phase 11; no bare `LaunchAgent` install |
| Developer ID (direct download) | No | Full daemon, Phase 11 Mac System CGEvent+AX, broad filesystem read |

Computer Use Phase 11 (Mac system CGEvent / Accessibility) ships **only** in the Developer ID build — it is compiled out with `#if !DISTRIBUTION_MAS`.

---

## Computer Use safety invariants

1. **Approval is the only ground truth at v1.** No silent autopilot.
2. **Trust mode is per-session; never sticky.** Session end resets trust to Manual.
3. **Three independent panic-kill paths:**
   - `⌃⌥⌘.` global hotkey
   - Phone three-finger long-press
   - NSWorkspace auth gate (loginwindow / SecurityAgent / screen sleep)
   - Remote Config `computer_use_kill_switch` (remote override)
4. **Phone can downgrade trust but not upgrade.** Upgrading from Step or Manual to Trusted requires action on the Mac. Prevents a compromised phone from escalating privileges.
5. **Audit chain is content-addressed** (SHA-256, BLAKE3-swappable). Every entry is tamper-evident including the terminal entry when `head.json` is supplied.

---

## iroh P2P security

- All iroh sessions require **Ed25519 key exchange** before any data flows
- Phone-as-controller (Phase 12): all control intents carry an Ed25519 signature validated by the daemon before execution
- Mercury media sessions: same pairing requirement; no anonymous relay connections

---

## Firebase

- **App Check** enforcement on all Cloud Function callables — requests without a valid App Check token are rejected
- Firebase Auth handles Google and Apple sign-in; OAuth redirect URIs must match `com.openburnbar.app`
- Remote MCP OAuth tokens: `functions/src/remoteMcpOAuth.ts`, grant management: `functions/src/remoteMcpGrant.ts`

---

## Supply chain

```bash
make sbom          # generates SPDX SBOM
make ci            # full CI including supply chain audit
```

The `make ci` target includes a supply chain audit step. SPDX SBOM artifacts are produced for each release.

---

## Known limitations (from SECURITY.md)

- Cost estimates use public pricing lists, not actual invoices — not for financial reconciliation
- Some parser formats require estimation; confidence is shown as "Exact" vs "Estimated"
- Non-secret settings (gateway URLs, chat model overrides) live in app preferences, not Keychain
- Cloudflare quick-tunnel for the Cursor connector expands network surface when enabled — review tunnel provider privacy policies before use
