# Packet K3: extract OpenBurnBarKernelCrypto (key material + sealed envelopes)
STATE: CONVERGED  LANE: Kernel-diet  DEPENDS-ON: K0, K1, K2 (Platform + Models must exist)
BASELINE-TOUCHING: none (Kernel shrink non-fatal)
BASE: origin/core-decomp2/k2 (PR base core-decomp2/k2; branch core-decomp2/k3)

## CONVERGED REALITY (integrator, compile-closure)
- All 12 `git mv` renames landed (git shows 99–100% rename similarity); ModuleMarker.swift removed.
- AE-IMPORT converged to EXACTLY: `import OpenBurnBarKernelPlatform` in 5 files
  (CloudVaultCrypto, CloudVaultDeviceKeypair, EscrowDeviceSafetyCode, HermesRatchetCrypto,
  HermesRelayCrypto — all reference `PlatformCrypto`); `import OpenBurnBarKernelModels` in 4 files
  (CLIAgentSessionRecord=AssistantRuntimeID/CLIUsageSnapshot, HermesRelayAuthenticatedRequest=
  HermesRealtimeRelayPayload/HermesRelayOperation, HermesRelayCrypto=HermesRelayOperation,
  RoamingProfilePayload=ProviderID/ProviderAccountDoc/…). HermesRelayCrypto took BOTH.
  The card's predicted EscrowDeviceSafetyCode Models import was NOT needed (its only Models-name
  matches were doc-comment prose); it takes Platform only. NO Contracts/Core import anywhere.
- AE-TESTABLE converged to EXACTLY 1 file: `@testable import OpenBurnBarKernelCrypto` added to
  `Tests/OpenBurnBarCoreTests/CloudVaultCryptoTests.swift` (reached internal
  `secureRandomCopyBytes` + `resolveAADForTesting`, which moved into KernelCrypto). Every other
  card-listed AE-TESTABLE candidate compiled unchanged through the umbrella re-export (only
  public crypto symbols reached).
- UNPLANNED path-pin updates (6 files beyond CODEOWNERS — all direct consequences of the file
  move, flagged for security review; under the ≤8 limit, zero layering impact):
  `.gitleaks.toml` + `.gitleaksignore` (HermesRelayCrypto allowlist path — the file carries an
  allowlisted false-positive; the allowlist path must track the move or gitleaks re-flags it),
  `scripts/ci/verify-codeowners-security-trees.sh` REQUIRED_RULES (mirrors the CODEOWNERS pin —
  a stale required-rule path fails-closed), `scripts/privacy/scan-chat-cloud-plaintext.mjs` (5×
  CloudVaultCrypto assertIncludes path — readFileSync throws ENOENT on the old path),
  `scripts/ci/write_burnbar_source_provenance.py` + `tests/test_burnbar_source_provenance.py`
  (CloudVaultCrypto + SignalEnvelopeAAD AGPL corresponding-source paths — generator raises
  FileNotFoundError on a missing required source). Plus doc/comment path refresh:
  `docs/security/BurnBar-threat-model.md` (also fixed a pre-existing HermesRatchetCrypto stale
  path), `docs/signalification/SWARM_RUNBOOK.md`, two Android Kotlin test doc-comments.
- gitleaks note: `detect --no-git` on the moved HermesRelayCrypto.swift with the base policy
  reports "no leaks found" — the `:generic-api-key:6` fingerprint guards a finding that no longer
  fires on current content; the allowlist path was still repointed for hygiene/coherence.
