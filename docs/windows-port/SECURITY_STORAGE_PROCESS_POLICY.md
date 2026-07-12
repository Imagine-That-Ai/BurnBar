# Windows Security, Storage, And Child-Process Policy

This note records the repaired foundation boundary for VAL-SEC-001,
VAL-SEC-004, and VAL-STORAGE-001.

## SQLCipher Credentials

- Production Windows storage must not read SQLCipher path or passphrase values
  from `OPENBURNBAR_SQLCIPHER_PATH` or `OPENBURNBAR_SQLCIPHER_PASSPHRASE`.
- `App.OnLaunched` calls `ReleaseConfigurationGuard` before configuration or
  storage composition. If either plaintext variable is present, startup fails
  closed.
- `WindowsStorageDevHost` provisions the database path from protected
  configuration or the default OpenBurnBar local app-data path, generates a
  passphrase when missing, and persists that passphrase through `IAppSecretStore`.
- Tests use injected `AppConfiguration` and secret-store instances. Those seams
  are internal test composition and are not part of release startup.

## Child Processes

All product-owned Windows child launches route through
`ChildProcessLaunchPolicy`:

| Launch id | Owner | Profile |
|---|---|---|
| `chat.direct-cli` | `ChatProcessRunner` | `Chat` |
| `chat.conpty-cli` | `ConPtyCliStream` | `Chat` |
| `cloud.oauth-browser` | `SystemBrowserLauncher` | `BrowserActivation` |
| `data.swift-engine-interim` | `SwiftEngineInterim` | `ReleaseTool` |
| `quota.claude-statusline-forwarder` | `ClaudeStatuslineHookInstaller` | `Chat` |

The policy sets `UseShellExecute=false`, clears the child environment, copies
only profile-approved runtime variables, and rejects names containing provider,
token, signing, SQLCipher, canary, or secret fragments.

OAuth browser activation is the only OS-activation case. On Windows it launches
`explorer.exe <authorization-url>` through the browser-activation profile rather
than shell-executing the URL from the OpenBurnBar process.

## Evidence

Focused tests under `windows/tests/configuration` scan `windows/app` for process
launch primitives and fail when a launch is not policy-owned. Windows host
evidence must still attach environment-dump artifacts for each launch id before
validator promotion.
