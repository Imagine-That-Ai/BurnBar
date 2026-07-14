// SPDX-License-Identifier: AGPL-3.0-only
//
// Phase-2 WS-K (Kernel diet) S0 scaffold — docs/CORE_DECOMPOSITION_PROGRAM.md.
//
// OpenBurnBarKernelPlatform is the LEAF of the 4-way OpenBurnBarKernel split
// (Platform < Models < Crypto, Contracts < Crypto). It owns the host/runtime
// primitives: PlatformSupport (crypto/logger/Sendable shims), the CLI launch
// adapters (CLILaunchAdapter/CLILaunchRedactor/CLITerminalSessionSupervisor),
// OpenBurnBarIdentity, OpenBurnBarLinuxPaths, LinuxLocalPeerDiscovery,
// SendableFileSystem, and the Foundation-only formatter/JSON/string/identifier
// utilities. Deps: Foundation (+ swift-crypto off-Apple via
// swiftCryptoNonAppleDependency, CryptoKit on Apple via canImport).
//
// At S0 this target holds only this marker (SwiftPM rejects a product/target
// with no sources). Packet K1 (plans/core-decomposition2/packets/K1-platform.md)
// `git mv`s the real files in and deletes this marker in the same commit.
// The OpenBurnBarKernel umbrella `@_exported import`s this module so every
// existing `import OpenBurnBarKernel` (and, transitively, `import
// OpenBurnBarCore`) consumer keeps compiling with zero call-site changes.
enum OpenBurnBarKernelPlatformModuleMarker {}
