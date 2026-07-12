// SPDX-License-Identifier: AGPL-3.0-only
//
// Phase-1 K1 of docs/SURFACE_SPRAWL_AND_SPLITBRAIN_REMEDIATION_PLAN.md.
//
// The pure contract/model layer (Contracts, Budget, Membership, Metrics,
// Entitlements, Errors, Memory, and the Foundation-only SharedModels) moved
// into the UI-free leaf target `OpenBurnBarKernel`. Re-export it so every
// existing `import OpenBurnBarCore` consumer keeps compiling with zero
// call-site changes. K2 repoints the daemon and ComputerUseCore at the kernel
// product directly; this shim is what keeps the seam invisible until then.
@_exported import OpenBurnBarKernel
