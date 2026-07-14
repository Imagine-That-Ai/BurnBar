// SPDX-License-Identifier: AGPL-3.0-only
//
// Phase-2 WS-K (Kernel diet) S0 scaffold — docs/CORE_DECOMPOSITION_PROGRAM.md.
//
// OpenBurnBarKernelContracts owns the IPC/RPC + mission contract tier of the
// OpenBurnBarKernel split: the entire Contracts/ directory (incl.
// BurnBarRPCContracts + BurnBarRPCIPCCanon.generated — the canon sources),
// OpenBurnBarAgentContracts, the root mission contracts
// (OpenBurnBarMissionControlContracts/…MissionsContracts/
// OpenBurnBarMissionNextActionPlanner), TraceContext, and ClientTelemetrySanitizer.
// Deps: OpenBurnBarKernelModels + OpenBurnBarKernelCrypto.
//
// COMPILE-CLOSURE (Crypto edge, proven at K0): Contracts/MissionGroupContracts.swift
// calls `CloudVaultCrypto.sealedPayload(from:)` / `.openPayload(…)`, so this tier
// depends on OpenBurnBarKernelCrypto (the task's "+Crypto ONLY if a
// compile-closure dry-run demands" — it demands).
//
// K4 CANON PIN: BurnBarRPCContracts.swift + BurnBarRPCIPCCanon.generated.swift
// move here from OpenBurnBarKernel/Contracts/, so packet K4 updates the two
// pinned paths in tools/ipc/generate-burnbarrpc-canon.mjs (contracts/swift) and
// .swiftlint.yml line 153 in the SAME PR (wire names stay byte-identical; only
// the path changes). plans/core-decomposition2/packets/K4-contracts.md.
//
// At S0 this target holds only this marker. Packet K4 `git mv`s the real files
// in and deletes this marker in the same commit.
enum OpenBurnBarKernelContractsModuleMarker {}
