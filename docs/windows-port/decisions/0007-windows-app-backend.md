# WPD-0007: Windows app backend — in-process Swift Engine + net8.0 forwarding facades over the net10.0 storage/PAL stack

- **Status:** Accepted (Phase 3, WS-B0)
- **Date:** 2026-07-04
- **Contract:** `VAL-WS-B0-ARCH` (the app↔engine/data contract; gates WS-B1–B6).
- **Scope:** How the Windows WinUI app gets real data behind its surfaces —
  replacing the stub/demo/in-memory stores with real backends — and resolves the
  TFM mismatch that today prevents the app from referencing the storage + PAL
  projects that already open the Mac DB and spawn real CLI processes.

## Context

The Windows app builds, runs, and renders (proven on physical Windows, landed as
#1248), but every surface is backed by **placeholder data** because **no real
backend is wired**. A fresh grep of `windows/app` confirms the app references
**none** of `OpenBurnBar.Storage`, `OpenBurnBar.CloudSync`, `OpenBurnBar.Pal.Ipc`,
or `OpenBurnBar.Pal.Ipc.Windows` — only the dependency-free Presentation layer
(`OpenBurnBar.App.Presentation`, `OpenBurnBar.App.Settings`,
`OpenBurnBar.App.Dashboard`, `OpenBurnBar.App.Pet`) + the renderer core
(`OpenBurnBar.Particles`, `OpenBurnBar.Pretext`) + `OpenBurnBar.Pal.Overlay`
+ `OpenBurnBar.Dist.Hardening`.

The stubs that must be replaced (WS-B1–B6):

| Stub | File | Real backend |
|------|------|-------------|
| `StubCliStream` | `Cli/StubCliStream.cs` | ConPTY-backed `ICliStream` over `ConPtySession.Spawn` |
| `InMemoryBudgetRuleStore` | `Presentation/Budget/BudgetRuleStore.cs` | SQLCipher-backed `IBudgetRuleStore` over `OpenBurnBar.Storage` |
| `MissionDispatchDemoHost` | `MissionControl/MissionDispatchDemoHost.cs` | Firestore `IMissionDispatchHost` over `FirestoreRestGateway` |
| `InMemorySwitcherProfileStore` + `SwitcherSampleData` | `Presentation/Switcher/` | Encrypted Windows profile store |
| `InMemoryElderWandPersistence` + `ElderWandSampleData` | `Presentation/ElderWand/` | DPAPI/CNG-backed settings store |
| `QuotaSampleData` | `Quota/QuotaSampleData.cs` | Ported `ProviderQuotaService` |
| `InsightSampleData` | `Presentation/Insights/` | Insights data engine over Firestore |
| `SurfaceStubPage` (sessionLogs/memory/onboarding/settings) | `Shell/SurfacePageResolver.cs` | Real pages (already exist; need registration + TFM fix) |

### The gating blocker — the TFM mismatch

The WinUI app targets **`net8.0-windows10.0.19041.0`** (WinUI 3 / WindowsAppSDK
1.8). The real-backend projects that must replace the stubs target:

| Project | TFM | What it owns |
|---------|-----|-------------|
| `OpenBurnBar.Storage` | **net10.0** | SQLCipher DB open/read/write (`IConversationReadStore`, `TokenUsageWriteSeam`) |
| `OpenBurnBar.Storage.SessionLogs` | **net10.0** | Adapts `IConversationReadStore` → `ISessionLogReadSource` |
| `OpenBurnBar.Pal.Ipc` | **net10.0** | Signed-nonce mutual handshake state machine |
| `OpenBurnBar.Pal.Ipc.Windows` | windows-only | `ConPtySession`, `NamedPipePeerAuthConnector` |
| `OpenBurnBar.CloudSync` | **net8.0** | Firestore REST gateway + CloudVault + offline queue |
| `OpenBurnBar.CloudSync.AppCheck` | net8.0-class | App Check token lifecycle |
| `OpenBurnBar.CloudSync.Crypto` | net8.0-class | CloudVault E2EE |

A **net8.0-windows app cannot reference a net10.0 library** — the TFM is
downward-incompatible. `OpenBurnBar.CloudSync` (net8.0) is referenceable today;
the storage + PAL projects are not. The `StorageSessionLogReadSource` adapter's
csproj explicitly documents this: *"the net8.0-windows app cannot reference
this net10.0 adapter directly; the app↔storage TFM reconciliation is owned by
the shell-integration lane (#1203). Until then the app binds the view-model to
a sample source."*

### The three candidate architectures

1. **Host the Swift Engine in-process** via the C-ABI/UniFFI bridge (WPD-0001)
   for read/parse paths + **net8.0 forwarding facades** over the net10.0
   storage/PAL for the C#-owned write/IPC paths.
2. **Port `OpenBurnBarDaemon` to a Windows service** + named-pipe (the app
   becomes a thin RPC client over `NamedPipePeerAuthConnector`; the service
   owns the SQLCipher DB + Firestore + ConPTY).
3. **Hybrid** — Swift Engine in-process for cheap reads + a thin Windows service
   for privileged/computer-use ops.

## Decision

**Option 1 — in-process Swift Engine (C-ABI/UniFFI) for the parse/read paths +
net8.0 forwarding facades over the net10.0 storage/PAL stack, all inside the one
WinUI process. No second process, no Windows service.**

### Why in-process Swift Engine (not a daemon service)

- **The Swift Engine is already Windows-compilable.** `OpenBurnBarCore` builds
  on `windows-latest` (x64) and `windows-11-arm` (ARM64) under
  `openburnbar-engine-windows.yml`; the walking skeleton + G2 parser parity run
  natively. Hosting it in-process reuses that proven surface — a second process
  would re-wrap the same code behind an RPC boundary for zero parity gain.
- **The C-ABI/UniFFI bridge is already the sanctioned binding path** (WPD-0001).
  The Rust crates already use it; the Swift Engine's `#[uniffi::export]` surface
  is the single source of truth for Swift/Kotlin and now C#. Hosting in-process
  means the app calls the engine through the same binding, no IPC hop.
- **No daemon lifecycle to manage.** A Windows service adds install/start/stop/
  crash-recovery/credential-broker surface — all of which the macOS app avoids
  by hosting the engine in-process. The macOS daemon exists for the
  *computer-use* privileged path, not for reads/parses/quota.
- **Computer-use is WS-D, not WS-B.** The privileged paths (ViGEm/SendInput/
  UIA/WGC/overlay) are gated on the Win11-Pro validation pass and ship behind
  `#if DISTRIBUTION_MAS`-equivalent gating. WS-B is about making the *data*
  surfaces real; none of B1–B6 need a second process. A service is the heavier
  option that buys nothing for the data-wiring lanes.

### Why net8.0 forwarding facades (not bump the app to net9.0)

The net10.0 storage + PAL projects cannot be referenced by a net8.0-windows
app. Three resolution paths were considered:

| Path | Cost | Risk |
|------|------|------|
| **(a) Bump the app to net9.0-windows** | WindowsAppSDK 1.8 supports net8/net9; medium churn (csproj + package refs + test TFMs). | ARM64 WinUI on net9 is less battle-tested; the whole app moves to a newer TFM for a storage dependency. |
| **(b) net8.0 forwarding facades** | A thin net8.0 project that re-exposes the storage/PAL interfaces the app consumes, delegating to the net10.0 implementations behind a load boundary (the facade loads the net10.0 assembly at runtime OR the net10.0 project multi-targets to net8.0 too). | Lowest churn — the app stays net8.0-windows; only the storage/PAL projects add a net8.0 target. |
| **(c) Out-of-process service** | Highest — a whole new process + IPC + auth. | Defers the TFM issue by putting net10.0 code in the service, but adds the service lifecycle surface. |

**Chosen: (b) net8.0 forwarding facades via multi-targeting.** The storage +
PAL projects add a `net8.0` target to their `<TargetFrameworks>` (they are
already plain `net10.0` with no Windows TFM and zero P/Invoke — the only
Windows-specific project is `OpenBurnBar.Pal.Ipc.Windows` which stays
windows-only). The app references the **net8.0** TFM of those multi-targeted
projects. This is the `OpenBurnBar.Pal.Ipc` portable-core pattern already proven
across the port: one managed assembly, multiple TFMs, the Windows-specific
bits gated by `[SupportedOSPlatform("windows")]`.

`Microsoft.Data.Sqlite.Core` + `SQLitePCLRaw.bundle_e_sqlcipher` (WPD-0004)
already support net8.0 — the bundle ships `win-x64`, `win-arm64`, and
`osx-arm64` natives, and the managed layer is TFM-agnostic. The same
byte-compat oracle that proved the Mac DB opens on Windows (10/10,
`VAL-P0-DB-010`) runs identically on net8.0.

### What this means for B1–B6

| Lane | Real backend | How it lands under this decision |
|------|--------------|----------------------------------|
| **B1** Real CLI stream | `ConPtyStream : ICliStream` over `ConPtySession.Spawn` | App references `OpenBurnBar.Pal.Ipc.Windows` (windows-only, already net-standard-compatible); the `ConPtySession` is P/Invoke over `CreatePseudoConsole` — same binary, app-side. No TFM issue (the Windows binding targets a Windows TFM the app already is). |
| **B2** Real persistence | `SqlCipherBudgetRuleStore : IBudgetRuleStore` over `OpenBurnBar.Storage` | Storage multi-targets to net8.0; app references the net8.0 TFM. New write seams for `budget_rules`/`budget_events` (the read seam already exists). |
| **B3** Real data providers | Wire Dashboard/SessionLogs/Memory/Insights to the engine + storage | `StorageSessionLogReadSource` (net10.0 → now net8.0 too) referenced by the app; the Swift Engine provides parse/quota via the UniFFI binding. |
| **B4** Live cloud | `FirestoreRestGateway` + `WindowsAppCheckProvider` + `OfflineWriteQueue` | `OpenBurnBar.CloudSync` is already net8.0 — app references it directly. Desktop-OAuth flow for credentials; App Check token attached per request. |
| **B5** Stub nav pages | Register `MemoryPage`/`OnboardingPage`/`SettingsPage`/`SessionLogsPage` in `SurfacePageResolver` | Pure app-internal change; no TFM issue. |
| **B6** Real mission dispatch | `FirestoreMissionDispatchHost : IMissionDispatchHost` over `FirestoreRestGateway` | Same as B4 — CloudSync is net8.0. |

### What this decision does NOT change

- **The SQLCipher byte-compat contract** (WPD-0004) — the pinned
  `cipher_compatibility=4` / page 4096 / kdf 256000 / HMAC-SHA512 / PBKDF2-HMAC-SHA512
  parameters are unchanged. Multi-targeting the managed assembly does not touch
  the native bundle.
- **The CloudVault E2EE fail-closed invariant** — `OpenBurnBar.CloudSync.Crypto`
  is already net8.0-class and unchanged; B4 wires it without weakening the
  encrypted-mode write guard.
- **The App Check fail-closed gate** — `WindowsAppCheckProvider` mints tokens
  via the TPM/Platform Crypto Provider (WS-D validates the TPM path on Win11
  Pro); until then the mock attestation producer is inert and mints nothing.
- **The computer-use security invariants** — WS-D owns the privileged-path
  validation; this decision is scoped to the data-wiring lanes (B1–B6).

## Consequences

- **Multi-target storage + PAL.** `OpenBurnBar.Storage`,
  `OpenBurnBar.Storage.SessionLogs`, and `OpenBurnBar.Pal.Ipc` add `net8.0` to
  their `<TargetFrameworks>`. The Windows-only `Pal.Ipc.Windows` stays
  windows-targeted. The managed code is TFM-agnostic (no P/Invoke in the
  portable projects); the native bundle is per-RID.
- **App gains 4 new ProjectReferences:** `OpenBurnBar.Storage` (net8.0 TFM),
  `OpenBurnBar.CloudSync`, `OpenBurnBar.CloudSync.AppCheck`,
  `OpenBurnBar.Pal.Ipc.Windows`. The `.sln` and the app csproj are the shared
  files touched by this wave (one owner per the integration discipline).
- **New write seams in Storage.** `IBudgetRuleStore` (budget_rules/budget_events),
  `ISwitcherProfileStore` (switcher profiles), `IElderWandPresetPersistence`
  (settings) need storage-backed implementations. The read seam
  (`IConversationReadStore`) + `TokenUsageWriteSeam` already exist; the new seams
  follow the same `SqlCipherConnection` pattern.
- **No Windows service.** The daemon-service option (Option 2) is deferred
  past WS-D — it is only warranted if the computer-use privileged path needs
  process isolation, and that decision belongs to the WS-D validation pass, not
  WS-B.
- **The Swift Engine binding lands as a follow-up.** The UniFFI C# binding
  (WPD-0001) is the engine surface; B3 wires the app's parse/quota calls through
  it. The binding itself is generated + committed (the FFI-007 lane); B3 is the
  app-side consumer.

## Why not a Windows service (Option 2) — the explicit rejection

A Windows service owning the SQLCipher DB + Firestore + ConPTY would solve the
TFM mismatch (the service can be net10.0) and would reuse the landed named-pipe
mutual-handshake (`NamedPipePeerAuthListener`/`Connector`). But:

- **It adds a process lifecycle the macOS app doesn't have.** Install, start,
  stop, crash recovery, credential brokering, and an upgrade story (the service
  must restart on app update) — all for a data layer that is a library call on
  macOS.
- **The IPC hop is a parity tax.** Every read/write/parse round-trips over the
  named pipe; the macOS app calls the engine in-process. The G2 byte-parity
  gate proves the parse path is identical; an RPC boundary introduces
  serialization + a second copy of the handshake state machine, for no
  correctness gain.
- **Computer-use is the only path that justifies a service**, and that's WS-D's
  call — gated on the Win11-Pro validation. WS-B's data surfaces do not need
  process isolation; the SQLCipher DB is a per-user file, and the Firestore
  gateway is already a stateless HTTP client.

If WS-D finds that the computer-use privileged path (ViGEm/SendInput/UIA/WGC)
needs isolation, the service can be added **without** re-architecting the data
lanes — the named-pipe handshake is already landed, and the data surfaces stay
in-process. This decision is the minimal one that unblocks B1–B6.

## Spike (the walking proof)

The spike for this ADR is a single end-to-end real-data path through the chosen
backend: **real CLI spawn (ConPTY) → parse (Swift Engine via UniFFI) → real
storage row (SQLCipher) → a live tile.** This proves the in-process + facade
model end-to-end before B1–B6 fan out. The spike is a separate PR (the B0
deliverable).

## Evidence (to be proven by the spike + B1–B6)

- `swift build --target OpenBurnBarCore` on Windows CI (x64 + ARM64) — already
  green (run 28701335549).
- `dotnet build` of the multi-targeted `OpenBurnBar.Storage` (net8.0 + net10.0)
  on macOS — must be green (the managed assembly is TFM-agnostic).
- The spike: a real `claude --output-format stream-json` spawn via `ConPtySession`
  produces the golden event stream; the parse path writes a real row to the
  SQLCipher DB; a Dashboard tile renders from that row.
- Each B-lane's verification is its own acceptance (see the plan §3).