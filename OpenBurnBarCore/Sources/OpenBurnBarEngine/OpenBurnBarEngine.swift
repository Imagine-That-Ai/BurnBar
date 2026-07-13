// SPDX-License-Identifier: AGPL-3.0-only
//
// Core-decomposition S16 (docs/CORE_DECOMPOSITION_PROGRAM.md): the UI-free engine
// umbrella. The daemon, CLI, and parity executables link `OpenBurnBarEngine`
// instead of `OpenBurnBarCore`, so they gain no transitive path to the SwiftUI /
// AppKit presentation layer (OpenBurnBarUI). That is the security payoff of the
// decomposition: the most privileged binaries stop linking the UI monolith.
//
// This file `@_exported import`s the engine-layer leaf targets so a single
// `import OpenBurnBarEngine` re-exposes everything the daemon consumes today.
// Engine depends on these leaves in the manifest and does NOT depend on
// OpenBurnBarCore (a Core→Engine edge would be circular; Engine sits below Core).
//
// S16/S17 verification status (packet P-17) — each re-exported leaf now holds
// its real extracted code EXCEPT Quota:
//   • Kernel       — populated (139 files).
//   • LogParsers   — populated (27 files).
//   • VectorKit    — populated (9 files).
//   • Hermes       — populated (7 files).
//   • Pretext      — populated (2 files + Resources bundle).
//   • Quota        — NOT extracted. The P-13 move packet was reverted (the Quota
//     code stayed entangled with LogParser/SQLite/utils in OpenBurnBarCore), so
//     OpenBurnBarQuota is still a marker-only target. `@_exported import` of a
//     marker-only target is valid Swift and re-exposes no usable symbol yet; the
//     line is a forward declaration that lights up automatically when the Quota
//     move lands. The daemon consumes NO Quota type (verified: zero
//     ProviderQuota*/Quota* references in OpenBurnBarDaemon/Sources), so the
//     empty re-export does not affect the S17 daemon repoint.
//
// The whole Engine transitive closure is UI-free: no target reachable from
// OpenBurnBarEngine imports SwiftUI or AppKit (grep-proven in packet P-17). That
// is the security payoff — the most privileged binaries link this umbrella and
// gain no path to OpenBurnBarUI / OpenBurnBarInsights presentation code.
@_exported import OpenBurnBarKernel
@_exported import OpenBurnBarLogParsers
@_exported import OpenBurnBarQuota
@_exported import OpenBurnBarVectorKit
@_exported import OpenBurnBarHermes
@_exported import OpenBurnBarPretext

/// Marker so the target always has a concrete symbol even before the umbrella has
/// downstream consumers. Unreferenced internal enum; zero runtime cost.
internal enum OpenBurnBarEngineModuleMarker {}