- V-list: whole `swift build` ✓; `--target` KernelPlatform/Models/Crypto/Contracts/Kernel/Engine ✓;
  daemon `swift build` ✓; `OPENBURNBAR_DAEMON_LINUX_BOUNDARY_BUILD=1 swift build` ✓; whole
  `swift test` exit 0 (2003 XCTest cases, 0 failures); targeted crypto/interop filter run 129
  cases 0 failures; 3 debt gates + no-suppressions + canon `--check` all ✓. The SignalCore KAT
  suites (CryptoKitAtRestInterop / RotationHandoffKAT / OBBSignalInteropKat) are gated OFF locally
  (Vendor/libsignal not vendored in the worktree — pre-existing `signalCoreTestFallbackExcludes`),
  CI-covered; the crypto files they exercise built clean and their non-FFI tests passed.

Moves the 12 crypto-tier files into `OpenBurnBarKernelCrypto` and deletes its
`ModuleMarker.swift`. Deps: `OpenBurnBarKernelPlatform`, `OpenBurnBarKernelModels`.
Includes `CLIAgentSessionRecord.swift` (a CloudVaultCrypto CONSUMER — calls
`.sealPayload/.openPayload`, proven by grep at K0). `CLIAgentResumePresentation.swift`
was REASSIGNED to Contracts (K4) — it needs Crypto AND a Contracts type
(`BurnBarRunResumeResponse`), and only Contracts can depend on both.

## git mv list (run exactly these, from repo root)
```
git mv OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/CLIAgentSessionRecord.swift OpenBurnBarCore/Sources/OpenBurnBarKernelCrypto/SharedModels/CLIAgentSessionRecord.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/CloudVaultCrypto.swift OpenBurnBarCore/Sources/OpenBurnBarKernelCrypto/SharedModels/CloudVaultCrypto.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/CloudVaultDeviceKeypair.swift OpenBurnBarCore/Sources/OpenBurnBarKernelCrypto/SharedModels/CloudVaultDeviceKeypair.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/CloudVaultSignalEnvelopeModels.swift OpenBurnBarCore/Sources/OpenBurnBarKernelCrypto/SharedModels/CloudVaultSignalEnvelopeModels.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/EscrowDeviceSafetyCode.swift OpenBurnBarCore/Sources/OpenBurnBarKernelCrypto/SharedModels/EscrowDeviceSafetyCode.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/EscrowModels.swift OpenBurnBarCore/Sources/OpenBurnBarKernelCrypto/SharedModels/EscrowModels.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/HermesRatchetCrypto.swift OpenBurnBarCore/Sources/OpenBurnBarKernelCrypto/SharedModels/HermesRatchetCrypto.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/HermesRelayAuthenticatedRequest.swift OpenBurnBarCore/Sources/OpenBurnBarKernelCrypto/SharedModels/HermesRelayAuthenticatedRequest.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/HermesRelayCrypto.swift OpenBurnBarCore/Sources/OpenBurnBarKernelCrypto/SharedModels/HermesRelayCrypto.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/PiConnectionTypes.swift OpenBurnBarCore/Sources/OpenBurnBarKernelCrypto/SharedModels/PiConnectionTypes.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/RoamingProfilePayload.swift OpenBurnBarCore/Sources/OpenBurnBarKernelCrypto/SharedModels/RoamingProfilePayload.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/SignalEnvelopeAAD.swift OpenBurnBarCore/Sources/OpenBurnBarKernelCrypto/SharedModels/SignalEnvelopeAAD.swift
git rm OpenBurnBarCore/Sources/OpenBurnBarKernelCrypto/ModuleMarker.swift
```

## Allowed edit files
- `OpenBurnBarCore/Package.swift` — NONE expected (Crypto deps
  `[Platform, Models, swiftCryptoNonAppleDependency]` declared at K0; no exclude edits
  — Crypto compiles whole off-Apple via swiftCryptoNonAppleDependency, exactly as the
  phase-1 P-04b crypto chain did).
