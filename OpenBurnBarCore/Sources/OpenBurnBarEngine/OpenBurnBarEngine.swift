// SPDX-License-Identifier: AGPL-3.0-only
//
// Core-decomposition S16 (docs/CORE_DECOMPOSITION_PROGRAM.md): the UI-free engine
// umbrella. The daemon, CLI, and parity executables link `OpenBurnBarEngine`
// instead of `OpenBurnBarCore`, so they gain no transitive path to the SwiftUI /
// AppKit presentation layer (OpenBurnBarUI). That is the security payoff of the
// decomposition: the most privileged binaries stop linking the UI monolith.
//
// This file `@_exported import`s the engine-layer leaf targets so a single
// `import OpenBurnBarEngine` re-exposes everything the daemon consumes today. At
// S0 those targets hold only marker placeholders — `@_exported import` of a
// marker-only target is valid; the symbols appear as the move packets fill each
// target. Engine depends on these leaves in the manifest and does NOT depend on
// OpenBurnBarCore (a Core→Engine edge would be circular; Engine sits below Core).
//
// This umbrella is authored at S0 so the target compiles from birth; the daemon
// repoint (S17) is a separate packet.
@_exported import OpenBurnBarKernel
@_exported import OpenBurnBarLogParsers
@_exported import OpenBurnBarQuota
@_exported import OpenBurnBarVectorKit
@_exported import OpenBurnBarHermes
@_exported import OpenBurnBarPretext

/// Marker so the target always has a concrete symbol even before the umbrella has
/// downstream consumers. Unreferenced internal enum; zero runtime cost.
internal enum OpenBurnBarEngineModuleMarker {}
