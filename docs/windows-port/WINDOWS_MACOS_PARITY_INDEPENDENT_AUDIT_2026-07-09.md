# Independent Windows Parity Audit Against macOS

**Date:** 2026-07-09
**Reference product:** shipping macOS OpenBurnBar
**Audit target:** local windows/liquid-glass-kernel-reskin checkout
**Status:** implementation complete; automated certification substantially complete; physical/manual/live-staging release gates remain

## Certification Update - 2026-07-11

The remediation plan in this audit has now been implemented through the F2
source/product ledger: 46 rows are Real, with zero DeferredApproved, Blocked,
or Substituted rows. That is implementation parity, not an unconditional public
release claim.

Current evidence materially supersedes the original source-only findings:

- Native Windows usage runtime, storage recovery, protected configuration,
  direct-process chat, settings/onboarding, activation, distribution, and the
  remaining declared parity surfaces are integrated on `main`.
- [Signed release run 29160512069](https://github.com/Imagine-That-Ai/BurnBar/actions/runs/29160512069)
  succeeded for x64 and ARM64 with unsigned output forbidden. Azure Artifact
  Signing, Authenticode verification, timestamps, checksums, Ed25519 feed,
  SBOM, OpenVEX, and Sigstore steps all passed.
- [Exact-candidate x64 run 29160940577](https://github.com/Imagine-That-Ai/BurnBar/actions/runs/29160940577)
  verified 10,476/10,476 exported blobs with zero mismatches and passed the
  Windows foundation harness and secret scan.
- [Signed hosted x64 run 29162867538](https://github.com/Imagine-That-Ai/BurnBar/actions/runs/29162867538)
  passed clean signed-MSIX registration, package identity checks, uninstall
  with absence verification, and reinstall.
- An exact `778e735a69ea9d812db87146630223ac1a3a49d7` candidate was imported into
  Windows 11 Pro ARM64 under UTM with 10,475/10,475 files verified and zero
  mismatches. The ARM64 solution build, 180 focused tests, all ten storage
  failure/recovery cases, chat evidence, and a zero-finding artifact secret scan
  passed. The evidence archive SHA-256 is
  `1a276bd023f5d6078fee4501ced80a94da9ba1db0414b774fd184fb4a843c7ad`.
- The signed ARM64 MSIX then passed clean install, responsive first launch,
  protocol activation, uninstall with absence verification, reinstall, and
  responsive final launch in the signed-in Windows 11 user session. Windows
  reported the expected publisher, `Arm64` architecture, version `1.0.29.0`,
  valid Microsoft Artifact Signing chain, and RFC 3161 timestamp.
- The physical iPhone companion built, signed, installed, and launched. Its
  suite recorded 1,240 passed, 13 failed, and 28 skipped tests, so this is
  physical compile/install evidence rather than a green-suite claim.

The committed evidence index is
[`evidence/final-certification-2026-07-11/README.md`](evidence/final-certification-2026-07-11/README.md).
The remaining blockers to a 100% certification statement are physical Windows
x64/ARM64 hardware performance and graphics coverage; Narrator, keyboard, DPI,
and high-contrast manual protocols; live staging OAuth/App Check/CloudVault and
cross-device flows; physical Computer Use/media/file-safety validation; and the
public update/rollback/Store release lifecycle. The QA checklist below remains
unchecked where a row combines any of these unproven requirements.

## Implementation Update - 2026-07-10

The foundation remediation branch implements the audit's highest-value daily-use
and distribution gaps without changing the release-certification boundary:

- A composed Windows usage runtime now discovers supported local logs, parses
  usage records, persists encrypted snapshots, and supplies flyout, dashboard,
  Atelier, command-palette, and onboarding scan surfaces from app startup.
- Settings and Updates routes now use typed controls and durable Windows
  persistence, with explicit unavailable reasons and Windows-native startup and
  update status. Onboarding performs real dependency, storage, notification,
  UI Automation, and chat-executable probes instead of placeholder readiness.
- Single-instance warm/cold activation routes URI, file, toast, startup, and
  command actions through one typed router. The WinSparkle host, bundled feed
  metadata, package images, and startup-task integration are composed into the
  app rather than remaining declaration-only assets.
- Chat executable management remains reachable after approval, durable chat and
  retrieval state use the encrypted store, Explorer restart re-registers the
  tray icon, and diagnostics can create bounded redacted support bundles.
- The foundation host harness verifies an exact exported Git candidate before
  running focused tests, process-containment checks, secret scans, route smokes,
  and interactive WinUI UI Automation in the signed-in user session.

This update is not a 1:1 parity or release claim. Signed publishing, hosted x64
evidence, physical x64/ARM64 hardware certification, production account/cloud
lifecycle, and the deeper daemon, Computer Use, and Mercury workflows retain
their independent release gates.

## Certification Harness Update - 2026-07-10

The UI automation harness now has an explicit `--certification-profile
accessibility` mode. It keeps the default smoke path fast, while adding a
machine-readable certification scenario manifest for baseline screenshots,
high-contrast rendering, reduced-transparency rendering, measured 100% DPI
captures, and the keyboard/input safety contract. High-contrast and
reduced-transparency scenarios seed the real persisted Windows appearance state
before `ThemeService` initializes, so route captures exercise production theme
composition rather than a test-only style shim.

Candidate `d8fc5675568f` has now passed exact import verification on the Windows
11 ARM64 UTM host (`10,255 / 10,255` files, zero mismatches), an ARM64 WinUI
build, `25 / 25` route/scenario captures, semantic UI Automation, and all nine
input-route contract rows. Its three DPI captures independently measured 100%
through `XamlRoot.RasterizationScale`. The compact receipt is
`docs/windows-port/evidence/accessibility-certification/host-run-d8fc567556.json`;
the external 200-file bundle is content-addressed by SHA-256
`ea53024c64534edc3fe6a731c2a9b501b0a5c04d80d74f755b15654fbe728275`.

This closes part of the certification infrastructure gap: CI and host evidence
can no longer treat generic route smoke as equivalent to accessibility/DPI
coverage. It does not replace the remaining physical-device Narrator protocol,
150%/200% DPI sweeps, high-contrast OS theme validation, or manual keyboard
certification required before a parity release claim.

## Original Executive Summary (Superseded)

The following was the audit-time finding on 2026-07-09. It is retained as the
remediation baseline and is superseded by the certification update above.

Windows is a substantial code port, but it is not at macOS product parity or
ready for a parity release. The shell, tray foundation, WinUI navigation,
visual primitives, portable parser/crypto/update cores, and x64/ARM64 unit CI
are meaningful strengths. The core daily-use path is still incomplete: fresh
installs do not create and populate a live local data plane; the tray and
dashboard are sample-or-empty; settings are largely diagnostic text;
updates/activation are declared but not shipped; and several advanced
capabilities are uncomposed or explicitly deferred.

This audit reviewed current source, current release assets, the 46-row Windows
ledger, selected Windows unit suites, and the Windows full-suite CI result.
The initial audit snapshot found the local Windows VM locked and its guest-exec
channel unavailable. The later exact-candidate receipt above supersedes that
statement for the bounded ARM64 UIA/accessibility scenarios only. Installed
release behavior, visual performance, notifications, activation, Narrator,
150%/200% DPI, OS-level high contrast, and physical x64/ARM64 hardware remain
uncertified.

The public v1.0.29 release has macOS artifacts but no Windows installer or
MSIX package. A passing scoped ledger and portable C# tests must not be
treated as end-to-end product parity evidence.

## Original Audit Evidence and Limitations (Superseded)

- The selected Windows Settings, Shell, and Dashboard suites passed: 233 tests.
- scripts/ci/verify-windows-parity-ledger.sh passed for its 46 scoped rows; its
  result validates declared blocking paths, not a clean-install product flow.
- The current PR Windows Full Suite run passed x64 and ARM64 .NET build/test
  jobs: https://github.com/Imagine-That-Ai/BurnBar/actions/runs/29027436509.
- The current checkout was windows/liquid-glass-kernel-reskin, ahead 23 and
  behind 28 commits of its upstream at audit time. Treat branch CI, release
  assets, and local source as separate facts.
- The macOS reference excludes disabled raw iCloud session mirroring. It does
  include real local aggregation, menu-bar operation, settings/onboarding,
  daemon lifecycle, update/recovery, chat, notifications, Computer Use, and
  Mercury/media behavior where supported by its distribution channel.

## Original Detailed Parity Matrix (Remediation Baseline)

| Area | What differs and why it matters | Recommended fix and implementation notes | Priority | Test steps |
|---|---|---|---|---|
| Live ingestion, tray, and dashboard | macOS discovers, parses, persists, and renders live usage. Windows configures quota acquisition, but the main flyout is sample-or-empty and Scan is explicitly a no-op. Dashboard command data is also sample-or-empty. See windows/app/OpenBurnBar.App/FlyoutWindow.xaml.cs:89-92,342-346 and Dashboard/DashboardPage.xaml.cs:101-109. The primary product value is unavailable in a normal fresh install. | Build WindowsUsageRuntime: Windows log discovery, watchers, parsers, encrypted persistence, snapshot publication, scan cancellation/progress/error/retry, and freshness metadata. Compose it into flyout, dashboard, insights, and session logs at app launch. | Critical | On a clean Windows VM with no environment variables or copied database, create Claude/Codex/Cursor activity. Verify automatic flyout/dashboard refresh and a Scan that changes persisted data. |
| Fresh-install storage, session logs, and recovery | Windows requires a pre-existing SQLCipher DB and passphrase; failure can fall back to empty data. See windows/app/OpenBurnBar.App/Storage/WindowsStorageDevHost.cs:13-34. macOS has durable aggregation and recovery UI. | Provision/migrate the database automatically, generate a protected key, repair the database picker owner window, and expose loading, no-data, invalid-key, locked-DB, migration, retry, archive/reset, and reveal-log states. | Critical | Exercise fresh install, corrupt DB, wrong key, locked file, and migration interruption. Each must expose an actionable path and recover after retry. |
| Secrets, identity, and cloud | SQLCipher passphrase, Firebase token, App Check token, and vault key persist in plaintext %LOCALAPPDATA%/OpenBurnBar/app_config.json; cloud startup is dev-token wiring rather than composed sign-in. See windows/app/OpenBurnBar.App.Configuration/AppConfiguration.cs:37-48,66-95 and AppConfigurationModel.cs:8-27. This is a credential-at-rest issue and a false production sign-in experience. | Add ISecretStore backed by DPAPI/Credential Manager, migrate and securely remove legacy values, then compose OAuth PKCE, refresh, TPM/App Check, offline queue, and sign-out cleanup. | Critical security / High feature | Assert that config, logs, diagnostics, child process environments, crash reports, and support bundles contain no secrets. Test staging sign-in, expiry, invalid App Check, offline recovery, and sign-out. |
| Chat correctness and command safety | Windows invokes cmd.exe /c, only narrowly escapes command text, and discards history. See windows/app/OpenBurnBar.App/Chat/CliProcessLineSource.cs:50-60,135-157. macOS supports persistent streamed chat, retrieval, attachments, and durable error handling. | Resolve approved executables directly. Use ProcessStartInfo.ArgumentList, stdin or structured temporary input, cancellation, output limits, persisted conversation state, and backend-unavailable UI. Eliminate shell-string construction. | Critical | Add metacharacter and quote payload regression tests, cancellation tests, streamed-error tests, restart/history tests, and attachment/paste/drop/retrieval-degradation tests. |
| Daemon, gateway, missions, and memory depth | macOS has an installed/repairable daemon lifecycle. Windows has useful portable primitives, but product settings explicitly retain gateway, headless runs, local Mission execution, watcher/planner, and connector deferrals. See windows/app/OpenBurnBar.App.Settings.ViewModels/Daemon/DaemonSettingsViewModel.cs:58-62 and DaemonSubstitutionMatrix.cs:28-53. | Decide and document a Windows service versus in-process worker. Implement authenticated IPC, durable journals, restart recovery, provider routing, mission execution, and lifecycle/recovery UI. | Critical | An approved run survives GUI close/restart, rehydrates safely, records audit state, and exposes meaningful health and error UX. |
| Settings and preferences | macOS has interactive, searchable settings with persistence. Many Windows tabs route to a generic reflection/text-dump host with in-memory/no-op defaults; Updates is static. See windows/app/OpenBurnBar.App/Settings/SettingsViewModelHostPage.xaml.cs:47-123 and UpdatesSettingsPage.xaml:28-44. | Replace generic host pages with concrete bound controls and production stores. Persist state securely; disable unavailable functions with a reason; wire every visible toggle and command. | High | Change each preference, restart, validate persistence and live effect. Test failed saves, unavailable services, and OS-disabled states. |
| Onboarding and permissions | macOS probes and refreshes real permissions. Windows system permissions are informational and chat gateway health is a placeholder. See windows/app/OpenBurnBar.App/Onboarding/Steps/SystemPermissionsStepPage.xaml.cs:6-22 and ChatEngineStepPage.xaml.cs:142-146. | Add Windows-native probes for notification registration, storage/log access, runtime dependencies, UI Automation, screen capture, and optional input components. Use Windows terminology, not copied TCC labels. | High | In a clean VM, deny, grant, revoke, restart, and recover each capability. Onboarding must never falsely report readiness. |
| Notifications, background behavior, and tray resilience | Windows has a tray foundation and a toast adapter, but live tray data, session/digest delivery, activation routing, preference persistence, Explorer restart recovery, and richer context actions are not proven or composed. See windows/app/OpenBurnBar.App/Budget/BudgetToastNotifier.cs:24-71. | Compose a notification router with the runtime. Add dedupe/rate limits, deep links, OS-disabled status, background cadence, TaskbarCreated re-registration, and Dashboard/Settings/Update tray actions. | High | Test app open/hidden/closed, sleep/wake, reboot, Explorer restart, disabled notifications, toast click/cold activation, and multi-monitor DPI. |
| Packaging, updater, URI/file/startup activation | MSIX declares protocol, file associations, startup, and toast activation, but app launch only handles route smoke then creates the tray. The updater core is unreferenced and required MSIX images are absent. See windows/packaging/msix/Package.appxmanifest:102-167 and windows/app/OpenBurnBar.App/App.xaml.cs:44-76. | Wire activation/update services, generate package assets, sign MSIX and portable artifacts, implement startup and single-instance handoff, and publish Windows release metadata/SBOM/attestations. | Critical | Clean x64 and ARM64 install; URI/file activation warm and cold; startup toggle; valid update, tampered-feed rejection, rollback, uninstall, and reinstall. |
| Computer Use, Mercury, and file transfer | macOS has approvals, audit, kill paths, media permissions, calls, mirroring, and guarded file transfer/quarantine. Windows has cores/adapters but not an end-to-end main-app capability. | After the runtime foundation, compose Windows UIA/SendInput/WGC capability checks, audit archive, kill switch/watchdog, secure-desktop denial, media permission UI, immutable outbound snapshots, and Defender/MOTW-aware inbound quarantine. | High | On physical x64 and ARM64 devices, test protected-target denial, panic halt, capture consent, Windows-to-Mac transfer/call/share, and malicious-file handling. |
| Navigation and command palette | The Windows shell is broad, but Ctrl+K has three fabricated recent sessions rather than live search/deep links. See windows/app/OpenBurnBar.App/Shell/CommandPalette.xaml.cs:80-90. | Add cancellable FTS/recency search over actual sessions/projects/memory, ranking, loading/no-results/error states, and direct record navigation. | Medium | Keyboard-only tests for populated, empty, slow, cancelled, and failing queries; verify each selected record opens. |
| Visual polish and responsiveness | Windows has Mica/Acrylic, WebView2/Win2D fallbacks, and semantic styling, but data-backed layouts and performance are unverified; no runtime screenshot/performance release gate exists. See windows/app/OpenBurnBar.App/Dashboard/DashboardPage.xaml.cs:38-82. | Establish shared semantic design tokens and loading/empty/error/offline/partial state components. Tune density, resizing, motion, and GPU fallbacks against macOS intent rather than copying macOS chrome. | High | Screenshot and pixel-diff baselines at 100/150/200% DPI, narrow/wide windows, light/dark/high-contrast, reduced motion/transparency, and disabled WebView2/Win2D. Capture frame/input/memory budgets. |
| Accessibility and keyboard | macOS has extensive annotations and Cmd shortcuts. Windows currently has limited automation metadata and mostly Ctrl+K; no UIA/Narrator interaction suite proves real accessibility. | Define accessible names/values/help, focus order, live-region announcements, Ctrl/Alt shortcuts, visible focus, high-contrast/reduced-motion behavior, and Windows UI Automation tests. | High | Narrator/manual keyboard protocol plus automated UIA tests for tray, onboarding, dashboard, settings, dialogs, palette, errors, and panic behavior. |
| Diagnostics and failure UX | macOS has recovery, redaction, archive/reset, reveal/copy diagnostics. Windows diagnostics are mostly local logs while storage failures can look like empty data. See windows/app/OpenBurnBar.App/Diagnostics/AppDiagnostics.cs:85-110. | Add redaction, bounded retention, correlation IDs, consented support bundle, data-source/native capability/updater status, and retry/repair/archive/reset controls. | High | Induce bad storage, expired auth, graphics/runtime absence, updater failure, and parser crash. Validate redaction and a usable support bundle. |
| Parity reporting and release evidence | The 46-row ledger and green .NET CI prove scoped paths, not a whole-product clean-install experience. The checkout, main CI, and public release are separate states. | Make real-device functional certification a required release artifact: fresh-install proof, screenshots, UIA, package tests, performance, security checks, and explicit residual scope. | High | Do not use a 1:1 parity label until every visible capability is functional or intentionally unavailable with a named, user-visible explanation. |

## Windows-Native Adaptation Requirements

Parity must preserve outcomes rather than imitate macOS APIs or chrome:

- Retain a notification-area tray instead of copying an NSStatusItem literally.
- Use adaptive WinUI NavigationView behavior, Windows Ctrl/Alt conventions,
  Windows privacy/UAC/UIA concepts, and Windows file/Defender handling.
- Use Windows app notifications with reliable activation routing.
- Preserve semantic spacing, density, motion, contrast, and status-state quality
  while respecting high contrast, reduced motion, and reduced transparency.

References: [Windows notification area guidance](https://learn.microsoft.com/en-us/windows/win32/shell/notification-area), [WinUI NavigationView guidance](https://learn.microsoft.com/en-us/windows/apps/develop/ui/controls/navigationview), [Windows notifications](https://learn.microsoft.com/en-us/windows/apps/develop/notifications/), and [accessibility best practices](https://learn.microsoft.com/en-us/windows/win32/winauto/accessibility-best-practices).

## Windows Parity Implementation Plan

| Sequence | Engineering work | Complexity and dependency | Acceptance criteria |
|---|---|---|---|
| 0 | Freeze misleading live labels; hide or explain incomplete capability; write the Windows runtime ADR. | M; first | Every visible control has a working action or a truthful unavailable state. |
| 1 | Security foundation: DPAPI/Credential Manager secret store, migration, secret redaction, and direct-process chat execution. | M; before cloud/chat release | No plaintext secrets or shell-injection path; security regression tests block release. |
| 2 | Native data plane: WindowsUsageRuntime, automatic DB provisioning/migration, agent-log discovery/watchers, snapshot store, recovery UI. | XL; depends on 1 | Fresh install shows real usage, sessions, quotas, and errors without developer configuration. |
| 3 | Replace generic settings/onboarding hosts with real bindings and a shared async-state component. | L; depends on 1-2 | Preferences persist and affect services; every route has loading/empty/error/retry coverage. |
| 4 | Background runtime/service: lifecycle, IPC, journal/recovery, notifications, health/status, tray integration. | XL; depends on 2 | Work survives app closure/restart when intended and fails closed when not. |
| 5 | Production cloud: OAuth PKCE, TPM/App Check, CloudVault, offline queue, account/device state. | L; depends on 1 and 4 | Real staging account lifecycle and cross-device sync pass without raw token entry. |
| 6 | Distribution: updater composition, MSIX/portable packaging, signing, activation, startup, release workflow. | L; depends on 1 and stable shell | Signed x64/ARM64 artifacts update/rollback and handle URI/file/toast activation. |
| 7 | True macOS-depth features: gateway/router, local missions, memory/project depth, Computer Use, Mercury/media/file transfer. | XL; depends on 4-5 | Each feature has end-to-end Windows host proof, not only portable-core tests. |
| 8 | Certification polish: visual baselines, performance harness, UIA/Narrator, stress/lifecycle, and physical-device test matrix. | L; spans 2-7 | Release gates produce evidence for all supported Windows configurations. |

### Shared Architecture Work

Use contract-first refactors: IUsageRuntime, ISecretStore, IActivationRouter,
INotificationRouter, and IRuntimeLifecycle. Keep UI implementations native to
each platform, while sharing domain contracts, parser vectors, state semantics,
and release acceptance fixtures between Swift and C#.

## Prioritized Remediation Roadmap

1. **P0 - release blockers:** plaintext secrets, shell-composed chat,
   fresh-install data plane, inert update/package/activation path.
2. **P1 - daily-use completeness:** real settings, onboarding probes,
   notifications, tray resilience, command-palette search, diagnostics/recovery.
3. **P2 - true feature parity:** persistent runtime/daemon, gateway/router,
   local missions, memory/project depth, Computer Use, Mercury/media.
4. **P3 - certification:** visual/performance/accessibility automation,
   hardware validation, signed distribution, and independent release evidence.

## QA Verification Checklist

- [ ] Clean Windows 11 x64 and ARM64 installation works without copied DBs,
  secrets, or developer variables.
- [ ] Agent activity updates tray, dashboard, insights, session logs, quota,
  and command palette in real time.
- [ ] Every loading, empty, error, offline, and partial state is explicit,
  recoverable, and keyboard accessible.
- [ ] Restart, sleep/wake, GUI close, Explorer restart, startup, update,
  rollback, URI, file, and toast activation work.
- [ ] Config, logs, support bundles, screenshots, and child-process
  environments contain no secrets.
- [ ] OAuth/App Check/CloudVault flows pass staging sign-in, expiry, offline
  queue, sign-out, and cross-device tests.
- [ ] UIA, Narrator, keyboard-only, high-contrast, reduced-motion, DPI, and
  screenshot tests run in CI.
- [ ] Performance is measured on real x64 and ARM64 hardware with GPU/WebView2
  fallback coverage.
- [ ] Computer Use, media, and file-transfer safety tests cover deny paths,
  permissions, panic kill, quarantine, and audit integrity.
- [ ] Release evidence contains signed artifacts, hashes, SBOM/attestations,
  install/update results, and physical-device certification.

## Conclusion

The audit's implementation plan is complete under the repository's F2 ledger,
and the signed x64/ARM64 build plus hosted x64 and ARM64 UTM foundation gates
are proven. The evidence does not yet close every row in the QA checklist.

Accordingly, the accurate current claim is: **100% source/product parity and
substantially complete automated certification, but not 100% physical release
certification**. A public parity release remains gated on the explicitly named
physical Windows, manual accessibility/display, live staging/cross-device,
advanced safety, and public lifecycle evidence above.
