# Packet K2: extract OpenBurnBarKernelModels (pure data + catalog + Resources bundle)
STATE: DRAFT  LANE: Kernel-diet  DEPENDS-ON: K0, K1 (Platform must exist so Models's
`import OpenBurnBarKernelPlatform` resolves)
BASELINE-TOUCHING: none (Kernel shrink non-fatal)
BASE: origin/main (after K1 merges)

Moves the 90 pure-data files (Foundation-only SharedModels + Budget/Entitlements/
Membership/Metrics/Errors/Memory + catalog loader/models) **and the `Resources/`
bundle** (catalog.json + secret-pattern-corpus.json) into `OpenBurnBarKernelModels`,
deletes its `ModuleMarker.swift`, and adds `resources: [.process("Resources")]` to the
KernelModels target (the ONE allowed manifest-structure edit for K2, mirroring P-06's
Pretext resources edit). Deps: `OpenBurnBarKernelPlatform`.

Includes the 3 files REASSIGNED from the task's Platform list (they consume Models
types, so they are Models, not leaf): `Platform/CLILaunchAdapter.swift`,
`Platform/CLITerminalSessionSupervisor.swift`, `SharedModels/LinuxSubstrateSupport.swift`.

## Full git mv list
90 mechanical `git mv`s + the Resources move + marker rm. The exact enumerated list is
the K0-generated `mv_K2.txt` (regenerate identically:
`buckets.json["OpenBurnBarKernelModels"]`, src `.../OpenBurnBarKernel/<rel>`, dst
`.../OpenBurnBarKernelModels/<rel>`). Load-bearing entries called out:
```
git mv OpenBurnBarCore/Sources/OpenBurnBarKernel/OpenBurnBarCatalogLoader.swift OpenBurnBarCore/Sources/OpenBurnBarKernelModels/OpenBurnBarCatalogLoader.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarKernel/OpenBurnBarCatalog.swift OpenBurnBarCore/Sources/OpenBurnBarKernelModels/OpenBurnBarCatalog.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/CLIRuntimeModelCatalog.swift OpenBurnBarCore/Sources/OpenBurnBarKernelModels/SharedModels/CLIRuntimeModelCatalog.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/WandModelRouter.swift OpenBurnBarCore/Sources/OpenBurnBarKernelModels/SharedModels/WandModelRouter.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarKernel/Memory/MemorySecretPIIGate.swift OpenBurnBarCore/Sources/OpenBurnBarKernelModels/Memory/MemorySecretPIIGate.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/RGBA.swift OpenBurnBarCore/Sources/OpenBurnBarKernelModels/SharedModels/RGBA.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/SubstrateFamily.swift OpenBurnBarCore/Sources/OpenBurnBarKernelModels/SharedModels/SubstrateFamily.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/SwitcherProfile.swift OpenBurnBarCore/Sources/OpenBurnBarKernelModels/SharedModels/SwitcherProfile.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarKernel/SwitcherProfileStoreAdapter.swift OpenBurnBarCore/Sources/OpenBurnBarKernelModels/SwitcherProfileStoreAdapter.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarKernel/Platform/CLILaunchAdapter.swift OpenBurnBarCore/Sources/OpenBurnBarKernelModels/CLILaunchAdapter.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarKernel/Platform/CLITerminalSessionSupervisor.swift OpenBurnBarCore/Sources/OpenBurnBarKernelModels/CLITerminalSessionSupervisor.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/LinuxSubstrateSupport.swift OpenBurnBarCore/Sources/OpenBurnBarKernelModels/SharedModels/LinuxSubstrateSupport.swift
# ...78 more from mv_K2.txt...
git mv OpenBurnBarCore/Sources/OpenBurnBarKernel/Resources OpenBurnBarCore/Sources/OpenBurnBarKernelModels/Resources
git rm OpenBurnBarCore/Sources/OpenBurnBarKernelModels/ModuleMarker.swift
```

## Allowed edit files
- `OpenBurnBarCore/Package.swift`:
  - ADD `resources: [.process("Resources")]` to the `OpenBurnBarKernelModels`
    `.target(...)` block (KernelModels now owns the bundle). REMOVE the same clause
    from the `OpenBurnBarKernel` target (its Resources/ dir moved out; a stale
    `.process("Resources")` on an empty dir makes SwiftPM fail).
  - No exclude edits (arrays stay empty; Models compiles whole off-Apple).
