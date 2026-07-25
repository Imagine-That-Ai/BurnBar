# Evidence — SharedUi shell (Linux-parity React shell hosted on Windows)

Ledger row: `shell-shared-ui`

## What this proves

The Windows app can render the SAME shell the Linux app renders — the
`apps/linux-desktop` React bundle, built with the Vite `windows` mode into
`apps/linux-desktop/dist-windows`, hosted in a WinUI WebView2 window
(`SharedUiHostWindow`) — because the entire command surface that bundle
speaks is now served by a C# dispatcher that is a contract-pinned peer of the
Linux Tauri backend.

Proven on the macOS authoring host (no Windows required):

- **Wire protocol.** `SharedUiBridgeMessage` / `SharedUiBridgeScript` encode
  and decode the exact envelopes `apps/linux-desktop/src/shim/tauriWebviewShim.ts`
  posts (`{kind:'invoke'|'listen'}`) and consumes
  (`invoke-result` / `channel` / `event`), including the guarded
  `window.__obbShimDispatch("...")` dispatch script with
  PretextBridge-parity JS string escaping. Tests: `SharedUiBridgeMessageTests`,
  `SharedUiBridgeScriptTests`.
- **Command contract.** `SharedUiDispatcher` routes the `LinuxShellBridge`
  command surface; unknown commands fail with the exact capability-absent
  string `not implemented on Windows` that the frontend's
  `isCapabilityAbsentError` maps to graceful degrade. Boot-critical commands
  (`runtime_capabilities`, `daemon_health`, `onboarding_*`, `subscription_*`,
  `tray_degraded`, perf, window/system actions) are host-local syntheses whose
  payloads satisfy the frontend's STRICT decoders (re-implemented invariant
  checks in `SharedUiContractTests`: the 27-id capability manifest, the
  8-step onboarding completion invariant, the snake_case subscription
  supervisor contract with constant id + strictly increasing seq).
- **Validation taxonomies.** Stripe/update URL allowlists
  (`SharedUiUrlPolicyTests`) and the gateway chat validator
  (`SharedUiGatewayChatValidatorTests`) mirror `lib.rs` error strings
  byte-for-byte (`external_url_*`, `update_url_*`, `gateway_invalid_*`,
  `gateway_request_too_large`), including the 1 MiB UTF-8 byte cap.
- **Backed data planes.** Usage, sessions (FTS + real per-session usage
  totals, never fabricated zeros), provider catalog + quota buckets, config
  snapshot, db/account/update status, proxy route log, and loopback gateway
  chat streaming are implemented over the in-process Windows stores
  (WPD-0006) in `windows/app/OpenBurnBar.App/SharedUi/WindowsSharedUiPlanes.cs`,
  which compile-checks clean on macOS against the real portable references.
- **Suite.** `dotnet test windows/tests/shared-ui` → 85/85 pass.
  Frontend regression: `apps/linux-desktop` typecheck clean, 478/478 vitest
  pass; the `dist-windows` bundle rebuilds (`vite build --mode windows`).

Not proven here (Windows-host gated, per `windows/app/DEV_HOST_RUNBOOK.md`):
the WinUI window compile, the live WebView2 navigation, and the end-to-end
render. Those are Windows CI / dev-host steps — the transport code follows
the repo's proven KernelBackdropHost/WebView2PretextHost patterns and the
fallback to the legacy XAML window is automatic when the bundle or WebView2
is unavailable.
