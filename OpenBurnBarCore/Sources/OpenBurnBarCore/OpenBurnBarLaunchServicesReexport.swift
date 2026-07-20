// SPDX-License-Identifier: AGPL-3.0-only
//
// Core-decomposition S0 (docs/CORE_DECOMPOSITION_PROGRAM.md). Pattern = KernelReexport.swift.
//
// Re-export the Apple-only OpenBurnBarLaunchServices decomposition target so every existing
// `import OpenBurnBarCore` consumer keeps compiling with zero call-site changes
// once its move packet lands. This target is pruned from the non-Apple build
// graph (mirroring OpenBurnBarData / `buildApplePrunedDecompositionTargets` in
// Package.swift), so Core does NOT depend on it off-Apple — the re-export is
// guarded to `os(macOS) || os(iOS)` to match that manifest pruning exactly. The
// target is populated by `git mv`; move packets NEVER edit this file.
#if os(macOS) || os(iOS)
@_exported import OpenBurnBarLaunchServices
#endif