- **BUNDLE-NAME TRANSITION (the K2 payoff-hazard, docs/CORE_DECOMPOSITION_PROGRAM.md).**
  Moving Resources/ renames the SwiftPM bundle
  `OpenBurnBarCore_OpenBurnBarKernel.bundle` → `OpenBurnBarCore_OpenBurnBarKernelModels.bundle`.
  `Bundle.module` inside the loaders (OpenBurnBarCatalogLoader / MemorySecretPIIGate,
  which MOVE with the bundle) resolves correctly to the new name automatically — NO
  loader edit needed. The EXTERNAL name-pins the daemon stages at runtime must accept
  BOTH names during the transition. Stage the new bundle IN ADDITION to the old:
  - `AgentLens/Services/OpenBurnBarDaemon/OpenBurnBarDaemonManager.swift:691`
    `kernelResourceBundleName` — change the single constant into an ordered list
    `["OpenBurnBarCore_OpenBurnBarKernelModels.bundle", "OpenBurnBarCore_OpenBurnBarKernel.bundle"]`
    and update the resolver/manager (`:254`, `OpenBurnBarDaemonBinaryResolver.swift:126`)
    to try each name. New name FIRST.
  - `scripts/build-macos-website-release.sh:167-168`,
    `scripts/ci/smoke-openburnbar-release-dmg.sh:126,129,131`,
    `.github/workflows/release.yml:1163-1164` — stage/verify BOTH bundle names
    (copy new; accept either in smoke). These are shell edits enumerated in the PR body.
  - `tools/openburnbar-mcp/ministry.py:29`, `select_wand_models.py:38`,
    `tests/test_ministry.py:22` — repoint the SOURCE catalog path
    `OpenBurnBarKernel/Resources/catalog.json` →
    `OpenBurnBarKernelModels/Resources/catalog.json`.
  - STALE-COMMENT fix: `OpenBurnBarCatalogLoader.swift:5-7` claims `Bundle.module`
    resolves to `OpenBurnBarCore_OpenBurnBarCore.bundle` — it is wrong (it resolves to
    the package_target name). Correct the prose to the new
    `OpenBurnBarCore_OpenBurnBarKernelModels.bundle` while the file is in-hand.
- **TokenUsage↔FusionUsageRow micro-edit (the ONE documented leaf-boundary wart).**
  `SharedModels/TokenUsage.swift` (stays in Models) references
  `FusionUsageRow.fusionParentPrefix` (`= "elderwand-"`); `FusionUsageRow` moves to
  Contracts (K4) because FusionSessionSpend consumes Contracts usage types. To keep
  Models buildable independently of Contracts, inline the literal at the TokenUsage
  use-site (`parentRequestID?.hasPrefix("elderwand-")`) OR add a Models-local
  `enum FusionParentPrefix { static let value = "elderwand-" }`. 1-line mechanical
  edit; enumerate in PR body. (If deferred, K2 must land AFTER K4 — prefer the inline.)
- **AE-IMPORT** (EXPECTED, add only what the compiler demands): `import
  OpenBurnBarKernelPlatform` in the ~4 files a K0 scan flagged (`Metrics/
  OpenBurnBarMetrics.swift`, `CLILaunchAdapter.swift`,
  `SharedModels/ProviderAccountDeviceLinkTypes+Generated.swift`,
  `SharedModels/ProviderQuotaTypes.swift`) — they reference Platform types
  (PlatformLogger/PlatformCrypto/JSON/identifier utils). Never `import
  OpenBurnBarKernelCrypto`/`Contracts`/`OpenBurnBarCore`.
- **AE-TESTABLE**: `@testable import OpenBurnBarKernelModels` in Core tests reaching
  moved internals (anticipated: catalog/PII/budget/entitlement/gated-feature/
  provider-quota/switcher-profile tests). Add ONLY where compile fails.

## Pre-flight path-pin greps (RUN; enumerate hits)
- Bundle pins (K0-enumerated): the 5 files above under BUNDLE-NAME TRANSITION.
- `.github/CODEOWNERS` — no Models-file pins (CloudVaultCrypto is K3).
- Canon pins — none on Models paths (BurnBarRPC* are K4).

## Shim
None. KernelUmbrella.swift already re-exports OpenBurnBarKernelModels (K0).

## Forbidden actions
Same as K1. Additionally: a `Bundle.module` file appearing in the mv list OUTSIDE the
Resources move that resolves to a THIRD bundle → `BLOCKED(resource-bundle)`.

## Validation (V-list)
Same 12-command V-list as K1 (swift build whole; --target KernelModels + Kernel +
Engine; swift test; Linux-boundary build; daemon build; 3 debt gates; no-suppressions;
canon --check) PLUS `cd OpenBurnBarDaemon && swift build && swift test` if the daemon
manager bundle-list change is in scope, and re-run
`tools/openburnbar-mcp/tests/test_ministry.py` after the catalog-path repoint.
Bundle-transition check: build the app, confirm the daemon loads the catalog from the
NEW bundle name (and still tolerates the old).

## Expected size after K2
OpenBurnBarKernelModels: 90 files / ~23785 LOC (ceiling 95 / 24600).
