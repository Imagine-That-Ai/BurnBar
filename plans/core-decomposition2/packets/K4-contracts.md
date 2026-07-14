# Packet K4: extract OpenBurnBarKernelContracts (RPC/IPC + mission contracts) — FINAL Kernel-emptying
STATE: CONVERGED  LANE: Kernel-diet  DEPENDS-ON: K0, K1, K2, K3 (Platform+Models+Crypto exist)
BASELINE-TOUCHING: YES — this packet EMPTIES OpenBurnBarKernel to the umbrella file
only, so it lands the Kernel ceiling drop (185/46250 → 3/200) as a same-PR JSON edit.
BASE: origin/core-decomp2/k3 (branch core-decomp2/k4; PR base core-decomp2/k3 — K0–K3
are chained, not yet on main).
**CANON-FLAGGED** (moves the canon sources — see canon handling below).

## CONVERGENCE LOG (K4 executed)
- 30 `git mv` OpenBurnBarKernel/* -> OpenBurnBarKernelContracts/* (subdirs preserved:
  Contracts/, SharedModels/, top-level) + `git rm` ModuleMarker.swift. OpenBurnBarKernel
  now = KernelUmbrella.swift ONLY (1 file / 26 LOC).
- AE-IMPORT (compiler-demanded, 17 files): 11× `import OpenBurnBarKernelPlatform`
  (BurnBar*ID typealiases + BurnBarJSONValue live in Platform), 8× `import
  OpenBurnBarKernelModels`, 2× `import OpenBurnBarKernelCrypto` (MissionGroupContracts,
  CLIAgentResumePresentation — the named crypto consumers). ZERO `import OpenBurnBarKernel`
  / `import OpenBurnBarCore`. Contracts declared deps = [Models, Crypto]; Platform reached
  transitively (Contracts→Models→Platform), so the Platform imports resolve. Full per-file
  list in the PR body.
- CANON: repointed 3 card-named pins (generate-burnbarrpc-canon.mjs contracts+swift,
  .swiftlint.yml) PLUS 4 additional load-bearing old-path references the pre-flight grep
  surfaced (tools/schema-sync/manifest.json BurnBarProviderContracts, apps/linux-desktop
  bridgeRpcContract.test.ts, scripts/linux-port/run-ipc-cli-gateway-evidence.sh ×2). Regen
  = 116 methods, all 3 generated outputs BYTE-IDENTICAL (sha256 unchanged, git diff empty),
  `--check` exit 0. capability/coverage generator pins left untouched (per card).
- Membership: PLANNED_CEILINGS.OpenBurnBarKernel 185/46250 → 3/200 in the script + `--update`
  regenerated the baseline; check PASSES (Kernel live 1f/26L under 3/200).
- Actual Contracts size: 30 files / ~11.6k LOC (ceiling 34/13100). Matches "Expected size".
- Package.resolved churn from local boundary/daemon resolves was reverted (not part of packet).

Moves the 30 contract-tier files into `OpenBurnBarKernelContracts` and deletes its
`ModuleMarker.swift`. Deps: `OpenBurnBarKernelModels`, `OpenBurnBarKernelCrypto` (the
Contracts→Crypto edge is proven — MissionGroupContracts + CLIAgentResumePresentation
call CloudVaultCrypto / use crypto-tier types). Includes the 3 files reassigned here
from Models/Crypto: `BurnBarRunCreateMetadata.swift`, `SharedModels/FusionSessionSpend.swift`
(consume Contracts usage types), `SharedModels/CLIAgentResumePresentation.swift` (needs
Crypto + Contracts). After this packet OpenBurnBarKernel = KernelUmbrella.swift ONLY.

## Full git mv list
30 mechanical `git mv`s + marker rm. Exact list = K0-generated `mv_K4.txt`
(`buckets.json["OpenBurnBarKernelContracts"]`). Load-bearing (CANON) entries:
```
git mv OpenBurnBarCore/Sources/OpenBurnBarKernel/Contracts/BurnBarRPCContracts.swift OpenBurnBarCore/Sources/OpenBurnBarKernelContracts/Contracts/BurnBarRPCContracts.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarKernel/Contracts/BurnBarRPCIPCCanon.generated.swift OpenBurnBarCore/Sources/OpenBurnBarKernelContracts/Contracts/BurnBarRPCIPCCanon.generated.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarKernel/Contracts/MissionGroupContracts.swift OpenBurnBarCore/Sources/OpenBurnBarKernelContracts/Contracts/MissionGroupContracts.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarKernel/OpenBurnBarAgentContracts.swift OpenBurnBarCore/Sources/OpenBurnBarKernelContracts/OpenBurnBarAgentContracts.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarKernel/OpenBurnBarMissionControlContracts.swift OpenBurnBarCore/Sources/OpenBurnBarKernelContracts/OpenBurnBarMissionControlContracts.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarKernel/OpenBurnBarMissionControlMissionsContracts.swift OpenBurnBarCore/Sources/OpenBurnBarKernelContracts/OpenBurnBarMissionControlMissionsContracts.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarKernel/OpenBurnBarMissionNextActionPlanner.swift OpenBurnBarCore/Sources/OpenBurnBarKernelContracts/OpenBurnBarMissionNextActionPlanner.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarKernel/TraceContext.swift OpenBurnBarCore/Sources/OpenBurnBarKernelContracts/TraceContext.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarKernel/ClientTelemetrySanitizer.swift OpenBurnBarCore/Sources/OpenBurnBarKernelContracts/ClientTelemetrySanitizer.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarKernel/BurnBarRunCreateMetadata.swift OpenBurnBarCore/Sources/OpenBurnBarKernelContracts/BurnBarRunCreateMetadata.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/FusionSessionSpend.swift OpenBurnBarCore/Sources/OpenBurnBarKernelContracts/SharedModels/FusionSessionSpend.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/CLIAgentResumePresentation.swift OpenBurnBarCore/Sources/OpenBurnBarKernelContracts/SharedModels/CLIAgentResumePresentation.swift
# ...the remaining 18 Contracts/* files from mv_K4.txt...
git rm OpenBurnBarCore/Sources/OpenBurnBarKernelContracts/ModuleMarker.swift
```

## CANON handling (CANON-FLAGGED — do this exactly)
The canon generator + swiftlint pin the OLD kernel paths (K0-enumerated):
- `tools/ipc/generate-burnbarrpc-canon.mjs:10` `contracts:` →
  `OpenBurnBarCore/Sources/OpenBurnBarKernelContracts/Contracts/BurnBarRPCContracts.swift`
- `tools/ipc/generate-burnbarrpc-canon.mjs:13` `swift:` →
  `OpenBurnBarCore/Sources/OpenBurnBarKernelContracts/Contracts/BurnBarRPCIPCCanon.generated.swift`
- `.swiftlint.yml:153` →
  `OpenBurnBarCore/Sources/OpenBurnBarKernelContracts/Contracts/BurnBarRPCIPCCanon.generated.swift`
Update all 3 path constants in the SAME PR. Then `node tools/ipc/generate-burnbarrpc-canon.mjs`
(regen) — the WIRE NAMES must stay byte-identical (only the file PATH changed). Then
`--check` must pass. ANY wire-name diff → `git`-reverse the move, `BLOCKED(canon-drift)`
(a sibling PR race — rebase after it merges). The daemon capability/coverage paths
(BurnBarRPCCapability.swift, BurnBarDaemonSocketRPCCoverage.swift) do NOT move — leave
those two generator constants untouched.

## Allowed edit files
- `OpenBurnBarCore/Package.swift` — NONE for target deps (Contracts deps
  `[Models, Crypto]` declared at K0). No exclude edits.
- `budgets/core-target-membership-baseline.json` + `scripts/debt/check-core-target-membership-budget.sh`
  — drop the Kernel `PLANNED_CEILINGS` entry to `{ maxFiles: 3, maxLines: 200 }`
  (Kernel is now the umbrella file only), then `--update`. This is the planned final
  ratchet; enumerate in PR body.
- The 3 CANON path constants above.
- **AE-IMPORT** (EXPECTED, large): `import OpenBurnBarKernelModels` in ~15 contract
  files (they reference agent/provider/mission Models types), `import
  OpenBurnBarKernelPlatform` in ~11 (JSON/logger/identifier utils), `import
  OpenBurnBarKernelCrypto` in the 2 crypto consumers (MissionGroupContracts,
  CLIAgentResumePresentation). `import Foundation` already present. NEVER `import
  OpenBurnBarCore`. Add only what the compiler demands; enumerate every line in PR body.
- **AE-TESTABLE**: `@testable import OpenBurnBarKernelContracts` in Core tests reaching
  moved internals (anticipated: RPC canon/coverage tests, provider/agent/mission
  contract tests, MissionGroup tests, FusionSessionSpend tests, run-create tests).

## Pre-flight path-pin greps (RUN; enumerate hits)
- Canon: the 3 pins above (generate-burnbarrpc-canon.mjs ×2, .swiftlint.yml ×1).
- `.github/CODEOWNERS` — CloudVaultCrypto pin already fixed in K3; confirm no Contracts
  path is separately pinned.
- Grep `.github project.yml tools scripts` for `BurnBarRPCContracts`,
  `BurnBarRPCIPCCanon`, `MissionGroupContracts`, `OpenBurnBarAgentContracts` paths.

## Shim
None. KernelUmbrella.swift already re-exports OpenBurnBarKernelContracts (K0). After
this packet the umbrella IS the whole Kernel target.

## Forbidden actions
Same as K1. Canon: never commit a wire-name diff; path-only regen is the sole allowed
canon change.

## Validation (V-list)
Same 12-command V-list as K1, with EMPHASIS on:
- `node tools/ipc/generate-burnbarrpc-canon.mjs --check` (path-repoint proven clean).
- `cd OpenBurnBarDaemon && swift build && swift test` (the daemon is the primary RPC
  contract consumer via OpenBurnBarEngine → it must still resolve every wire name).
- membership gate: Kernel now 1 file / ~26 LOC, under the new 3/200 ceiling; all 4
  sub-targets under their ceilings.

## Expected size after K4
OpenBurnBarKernelContracts: 30 files / ~11678 LOC (ceiling 34 / 13100).
OpenBurnBarKernel: 1 file (KernelUmbrella.swift) / ~26 LOC (ceiling dropped to 3/200).