- **AE-IMPORT** (EXPECTED): `import OpenBurnBarKernelPlatform` in the ~5 files that use
  PlatformCrypto/PlatformLogger/SendableFileSystem (CloudVaultCrypto,
  CloudVaultDeviceKeypair, EscrowDeviceSafetyCode, HermesRelayCrypto,
  HermesRatchetCrypto); `import OpenBurnBarKernelModels` in the ~5 files that reference
  Models types (EscrowDeviceSafetyCode, HermesRelayCrypto, HermesRelayAuthenticatedRequest,
  RoamingProfilePayload, CLIAgentSessionRecord — e.g. SwitcherProfile/AgentProvider/
  TokenUsage). `import Foundation`/`import Security` already present. NEVER `import
  OpenBurnBarKernelContracts` (Crypto sits BELOW Contracts) or `OpenBurnBarCore`. If a
  Crypto file demands a Contracts type → STOP (`BLOCKED(closure)`): it belongs in
  Contracts (as CLIAgentResumePresentation did).
- **AE-TESTABLE**: `@testable import OpenBurnBarKernelCrypto` in Core tests reaching
  moved internals. Anticipated: `CloudVaultCryptoTests`, `CloudVaultRotation*Tests`,
  `EscrowDeviceSafetyCodeTests`, `EscrowModelsTests`, `HermesRatchetCryptoTests`,
  `HermesRelayCryptoTests` / `HermesRelayAuthenticatedRequestOpenerTests`,
  `PiAgentRelayContractTests`, `CLIAgentSessionCodecTests`, `SignalEnvelopeAADTests`.
  Add ONLY where compile fails.

## Pre-flight path-pin greps (RUN; enumerate hits)
- **`.github/CODEOWNERS:54`** — `OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/CloudVaultCrypto.swift @Ajnunezg @emilio3435`.
  UPDATED to `.../OpenBurnBarKernelCrypto/SharedModels/CloudVaultCrypto.swift` (the only
  CODEOWNERS Kernel crypto pin; line 51 `AgentLens/Services/CloudVaultCrypto.swift` + lines 55–56
  `OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/*Signal*/*HPKE*` are DIFFERENT paths, not
  moved by K3, left untouched).
- **CORRECTION (integrator):** the card's "confirm no OTHER moved crypto path is pinned" was
  incomplete — a full-repo path sweep found the CODEOWNERS pin is MIRRORED/consumed by 5 more
  functional gates that also hard-code the old crypto paths (see CONVERGED REALITY unplanned-file
  list). All were repointed in this PR; without them the security-pr / license-posture / privacy
  gates fail-closed on the move.
- Canon pins — none on crypto paths (BurnBarRPC* → K4); `canon --check` ✓.
- gitleaks scans EVERY commit: these are source crypto files with NO embedded secrets (key
  material is generated/loaded at runtime). HermesRelayCrypto.swift carries a pre-existing
  allowlisted false-positive; its `.gitleaks.toml` + `.gitleaksignore` allowlist PATHS were
  repointed (not the file content) so the suppression tracks the move. NOTE the PR's own gitleaks
  run uses the BASE branch's `.gitleaks.toml`/`.gitleaksignore` (security-pr.yml refuses head
  policy), so these head-branch allowlist edits take effect only once merged onto the base — the
  empirical `--no-git` check shows the finding no longer fires on current content, so no PR-time
  gitleaks failure is expected regardless.

## Shim
None. KernelUmbrella.swift already re-exports OpenBurnBarKernelCrypto (K0).

## Forbidden actions
Same as K1. No Package.swift dependency-edge additions (Crypto's deps fixed at K0).

## Validation (V-list)
Same 12-command V-list as K1 (whole build; --target KernelCrypto + Kernel + Engine;
swift test; Linux-boundary build; daemon build; 3 debt gates; no-suppressions; canon
--check). Crypto-specific: the CloudVault/Escrow/Signal interop KAT tests
(CryptoKitAtRestInterop / rotation-handoff / OBBSignal*) must stay green — they prove
wire/at-rest byte-compat survived the module split.

## Expected size after K3
OpenBurnBarKernelCrypto: 12 files / ~5172 LOC (ceiling 14 / 5900).
