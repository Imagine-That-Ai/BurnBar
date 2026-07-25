# SharedUi host — the Linux shell, rendered on Windows

**Status:** landed (dispatcher + transport + backing planes; WinUI compile is Windows-host gated per
[`windows/app/DEV_HOST_RUNBOOK.md`](../../windows/app/DEV_HOST_RUNBOOK.md)) · **Ledger row:**
`shell-shared-ui` ([`WINDOWS_PARITY_LEDGER.yml`](WINDOWS_PARITY_LEDGER.yml)) · **Evidence:**
[`evidence/f1-depth/shared-ui-shell.md`](evidence/f1-depth/shared-ui-shell.md)

The Windows app presents the **same shell the Linux desktop app presents** — literally the same
React bundle — instead of a separately-skinned XAML lookalike. One UI codebase
(`apps/linux-desktop`) is the visual source of truth for both desktop shells; the Windows app
hosts it in a WebView2 and serves its entire backend contract in C#.

## Architecture

```
apps/linux-desktop  (React + Vite; visual source of truth)
  │  vite build --mode windows  →  apps/linux-desktop/dist-windows/
  │  aliases @tauri-apps/api/* → src/shim/tauriWebviewShim.ts
  ▼
SharedUiHostWindow (WinUI, windows/app/OpenBurnBar.App/SharedUi/)
  WebView2 → https://shared.openburnbar.invalid/index.html
  (bundle shipped as app content under Resources/SharedUi/)
  │  chrome.webview.postMessage: { kind:'invoke', id, command, args }
  ▼
SharedUiDispatcher (windows/app/OpenBurnBar.App.SharedUi — portable net8.0)
  routes the ~80-command LinuxShellBridge surface
  │  replies via window.__obbShimDispatch({ kind:'invoke-result'|'channel'|'event', ... })
  ▼
Windows backing planes (windows/app/OpenBurnBar.App/SharedUi/WindowsSharedUiPlanes.cs)
  SQLCipher store · session-log FTS · quota acquisition · gateway routes ·
  loopback model proxy · OAuth credentials · WinSparkle updater · process actions
```

This is the C# peer of the Linux Tauri backend (`apps/linux-desktop/src-tauri/src/lib.rs`):
same command names, same wire casings, same error-string taxonomy, same strict-decoder
payloads. The single-process Windows backend (WPD-0006) means there is no daemon to proxy;
commands are answered from the in-process stores instead.

## Command backing tiers

| Tier | Commands | Backing |
|---|---|---|
| Boot-critical, host-local | `runtime_capabilities`, `daemon_health`, `onboarding_snapshot/action/reset`, `subscription_start/resume/stop`, `tray_degraded`, `record_perf_sample`, `measure_perf_operation`, `open_dashboard`, `quit_app`, `session_env` | Synthesized in the library; payloads satisfy the frontend's strict decoders (pinned by `SharedUiContractTests`) |
| Data reads | `usage_summary/insights/calendar`, `session_list/search`, `provider_catalog`, `config_snapshot` (+`config_update` privacy booleans), `db_status`, `account_status`, `update_status`, `app_version_info`, `export_diagnostics`, `proxy_route_log_recent/clear`, `database_workspace_status` (never-reject error bundle) | In-process stores: `token_usage` (incl. `TokenUsageReadSeam.LoadSessionTotals` for real per-session totals), session-log FTS, quota coordinator, ElderWand route projection, OAuth provider, WinSparkle status, support-bundle builder |
| Chat gateway | `gateway_probe`, `gateway_chat_stream` (Channel SSE, lib.rs taxonomy + 16 MiB cap + UTF-8 boundary handling), `gateway_chat_cancel` | `LocalHttpGatewayHost` loopback proxy. Streaming only — thread persistence (`chat_thread_list`, `chat_thread_get`, `chat_message_append`) is **not** served, so `chat.gateway` stays `unavailable` and the shared Chat surface stays gated behind the native Chat window |
| OS integration | `open_external_url` (Stripe allowlist), `open_update_url` (signed-channel allowlist) | `SharedUiUrlPolicy` mirror + `ChildProcessLaunchPolicy` |
| Capability-absent | everything else (media, computer-use, missions, memory, projects, notifications, integrations, membership, provider mutations, pet) | `"not implemented on Windows: <command>"` → the frontend's `isCapabilityAbsentError` graceful-degrade path. Never fabricated data |

The `runtime_capabilities` manifest is the honesty surface: ids backed by real Windows data are
`available`/`degraded`; daemon-only lanes are `unavailable` with a reason + substitute, so the
shell renders the designed blocked panels instead of erroring.

## Window policy

`ShowMainWindow()` (tray Open, flyout "Open full window") opens the **SharedUiHostWindow** when
`SharedUiHostWindow.IsAvailable` (bundle present + WebView2 not env-disabled), otherwise the
legacy XAML `MainWindow` — an automatic, logged fallback, never a dead end. The legacy window
also remains the host for XAML-route automation (`--route-smoke`), the protocol-activation
route keys, and the XAML command palette; the SharedUi shell carries its own in-page palette.
The window is sized 1280×840 (Linux `tauri.conf.json`), carries the same glass title bar as
`MainWindow`, and pushes the app theme into the web content via
`CoreWebView2.Profile.PreferredColorScheme`.

## Failure honesty

- Bundle missing → fallback to the legacy window at launch; publish **fails closed**
  (`RequireOpenBurnBarSharedUiBundle` target).
- WebView2 init/navigation failure → in-window panel with the reason + a button to the legacy
  window (`Failed` event mirrors `KernelBackdropHost`).
- WebView2 disabled via `OPENBURNBAR_DISABLE_WEBVIEW2` → the `NativeCapability` gate fails over
  to the legacy window.
- Storage in typed recovery → `daemon_health.ok:false`, `usage.read`/`sessions.read`
  `unavailable`, `tray_degraded:true` — the shell renders its offline notices, no mock data.

## Inner loop

```bash
# Rebuild the shared bundle (required after any apps/linux-desktop change)
cd apps/linux-desktop && node_modules/.bin/vite build --mode windows

# macOS authoring host: library + contract tests
dotnet build windows/app/OpenBurnBar.App.SharedUi
dotnet test windows/tests/shared-ui

# Windows host: build/run the app (see windows/app/DEV_HOST_RUNBOOK.md)
```

`apps/linux-desktop/dist-windows/` is git-ignored build output; CI/release must run the vite
build before `dotnet publish` (the publish target errors otherwise).
