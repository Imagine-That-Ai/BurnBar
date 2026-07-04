# windows/dist — signed distribution core (Phase 5)

The Windows equivalent of the macOS **signed-distribution + supply-chain** surface: the pieces
that turn a built app into a **safely updatable, signed, provenance-carrying** release. Everything
here that can be, is **portable net8.0** (no Windows deps) so it **builds + is unit-tested on the
macOS authoring host today** (`windows/tests/dist`), and the security kernel is proven on every PR
by [`.github/workflows/pr-windows-dist.yml`](../../.github/workflows/pr-windows-dist.yml).

## What lives here

| Project / file | What it is |
| --- | --- |
| `OpenBurnBar.Dist.UpdateFeed/` | The **update-feed verification kernel** (net8.0). Parses the direct-download feed, verifies a detached **Ed25519 signature over a canonical release descriptor with a PINNED key** that is *independent of the Authenticode cert*, and decides — **fail-closed** — whether an authenticated, newer release is available. The Windows analog of Sparkle's EdDSA-over-the-DMG + pinned `SUPublicEDKey`. |
| `OpenBurnBar.Dist.UpdateFeed.Tool/` | The **release-pipeline signer CLI** (`gen-key` / `derive-pubkey` / `sign-entry` / `build-feed` / `verify-feed`). Runs only in CI / offline setup — never in the shipped app — and shares the exact canonicalizer + BouncyCastle Ed25519 the client verifies with, so the CI round-trip proves the whole chain. |
| `OpenBurnBar.Dist.Hardening/` | The **DLL-load hardening** library + `HardeningPolicy` single-source-of-truth (net8.0). The runtime `SetDefaultDllDirectories` shim + the required native/managed hardening flags. See [`DLL_HARDENING.md`](DLL_HARDENING.md). |
| `props/OpenBurnBar.Windows.Hardening.props` | Managed PE-hardening props (HighEntropyVA + Deterministic), **imported by the WinUI app**. |
| `props/OpenBurnBar.Windows.NativeHardening.props` | Link-time hardening props (`/DEPENDENTLOADFLAG`, `/guard:cf`, `/HIGHENTROPYVA`, `/DYNAMICBASE`, `/NXCOMPAT`) for in-tree native `.vcxproj`. |
| `WINDOWS_RELEASE.md` | The release runbook: the pipeline, the secrets, key management, and the honest deferrals. |

The unit tests are in [`windows/tests/dist`](../tests/dist) (net10.0, xUnit); the tree-budget area
is `dist` (see [`windows/README.md`](../README.md)).

## The two independent trust roots (why this exists)

A Windows release is authenticated by **two independent keys**, exactly mirroring macOS:

1. **Authenticode** (Azure Trusted Signing / the W0 cert) authenticates the installer to
   SmartScreen + the OS loader. *Analog: macOS Developer-ID codesign.*
2. **The pinned Ed25519 update key** (`WINDOWS_UPDATE_SIGNING_KEY`) authenticates each **update
   offer** in the feed. *Analog: Sparkle's `SUPublicEDKey`.*

Because they are independent, **a compromised Authenticode cert alone cannot ship a malicious
update**: the feed entry must *also* verify under the pinned key, and the downloaded bytes must
hash to the signed `sha256`. Either check failing is **fail-closed** (never "available"). This is
the R18-adjacent supply-chain invariant the master plan requires the Windows port to preserve.

## Honest ceiling

The real MSIX/EXE build, Authenticode signing, and Store/winget submission need a **Windows
runner + the W0 Trusted-Signing tenant + code-signing cert** (procurement — Alberto). Those steps
are gated on the `WINDOWS_CODESIGN_*` / `WINDOWS_UPDATE_SIGNING_KEY` secrets in
[`openburnbar-release-windows.yml`](../../.github/workflows/openburnbar-release-windows.yml) and
emit a clear *deferred* warning when unset. What is **proven today on macOS**: the portable
update-feed kernel (`dotnet test` + an end-to-end signer round-trip), the packaging props
(`xmllint` + policy cross-check), version consistency, and workflow lint (`actionlint`).
