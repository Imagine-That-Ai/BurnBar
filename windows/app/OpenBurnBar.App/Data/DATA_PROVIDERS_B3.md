# WS-B3 data providers (storage + interim Swift)

## Wired (this branch)

| Surface | Source | Env / notes |
|---------|--------|-------------|
| Session Logs | `SqlCipherSessionLogReadSource` → `conversations` + FTS | `OPENBURNBAR_SQLCIPHER_PATH`, `OPENBURNBAR_SQLCIPHER_PASSPHRASE` |
| Dashboard (Classic stat tiles) | `TokenUsageReadSeam` aggregates on `token_usage` | Same SQLCipher env |
| Budget / Switcher / Elder Wand | B2 `SqlCipher*` stores via `WindowsStorageDevHost` | Same |

## Interim engine compute (macOS dev host)

- `SwiftEngineInterim.RunG2ParserParityAsync` shells out to `swift run --package-path OpenBurnBarCore OpenBurnBarG2ParserParity`.
- Optional: `OPENBURNBAR_CORE_PACKAGE_PATH`.
- Does **not** use `crates/burnbar-remote` UniFFI C# (`BurnBarRemote.Ffi`); that crate is remote relay transport, not the OpenBurnBar Swift Engine.

## Deferred

| Item | Reason |
|------|--------|
| In-process Swift Engine C-ABI / UniFFI from `OpenBurnBarCore` | B0 crux; needs Windows CI proof |
| `BurnBarRemote.Ffi` project reference on the WinUI app | Wrong binding per WPD; not added |
| Quota live dials | `ProviderQuotaService` not ported; Firestore quota docs need B4 sync |
| Memory cloud read/write | B4 OAuth + sync |
| Insights data engine | Template gallery only; engine deferred |
| Session Logs live CLI | B1 `ConPtyCliStream` (stub removed from primary route) |
| WinUI full `dotnet build` on macOS | XamlCompiler is Windows-only; build Presentation + Storage + tests here |

## Verification

```bash
cd windows/storage/OpenBurnBar.Storage && dotnet build
cd windows/app/OpenBurnBar.App.Presentation && dotnet build
cd windows/tests/presentation && dotnet test --no-build  # after build test proj
```