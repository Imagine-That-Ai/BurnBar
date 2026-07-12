# WS-B3 data providers (storage + interim Swift)

## Wired (this branch)

| Surface | Source | Policy / notes |
|---------|--------|-------------|
| Session Logs | `SqlCipherSessionLogReadSource` → `conversations` + FTS | `WindowsStorageDevHost` provisions `%LOCALAPPDATA%\OpenBurnBar\openburnbar.sqlite`; SQLCipher passphrase lives in protected storage. |
| Dashboard (Classic stat tiles) | `TokenUsageReadSeam` aggregates on `token_usage` | Same protected SQLCipher runtime. |
| Budget / Switcher / Elder Wand | B2 `SqlCipher*` stores via `WindowsStorageDevHost` | Same protected SQLCipher runtime. |
| Quota workspace | B4 CloudSyncQuotaSnapshotStore → Firestore quota_snapshots (Mac-computed); sample fallback | OPENBURNBAR_FIREBASE_UID (+ project / vault as for Memory) |

## Interim engine compute (macOS dev host)

- `SwiftEngineInterim.RunG2ParserParityAsync` shells out to `swift run --package-path OpenBurnBarCore OpenBurnBarG2ParserParity`.
- Optional: `OPENBURNBAR_CORE_PACKAGE_PATH`.
- `SwiftEngineInterim` launches through `ChildProcessLaunchPolicy` with the
  `ReleaseTool` environment allowlist.
- Does **not** use `crates/burnbar-remote` UniFFI C# (`BurnBarRemote.Ffi`); that crate is remote relay transport, not the OpenBurnBar Swift Engine.

## Deferred

| Item | Reason |
|------|--------|
| In-process Swift Engine C-ABI / UniFFI from `OpenBurnBarCore` | B0 crux; needs Windows CI proof |
| `BurnBarRemote.Ffi` project reference on the WinUI app | Wrong binding per WPD; not added |
| Quota from local SQLCipher provider_quota_snapshots | Table is populated by Swift engine only; empty on Windows without in-process binding |
| Insights data engine | Template gallery only; engine deferred |
| Session Logs live CLI | B1 `ConPtyCliStream` (stub removed from primary route) |
| WinUI full `dotnet build` on macOS | XamlCompiler is Windows-only; build Presentation + Storage + tests here |

## Verification

```bash
cd windows/storage/OpenBurnBar.Storage && dotnet build
cd windows/app/OpenBurnBar.App.Presentation && dotnet build
cd windows/tests/presentation && dotnet test --no-build  # after build test proj
```
