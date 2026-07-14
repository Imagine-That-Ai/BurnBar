// SPDX-License-Identifier: AGPL-3.0-only
//
// Phase-2 WS-K (Kernel diet) — docs/CORE_DECOMPOSITION_PROGRAM.md.
//
// OpenBurnBarKernel is being split into 4 coherent sub-targets:
//   OpenBurnBarKernelPlatform  (leaf: host/runtime primitives)
//   OpenBurnBarKernelModels    (pure data + catalog + Resources bundle)
//   OpenBurnBarKernelCrypto    (key material + sealed envelopes)
//   OpenBurnBarKernelContracts (RPC/IPC + mission contracts)
//
// This umbrella `@_exported import`s all 4 so every existing `import
// OpenBurnBarKernel` consumer — and, transitively via OpenBurnBarCore's
// `@_exported import OpenBurnBarKernel`, every `import OpenBurnBarCore`
// consumer — keeps seeing the same public symbols with ZERO call-site changes as
// the move packets (K1–K4) carry files out of this target into the sub-targets.
//
// At S0 (this scaffold packet) the sub-targets hold only ModuleMarker.swift, so
// these re-exports are harmless no-ops that compile alongside the ~144 files
// still physically in OpenBurnBarKernel. Each move packet (K1–K4) empties one
// more slice of this target into its sub-target; the FINAL move packet reduces
// OpenBurnBarKernel to this umbrella file only (ceiling drops to 3 files / 200
// LOC — see budgets/core-target-membership-baseline.json).
@_exported import OpenBurnBarKernelPlatform
@_exported import OpenBurnBarKernelModels
@_exported import OpenBurnBarKernelCrypto
@_exported import OpenBurnBarKernelContracts
