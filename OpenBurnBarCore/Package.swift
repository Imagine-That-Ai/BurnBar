// swift-tools-version: 6.0
// SPDX-License-Identifier: AGPL-3.0-only

import PackageDescription
import Foundation

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let buildForLinuxBoundary = ProcessInfo.processInfo.environment["OPENBURNBAR_DAEMON_LINUX_BOUNDARY_BUILD"] == "1"
let buildLinuxSecurityOnly = ProcessInfo.processInfo.environment["OPENBURNBAR_LINUX_SECURITY_ONLY_BUILD"] == "1"
let disableBurnBarRemoteXCFramework = ProcessInfo.processInfo.environment[
    "OPENBURNBAR_DISABLE_BURNBAR_REMOTE_XCFRAMEWORK"
] == "1"
// Domain-core consumer linkage: when the focused domain-core test job links the
// pre-built OpenBurnBarDomainCore.xcframework (a Rust staticlib) alongside the
// locally-built libsignal-ffi (also a Rust staticlib), both archives embed Rust
// runtime objects whose `_rust_eh_personality` collides at link time. Setting
// OPENBURNBAR_DISABLE_LIBSIGNAL_SWIFT_PACKAGE=1 makes `hasLibSignalSwiftPackage`
// false — mirroring `disableBurnBarRemoteXCFramework` — so the local LibSignalClient
// Swift package and its libsignal_ffi.a are pruned from the package graph. The
// SignalCore/SignalSessionTransport targets compile with their existing
// unavailable stubs and the full-app CI gates still exercise real libsignal.
let disableLibSignalSwiftPackage = ProcessInfo.processInfo.environment[
    "OPENBURNBAR_DISABLE_LIBSIGNAL_SWIFT_PACKAGE"
] == "1"
#if os(Windows)
let buildOnWindows = true
#else
let buildOnWindows = false
#endif
// Core-decomposition S0: Apple-only presentation targets (OpenBurnBarUI,
// OpenBurnBarTextExpansion, OpenBurnBarLaunchServices) and
// their products are pruned from the non-Apple build graph exactly as
// `OpenBurnBarData` is pruned from the Linux-boundary build: host-evaluated, so on
// a Linux/Windows host the target/product is absent and Core does not depend on
// it. On Apple hosts they are present and Core links them. This mirrors the
// existing `buildForLinuxBoundary`/`OpenBurnBarData` pruning idiom rather than
// inventing a new seam. MUST be declared here (with the other host flags) so the
// `packageProductsBase` product list below reads an initialized value — a later
// declaration is a forward reference that silently evaluates to `false`, dropping
// the Apple-only PRODUCTS from the package graph even on Apple (P-19: the widget
// repoint needs these products emitted, not just the targets).
#if os(Linux) || os(Windows)
let buildApplePrunedDecompositionTargets = false
#else
let buildApplePrunedDecompositionTargets = true
#endif
// Windows-port Tier-A seam (PHASE1_CORE_SPLIT_PLAN.md, PR-3): this manifest is
// host-evaluated, and this marker is an *Apple-vs-non-Apple* switch (Vendor
// `.xcframework`s only exist for Apple). Windows joins Linux on the non-Apple
// side: no Vendor xcframeworks, so every `has*XCFramework` flag is false and the
// binaryTargets/products they gate are pruned exactly as on Linux. The Apple
// `#else` branch (which probes `../Vendor/*.xcframework`) stays byte-identical.
#if os(Linux) || os(Windows)
let hasIrohXCFramework = false
let hasDomainCoreXCFramework = false
let hasSignalFfiIOSXCFramework = false
let hasSignalFfiMacXCFramework = false
let hasLegacySignalFfiXCFramework = false
let hasLibSignalSwiftPackage = false
let hasBurnBarRemoteXCFramework = false
#else
let hasIrohXCFramework = FileManager.default.fileExists(
    atPath: packageRoot
        .appendingPathComponent("../Vendor/OpenBurnBarIroh.xcframework")
        .standardizedFileURL
        .path
)
let hasDomainCoreXCFramework = FileManager.default.fileExists(
    atPath: packageRoot
        .appendingPathComponent("../Vendor/OpenBurnBarDomainCore.xcframework")
        .standardizedFileURL
        .path
)
let hasSignalFfiIOSXCFramework = FileManager.default.fileExists(
    atPath: packageRoot
        .appendingPathComponent("../Vendor/OpenBurnBarSignalFfiIOS.xcframework")
        .standardizedFileURL
        .path
)
let hasSignalFfiMacXCFramework = FileManager.default.fileExists(
    atPath: packageRoot
        .appendingPathComponent("../Vendor/OpenBurnBarSignalFfiMac.xcframework")
        .standardizedFileURL
        .path
)
let hasLegacySignalFfiXCFramework = FileManager.default.fileExists(
    atPath: packageRoot
        .appendingPathComponent("../Vendor/OpenBurnBarSignalFfi.xcframework")
        .standardizedFileURL
        .path
)
let hasLibSignalSwiftPackage = !disableLibSignalSwiftPackage && FileManager.default.fileExists(
    atPath: packageRoot
        .appendingPathComponent("../Vendor/libsignal/swift/Package.swift")
        .standardizedFileURL
        .path
)
let hasBurnBarRemoteXCFramework = !disableBurnBarRemoteXCFramework && FileManager.default.fileExists(
    atPath: packageRoot
        .appendingPathComponent("../Vendor/BurnBarRemote.xcframework")
        .standardizedFileURL
        .path
)
#endif

#if os(Linux)
let linuxIrohNativeLibraryDirectory: String? = {
    guard let configured = ProcessInfo.processInfo.environment["OPENBURNBAR_LINUX_IROH_LIBRARY_DIR"]?
        .trimmingCharacters(in: .whitespacesAndNewlines),
        configured.isEmpty == false
    else {
        return nil
    }
    let directory = URL(fileURLWithPath: configured).standardizedFileURL
    let dynamicLibrary = directory.appendingPathComponent("libopenburnbar_iroh.so")
    let staticLibrary = directory.appendingPathComponent("libopenburnbar_iroh.a")
    guard FileManager.default.fileExists(atPath: dynamicLibrary.path),
          FileManager.default.fileExists(atPath: staticLibrary.path) else {
        fatalError(
            "OPENBURNBAR_LINUX_IROH_LIBRARY_DIR must contain libopenburnbar_iroh.so and libopenburnbar_iroh.a: \(directory.path)"
        )
    }
    return directory.path
}()
#else
let linuxIrohNativeLibraryDirectory: String? = nil
#endif
let hasLinuxIrohNativeLibrary = linuxIrohNativeLibraryDirectory != nil
let hasIrohFFIBindings = hasIrohXCFramework || hasLinuxIrohNativeLibrary

// Assembled incrementally (seed literal + `append(contentsOf:)` per host-gated
// block) rather than as one `[…] + (cond ? […] : []) + …` concatenation
// expression: the Core-decomposition products (LogParsers/Quota/VectorKit/Hermes/
// Pretext/Engine + the Apple-only Insights/TextExpansion/LaunchServices/UI block)
// grew the single literal past what the Linux SwiftPM manifest compiler
// (swift-tools 6.0) can type-check in reasonable time — it aborts with "unable to
// type-check this expression in reasonable time" on the whole `let` even though
// macOS/Xcode's newer type-checker accepts it. Splitting into statements keeps the
// emitted product SET byte-for-byte identical while giving the checker small,
// independently-solvable sub-expressions. Do NOT collapse back into one literal.
var packageProductsBase: [Product] = [
    .library(
        name: "OpenBurnBarCore",
        targets: ["OpenBurnBarCore"]
    ),
    // Phase-1 K1 of docs/SURFACE_SPRAWL_AND_SPLITBRAIN_REMEDIATION_PLAN.md: the
    // UI-free contract/model kernel (RPC contracts, canon, budget/membership/
    // entitlement/metrics primitives, Foundation-only SharedModels). Leaf
    // target: Foundation (+ swift-crypto off-Apple, CryptoKit on Apple via
    // canImport) + OpenBurnBarFirestoreModels only — ZERO SwiftUI/AppKit.
    // OpenBurnBarCore `@_exported import`s it so existing consumers keep
    // compiling unchanged; K2 repoints the daemon/ComputerUseCore at this
    // product directly.
    .library(
        name: "OpenBurnBarKernel",
        targets: ["OpenBurnBarKernel"]
    ),
    .library(
        name: "OpenBurnBarAssistantModels",
        targets: ["OpenBurnBarAssistantModels"]
    ),
    .library(
        name: "OpenBurnBarInboxModels",
        targets: ["OpenBurnBarInboxModels"]
    ),
    .library(
        name: "OpenBurnBarDomainCoreRuntime",
        targets: ["OpenBurnBarDomainCoreRuntime"]
    ),
    // Core-decomposition S0 (docs/CORE_DECOMPOSITION_PROGRAM.md): the cross-platform
    // (Apple + Linux + Windows) engine-layer targets carved out of the
    // OpenBurnBarCore monolith. At S0 each holds only a `ModuleMarker.swift`
    // placeholder (SwiftPM rejects a product whose target has no sources); the move
    // packets (S1/S6/S7/S8/S9/S10) fill them via `git mv`. OpenBurnBarCore
    // `@_exported import`s each one so existing `import OpenBurnBarCore` consumers
    // keep compiling with zero call-site changes. OpenBurnBarSQLiteReader is
    // deliberately product-less (package-internal micro-target; the K3 fix — see
    // its target declaration). OpenBurnBarEngine is the UI-free umbrella the
    // daemon/CLI/parity executables link (S16/S17).
    .library(
        name: "OpenBurnBarLogParsers",
        targets: ["OpenBurnBarLogParsers"]
    ),
    .library(
        name: "OpenBurnBarQuota",
        targets: ["OpenBurnBarQuota"]
    ),
    .library(
        name: "OpenBurnBarVectorKit",
        targets: ["OpenBurnBarVectorKit"]
    ),
    .library(
        name: "OpenBurnBarHermes",
        targets: ["OpenBurnBarHermes"]
    ),
    .library(
        name: "OpenBurnBarPretext",
        targets: ["OpenBurnBarPretext"]
    ),
    .library(
        name: "OpenBurnBarEngine",
        targets: ["OpenBurnBarEngine"]
    ),
    // Windows-port WPD-0007: C-ABI dynamic library for in-process P/Invoke (C# DllImport).
    .library(
        name: "OpenBurnBarCoreCAbi",
        type: .dynamic,
        targets: ["OpenBurnBarCoreCAbi"]
    ),
    // Opt-in, consent-gated Amplitude analytics core (SDK-free). Holds the
    // tri-state consent store (persisted in the shared App Group so the widget +
    // keyboard extensions read it), the recorder/wrapper, the transport-protocol
    // seam, the event registry, the anti-fingerprinting buckets, and the
    // string|bool-only AnalyticsValue. The real Amplitude SDK lives behind the
    // transport protocol in the iOS app target, so this package never imports the
    // SDK and stays `swift build`-able on any toolchain. Mirrors the macOS
    // reference in AgentLens/Services/Analytics.
    .library(
        name: "OpenBurnBarAnalytics",
        targets: ["OpenBurnBarAnalytics"]
    ),
    // Transport-agnostic iroh relay protocol + pairing + loopback
    // transport. When `Vendor/OpenBurnBarIroh.xcframework` exists, this
    // product also links the UniFFI-backed iroh QUIC bridge.
    .library(
        name: "OpenBurnBarIrohRelay",
        targets: ["OpenBurnBarIrohRelay"]
    ),
    // Mercury media substrate (file transfer, screen share, 1:1 video) —
    // see `plans/2026-05-15-mercury-media-master-plan.md`. Pure-Swift
    // shared types (frame codec, stream classes, bitrate controller,
    // capability gate, budget envelope). Platform implementations live
    // in `AgentLens/Services/Media/` and `OpenBurnBarMobile/Services/Media/`.
    .library(
        name: "OpenBurnBarMedia",
        targets: ["OpenBurnBarMedia"]
    ),
    .library(
        name: "BurnBarRemoteEngine",
        targets: ["BurnBarRemoteEngine"]
    ),
    // Computer Use substrate (Agent Watch, Browser CU, Mac CU,
    // Phone-as-controller). See
    // `plans/2026-05-16-computer-use-master-plan.md`. Pure-Swift
    // cross-platform shared types — session metadata, scope rules,
    // deny registry, audit chain, action descriptors, capability gate,
    // budget envelope. No AppKit. No AVFoundation. Mac runtime + iOS
    // runtime types live in `AgentLens/Services/ComputerUse/` and
    // `OpenBurnBarMobile/Services/ComputerUse/`.
    .library(
        name: "OpenBurnBarComputerUseCore",
        targets: ["OpenBurnBarComputerUseCore"]
    ),
    .library(
        name: "OpenBurnBarFirestoreModels",
        targets: ["OpenBurnBarFirestoreModels"]
    ),
    .library(
        name: "OpenBurnBarLinuxSecurity",
        targets: ["OpenBurnBarLinuxSecurity"]
    ),
    .library(
        name: "OpenBurnBarSignalCore",
        targets: ["OpenBurnBarSignalCore"]
    ),
    .library(
        name: "OpenBurnBarSignalSessionTransport",
        targets: ["OpenBurnBarSignalSessionTransport"]
    )
]
if !buildForLinuxBoundary {
    packageProductsBase.append(
        .library(
            name: "OpenBurnBarData",
            targets: ["OpenBurnBarData"]
        )
    )
}
// Usage-insights models and deterministic analysis are Foundation-only and are
// consumed by the Linux daemon RPC as well as Apple presentation surfaces.
packageProductsBase.append(
    .library(
        name: "OpenBurnBarInsights",
        targets: ["OpenBurnBarInsights"]
    )
)
if buildApplePrunedDecompositionTargets {
    // Apple-only presentation products remain pruned off the non-Apple graph.
    packageProductsBase.append(contentsOf: [
        .library(
            name: "OpenBurnBarTextExpansion",
            targets: ["OpenBurnBarTextExpansion"]
        ),
        .library(
            name: "OpenBurnBarLaunchServices",
            targets: ["OpenBurnBarLaunchServices"]
        ),
        .library(
            name: "OpenBurnBarUI",
            targets: ["OpenBurnBarUI"]
        )
    ])
}
if hasIrohFFIBindings {
    packageProductsBase.append(
        .library(
            name: "OpenBurnBarIrohFFI",
            targets: ["OpenBurnBarIrohFFI"]
        )
    )
}
if hasBurnBarRemoteXCFramework {
    packageProductsBase.append(
        .library(
            name: "BurnBarRemoteFFI",
            targets: ["BurnBarRemoteFFI"]
        )
    )
}
if hasDomainCoreXCFramework {
    packageProductsBase.append(
        .executable(
            name: "OpenBurnBarDomainCoreFFISmoke",
            targets: ["OpenBurnBarDomainCoreFFISmoke"]
        )
    )
}

let packageProducts: [Product] = buildLinuxSecurityOnly ? [
    .library(
        name: "OpenBurnBarLinuxSecurity",
        targets: ["OpenBurnBarLinuxSecurity"]
    )
] : packageProductsBase

// Phase-1 K2 of docs/SURFACE_SPRAWL_AND_SPLITBRAIN_REMEDIATION_PLAN.md: the
// privileged-input sibling chain (IrohRelay -> Media -> ComputerUseCore, linked
// by RemoteAccessAgentCore and the HID-entitled privileged binaries) depends on
// the UI-free OpenBurnBarKernel, NOT the SwiftUI/AppKit-carrying OpenBurnBarCore
// target. This is where audit finding #4's link-surface win lands: the most
// security-sensitive binaries stop transitively linking the UI monolith.
let irohRelayDependencies: [Target.Dependency] = hasIrohFFIBindings
    ? ["OpenBurnBarKernel", "OpenBurnBarIrohFFI"]
    : ["OpenBurnBarKernel"]

let irohFFITargets: [Target] = {
    if hasIrohXCFramework {
        return [
            .binaryTarget(
                name: "OpenBurnBarIroh",
                path: "../Vendor/OpenBurnBarIroh.xcframework"
            ),
            .target(
                name: "OpenBurnBarIrohFFI",
                dependencies: ["OpenBurnBarIroh"],
                path: "Sources/OpenBurnBarIroh/Generated",
                exclude: [
                    "openburnbar_iroh.modulemap",
                    "openburnbar_irohFFI.h"
                ],
                // Generated UniFFI bindings (never hand-edited; AAR parity) target Swift 5.
                swiftSettings: [.swiftLanguageMode(.v5)],
                linkerSettings: [
                    .linkedFramework("SystemConfiguration", .when(platforms: [.macOS, .iOS]))
                ]
            )
        ]
    }
    guard let libraryDirectory = linuxIrohNativeLibraryDirectory else {
        return []
    }
    return [
        .target(
            name: "openburnbar_irohFFI",
            path: "Sources/openburnbar_irohFFI",
            publicHeadersPath: "include",
            linkerSettings: [
                // Link the Rust transport archive into standalone daemon
                // artifacts. Native packages also stage the .so for their
                // existing runtime payload contract, but a downloaded daemon
                // executable must not depend on an unshipped sibling library.
                .unsafeFlags([libraryDirectory + "/libopenburnbar_iroh.a"])
            ]
        ),
        .target(
            name: "OpenBurnBarIrohFFI",
            dependencies: ["openburnbar_irohFFI"],
            path: "Sources/OpenBurnBarIroh/Generated",
            exclude: [
                "openburnbar_iroh.modulemap",
                "openburnbar_irohFFI.h"
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
}()

let domainCoreBinaryTargets: [Target] = hasDomainCoreXCFramework ? [
    .binaryTarget(
        name: "OpenBurnBarDomainCore",
        path: "../Vendor/OpenBurnBarDomainCore.xcframework"
    ),
    .target(
        name: "OpenBurnBarDomainCoreFFI",
        dependencies: ["OpenBurnBarDomainCore"],
        path: "Sources/OpenBurnBarDomainCore/Generated",
        exclude: [
            "openburnbar_domain_ffi.modulemap",
            "openburnbar_domain_ffiFFI.h"
        ],
        swiftSettings: [.swiftLanguageMode(.v5)]
    )
] : []

let domainCoreDependencies: [Target.Dependency] = hasDomainCoreXCFramework
    ? ["OpenBurnBarDomainCoreFFI"]
    : []

let domainCoreSmokeTargets: [Target] = hasDomainCoreXCFramework ? [
    .executableTarget(
        name: "OpenBurnBarDomainCoreFFISmoke",
        dependencies: ["OpenBurnBarDomainCoreFFI"],
        path: "Sources/OpenBurnBarDomainCoreFFISmoke",
        swiftSettings: [.swiftLanguageMode(.v5)]
    )
] : []

let burnBarRemoteBinaryTargets: [Target] = hasBurnBarRemoteXCFramework ? [
    .binaryTarget(
        name: "BurnBarRemote",
        path: "../Vendor/BurnBarRemote.xcframework"
    ),
    .target(
        name: "BurnBarRemoteFFI",
        dependencies: ["BurnBarRemote"],
        path: "Sources/BurnBarRemote/Generated",
        exclude: [
            "burnbar_remote.modulemap",
            "burnbar_remoteFFI.h"
        ],
        swiftSettings: [.swiftLanguageMode(.v5)]
    )
] : []

let burnBarRemoteEngineDependencies: [Target.Dependency] = hasBurnBarRemoteXCFramework ? [
    "BurnBarRemoteFFI"
] : []

let burnBarRemoteEngineSwiftSettings: [SwiftSetting] = hasBurnBarRemoteXCFramework ? [
    .define("OPENBURNBAR_HAS_BURNBAR_REMOTE_FFI")
] : []

let signalFfiDependencies: [Target.Dependency] = {
    var dependencies: [Target.Dependency] = []
    if hasSignalFfiIOSXCFramework {
        dependencies.append(.target(name: "OpenBurnBarSignalFfiIOS", condition: .when(platforms: [.iOS])))
    }
    if hasSignalFfiMacXCFramework {
        dependencies.append(.target(name: "OpenBurnBarSignalFfiMac", condition: .when(platforms: [.macOS])))
    }
    if hasLegacySignalFfiXCFramework && !hasSignalFfiMacXCFramework {
        dependencies.append(.target(name: "OpenBurnBarSignalFfi", condition: .when(platforms: [.macOS])))
    }
    return dependencies
}()

let signalCoreDependencies: [Target.Dependency] = [
    "OpenBurnBarCore",
    .product(name: "Crypto", package: "swift-crypto")
] + (hasLibSignalSwiftPackage ? [
    .product(name: "LibSignalClient", package: "LibSignalClient")
] : []) + signalFfiDependencies

let signalCoreSources: [String]? = hasLibSignalSwiftPackage
    ? nil
    : ["OpenBurnBarSignalCoreUnavailable.swift"]

let signalCoreFallbackExcludes: [String] = hasLibSignalSwiftPackage ? [] : [
    "CloudVaultDeviceTrustChain.swift",
    "OBBSignalPreKeyGenerator.swift",
    "OBBSignalProtocolStore.swift",
    "SignalAtRestFallbackPolicy.swift",
    "SignalAtRestSealer.swift",
    "SignalIdentityKeyStore.swift"
]

let signalSessionTransportDependencies: [Target.Dependency] = [
    "OpenBurnBarCore",
    "OpenBurnBarFirestoreModels",
    "OpenBurnBarIrohRelay",
    "OpenBurnBarSignalCore"
] + (hasLibSignalSwiftPackage ? [
    .product(name: "LibSignalClient", package: "LibSignalClient")
] : [])

let signalSessionTransportSources: [String]? = hasLibSignalSwiftPackage
    ? nil
    : ["OBBSignalSessionTransportUnavailable.swift"]

let signalSessionTransportFallbackExcludes: [String] = hasLibSignalSwiftPackage ? [] : [
    "OBBSignalSessionCipherTransport.swift"
]

let signalCoreTestFallbackExcludes: [String] = hasLibSignalSwiftPackage ? [] : [
    "CloudVaultDeviceTrustChainTests.swift",
    "CloudVaultRotationHandoffKATTests.swift",
    "CryptoKitAtRestInteropTests.swift",
    "OBBSignalIdentityPinTests.swift",
    "OBBSignalInteropFixtureGen.swift",
    "OBBSignalInteropKatTests.swift",
    "OBBSignalProtocolStoreSessionTests.swift",
    "SignalAtRestFallbackPolicyTests.swift",
    "SignalAtRestSealerTests.swift"
]

let signalSessionTransportTestFallbackExcludes: [String] = hasLibSignalSwiftPackage ? [] : [
    "OBBSignalSessionOverIrohTests.swift"
]

// LinuxCoreFoundationTests calls `OpenBurnBarSignalAtRest.sealPayload`/`openPayload`
// which exist only in the full LibSignalClient-backed implementation, not in the
// unavailable fallback stub. Exclude that file ONLY when libsignal is explicitly
// pruned via OPENBURNBAR_DISABLE_LIBSIGNAL_SWIFT_PACKAGE=1 (the focused macOS
// domain-core consumer mode). On Linux/Windows, where `hasLibSignalSwiftPackage`
// is always false, the file compiles against the fallback stub and MUST run —
// it is part of the Linux core-foundation test floor.
let linuxCoreFoundationSignalTestExcludes: [String] = disableLibSignalSwiftPackage ? [
    "LinuxCoreFoundationTests.swift"
] : []

let signalBinaryTargets: [Target] = {
    var targets: [Target] = []
    if hasSignalFfiIOSXCFramework {
        targets.append(.binaryTarget(
            name: "OpenBurnBarSignalFfiIOS",
            path: "../Vendor/OpenBurnBarSignalFfiIOS.xcframework"
        ))
    }
    if hasSignalFfiMacXCFramework {
        targets.append(.binaryTarget(
            name: "OpenBurnBarSignalFfiMac",
            path: "../Vendor/OpenBurnBarSignalFfiMac.xcframework"
        ))
    }
    if hasLegacySignalFfiXCFramework && !hasSignalFfiMacXCFramework {
        targets.append(.binaryTarget(
            name: "OpenBurnBarSignalFfi",
            path: "../Vendor/OpenBurnBarSignalFfi.xcframework"
        ))
    }
    return targets
}()

func signalFfiLibraryDirectory(in xcframeworkRelativePath: String) -> String? {
    let root = packageRoot
        .appendingPathComponent(xcframeworkRelativePath)
        .standardizedFileURL
    let candidates = [
        "macos-arm64_x86_64",
        "macos-arm64",
        "macos-x86_64"
    ]

    return candidates
        .map { root.appendingPathComponent($0).path }
        .first { FileManager.default.fileExists(atPath: "\($0)/libsignal_ffi.dylib") }
}

let signalFfiLinkerSettings: [LinkerSetting] = {
    let directory = signalFfiLibraryDirectory(in: "../Vendor/OpenBurnBarSignalFfiMac.xcframework")
        ?? signalFfiLibraryDirectory(in: "../Vendor/OpenBurnBarSignalFfi.xcframework")
    guard let directory else { return [] }
    return [
        .unsafeFlags(["-L", directory, "-lsignal_ffi"], .when(platforms: [.macOS]))
    ]
}()

let swiftTestingDependency: Target.Dependency = .product(name: "Testing", package: "swift-testing")
let swiftTestingAppleDependency: Target.Dependency = .product(
    name: "Testing",
    package: "swift-testing",
    condition: .when(platforms: [.macOS, .iOS])
)
#if os(Linux)
let swiftTestingAppleDependencies: [Target.Dependency] = []
// Linux contract tests use swift-testing as well as XCTest. Keep the package
// in the graph on every platform so native release builds do not depend on a
// test-only manifest rewrite.
let swiftTestingPackageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/swiftlang/swift-testing", from: "0.11.0")
]
#else
let swiftTestingAppleDependencies: [Target.Dependency] = [swiftTestingAppleDependency]
let swiftTestingPackageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/swiftlang/swift-testing", from: "0.11.0")
]
#endif
let swiftCryptoDependency: Target.Dependency = .product(name: "Crypto", package: "swift-crypto")
// Windows-port Tier-A seam (PHASE1_CORE_SPLIT_PLAN.md, PR-2): OpenBurnBarCore's
// crypto is centralized in `OpenBurnBarPlatformSupport/PlatformSupport.swift`, which resolves to
// CryptoKit on Apple via `#if canImport(CryptoKit)` and to swift-crypto's
// `Crypto` module only in the `#else` (non-Apple) branch. Gate Core's
// swift-crypto product to Windows/Linux so the **Apple** link/product graph
// gains no swift-crypto (macOS/iOS keep using CryptoKit, byte-identical to the
// pre-port baseline); off-Apple, `import Crypto` in PlatformSupport resolves
// against this product. The other targets that also link swift-crypto
// (SignalCore/IrohRelay/Media/ComputerUseCore/LinuxSecurity) keep the
// unconditional `swiftCryptoDependency` and are pruned off-Apple separately.
let swiftCryptoNonAppleDependency: Target.Dependency = .product(
    name: "Crypto",
    package: "swift-crypto",
    condition: .when(platforms: [.windows, .linux])
)

// Windows-port Tier-A seam (PHASE1_CORE_SPLIT_PLAN.md, PR-3): the exclude/prune
// lists below are the *non-Apple* file seam. They are **empty on Apple** (the
// `#else` branch), so macOS/iOS compile the whole target byte-identically to the
// pre-port baseline; populated off-Apple, they carve the Foundation(+swift-crypto)
// Engine subset out of the UI/Vendor-coupled remainder. Windows joins Linux here
// so the production `OpenBurnBarCore` target is pruned identically on both
// non-Apple hosts. Host-evaluated, so `os(Windows)` is true only on a Windows host.
#if os(Linux) || os(Windows)
// P-16f (S14/K4 complete): this array now holds ZERO real entries — every UI file that
// used to be excluded off-Apple has moved into targets pruned WHOLE off-Apple, so the
// literal is comment-only. An empty `[...]` literal has no inferable element type, so it
// MUST carry an explicit `[String]` annotation or SwiftPM rejects the off-Apple manifest
// with "empty collection literal requires an explicit type" (the Apple `#else` branch is
// already annotated the same way). Keep the annotation for as long as the array is empty.
let openBurnBarCoreExcludes: [String] = [
    // P-16f (S14 UI, FINAL UI sub-packet): the last 15 Views/ root files moved to the
    // Apple-only OpenBurnBarUI target, emptying Core's Views/ directory entirely. The
    // wholesale "Views" exclude that P-16a–e rode is therefore DELETED — the directory no
    // longer exists in the Core source tree, and a stale exclude on a non-existent path
    // makes SwiftPM reject the off-Apple manifest. All of Views/ now lives in the
    // OpenBurnBarUI target (Substrate P-16a, Insights root P-16b, MissionControl P-16c,
    // Cards/Square P-16d, Swarm+Verdict P-16e, root P-16f), which is pruned WHOLE off-Apple
    // (buildApplePrunedDecompositionTargets), so no off-Apple Core file references any view.
    // K4 (the daemon's UI-free-Core payoff) is complete: OpenBurnBarCore's off-Apple source
    // now carries ZERO SwiftUI/AppKit views.
    // P-15: CLITerminalSessionSupervisor.swift, BrowserLaunchAdapter.swift,
    // ChromeProfileDiscovery.swift, AppCheckDebugTokenEnvironment.swift, and
    // SwitcherBrowserLaunchService.swift moved to the Apple-only
    // OpenBurnBarLaunchServices target (pruned WHOLE off-Apple like
    // OpenBurnBarData), so their Core off-Apple exclude entries were removed here
    // (they no longer live under Core; the launch/discovery services + the
    // App Check debug-token env writer are Apple-only).
    // Insights + Verdict subsystem: heavy, model-gateway/LLM-analysis coupled, and
    // consumed only by Views/ (excluded) — drop the whole tree off-Apple rather than
    // the prior partial set that left model files referencing excluded types.
    // P-16b (S14 UI): AgentInsights/AgentInsightsViewModel.swift moved to the Apple-only
    // OpenBurnBarUI target (pulled forward with Views/Insights/ — AgentInsightsView binds
    // it as `@Bindable public var viewModel: AgentInsightsViewModel`). It is
    // Foundation/Observation-only (no SwiftUI) but rides UI because its sole build-time
    // consumers are the Insights views; OpenBurnBarUI is pruned WHOLE off-Apple, so its
    // stale exclude entry is removed (no off-Apple Core file references it — the only
    // off-Apple mention is a doc comment in OpenBurnBarInsights/AgentInsightsScope.swift).
    // P-08/P-09: files that moved out of Core into the Apple-only OpenBurnBarInsights
    // target (which is pruned WHOLE off-Apple) no longer exist in the off-Apple Core
    // source tree, so their stale exclude entries are removed by the mover (a stale
    // exclude on a moved-out file makes SwiftPM reject the off-Apple manifest):
    // P-08 removed "AgentInsights/AgentInsightsBundleAssembler.swift" (FIX-6); P-09
    // removes "Demo/InsightVerdictDemoFixture.swift" (FIX-8, moved to
    // OpenBurnBarInsights/Demo/ with its RuleBasedVerdictEngine).
    // P-09 narrowed "Services/Insights" -> "Services/Insights/Share": the
    // Adapters/Cadence/Trace/Verdict subtrees + InsightProviderGatewayRegistry.swift
    // all moved to OpenBurnBarInsights, leaving only Share/InsightShareCardRenderer.swift
    // (AppKit/UIKit) in Core until S14/UI.
    // NOTE: P-15 (merged earlier on wave3-base) already moved
    // SwitcherBrowserLaunchService.swift into OpenBurnBarLaunchServices and removed its
    // Core off-Apple exclude (see the P-15 comment above), so it is intentionally NOT
    // re-listed here even though p-09's base (pre-P-15) still carried that exclude.
    // P-16e (S14 UI): Services/Insights/Share/InsightShareCardRenderer.swift moved to
    // the Apple-only OpenBurnBarUI target (with the Swarm canvas cluster + the
    // Views/Insights/Verdict subtree). Services/Insights/Share/ is now empty in Core, so
    // the narrowed "Services/Insights/Share" exclude is REMOVED (a stale exclude on a
    // moved-out/empty path makes SwiftPM reject the off-Apple manifest). OpenBurnBarUI is
    // pruned WHOLE off-Apple, so the renderer no longer exists in the off-Apple source.
    // P-16b (S14 UI): SharedModels/AgentProvider+LogoBackdrop.swift moved to the
    // Apple-only OpenBurnBarUI target (pulled forward with Views/Insights/ — it is the
    // AgentProvider logo-backdrop extension hub consumed by UnifiedProviderLogoView).
    // OpenBurnBarUI is pruned WHOLE off-Apple, so the file no longer exists in the
    // off-Apple Core source tree and its stale exclude entry is removed here (a stale
    // exclude on a moved-out file makes SwiftPM reject the off-Apple manifest). The
    // "Views" wholesale exclude below still resolves (Views/ root + Views/Insights/Verdict/
    // + Views/MissionControl/Cards/Square remain in Core until later P-16 sub-packets).
    // P-16d (S14 UI): SharedModels/AgentWatchLiveActivityAttributes.swift +
    // SharedModels/BurnBarLiveActivityAttributes.swift moved to the Apple-only
    // OpenBurnBarUI target (with the LiveActivity/PixelClock straggler cluster). They
    // rode explicit off-Apple exclude entries here (ActivityKit/WidgetKit LiveActivity
    // attributes are Apple-only); OpenBurnBarUI is pruned WHOLE off-Apple, so the files
    // no longer exist in the off-Apple Core source tree and their stale exclude entries
    // are removed here (a stale exclude on a moved-out file makes SwiftPM reject the
    // off-Apple manifest). They have ZERO off-Apple-live Core consumers.
    // P-04b: the crypto-chain SharedModels below moved to OpenBurnBarKernel (they now
    // compile off-Apple in the Kernel, which links swiftCryptoNonAppleDependency), so
    // their Core off-Apple exclude entries were removed: CLIAgentSessionRecord,
    // CLIAgentResumePresentation, PiConnectionTypes, CloudVaultDeviceKeypair,
    // EscrowDeviceSafetyCode, HermesRatchetCrypto, HermesRelayAuthenticatedRequest.
    // P-10: SharedModels/Insights + SharedModels/InsightVerdictWidgetSnapshot.swift
    // moved to the Apple-only OpenBurnBarInsights target, so their Core off-Apple
    // exclude entries were removed here too (they no longer live under Core).
    // P-14: PensieveKnowledgeChunker + PensieveVectorCloak moved to
    // OpenBurnBarVectorKit. They reference `PlatformCrypto` (sha256/sha256Hex/
    // hmacSHA256) from OpenBurnBarKernel, which is fully cross-platform (CryptoKit
    // on Apple, swift-crypto off-Apple), so they compile off-Apple in VectorKit
    // through the Kernel dep — no VectorKit off-Apple exclude and no unguarded
    // CryptoKit. Their Core off-Apple exclude entries are therefore removed.
    // P-16d (S14 UI): SharedModels/PixelClockSettingsModel.swift +
    // SharedModels/SmartHubDisplaySettingsModel.swift moved to the Apple-only
    // OpenBurnBarUI target (with the LiveActivity/PixelClock straggler cluster). They
    // rode explicit off-Apple exclude entries here; OpenBurnBarUI is pruned WHOLE
    // off-Apple, so the files no longer exist in the off-Apple Core source tree and
    // their stale exclude entries are removed here. They have ZERO off-Apple-live Core
    // consumers (their only build-time consumers are the PixelClock/SmartHub views).
    // P-16b (S14 UI): SharedModels/ThemePrimitives.swift moved to the Apple-only
    // OpenBurnBarUI target (pulled forward with Views/Insights/ — it defines the
    // `Color(editorial:light:dark:)` bridge + AppSkin/DashboardLayout that
    // UnifiedDesignSystem's Colors palette consumes; its companion
    // SharedModels/DesignSystemTokens.swift (Foundation-only, was NOT excluded here)
    // moved with it). OpenBurnBarUI is pruned WHOLE off-Apple, so ThemePrimitives no
    // longer exists in the off-Apple Core tree and its stale exclude is removed. Every
    // off-Apple consumer of DesignSystemTokens/DesignSystemColors is itself off-Apple-
    // excluded (SwarmColorDriver explicit; SwarmCanvasView+Color / MissionFanOutGroup /
    // CardEnvelopeView under the "Views" wholesale exclude), so no off-Apple-live Core
    // file dangles on the moved color cluster.
    // P-16d (S14 UI): SharedModels/SwarmColorDriver.swift moved to the Apple-only
    // OpenBurnBarUI target (the color-cluster hub — it consumes DesignSystemColors +
    // the RGBA color-math extensions, both already in UI, so it resolves same-module in
    // UI and is fully `public`, so its remaining Core consumers SwarmCanvasView.swift /
    // SwarmCanvasView+Color.swift (Views/ root, P-16f) reach it cross-module via Core's
    // @_exported import OpenBurnBarUI on Apple). It rode an explicit off-Apple exclude
    // here; OpenBurnBarUI is pruned WHOLE off-Apple, so it no longer exists in the
    // off-Apple Core tree and its stale exclude is removed. Its two remaining Core
    // consumers are BOTH already off-Apple-excluded (under the "Views" wholesale
    // exclude), so no off-Apple-live Core file dangles.
    // Also moved to OpenBurnBarUI in P-16d (never off-Apple-excluded — Foundation-only
    // in Core, so they compiled off-Apple; their sole build-time consumers are the UI
    // views, so they follow the views into the Apple-only target, which is pruned WHOLE
    // off-Apple; ZERO off-Apple-live Core consumers, so no exclude entry is needed):
    // PixelClockQuotaRenderer.swift, PixelClockProviderLogoAssets.generated.swift,
    // SharedModels/AgentWatchLiveActivityIntents.swift (#if os(iOS) AppIntents, empty
    // off-Apple), Views/Cards/CardEnvelopeView.swift + Views/Square/UnifiedSearchIndex.swift
    // (rode the "Views" wholesale exclude, which STILL resolves — Views/ root +
    // Views/Insights/Verdict/ remain in Core until P-16e/f).
]
// Core-decomposition S0 (docs/CORE_DECOMPOSITION_PROGRAM.md): per-sibling-target
// off-Apple exclude seams for the new decomposition targets. They are EMPTY at
// S0 (no files have moved yet) and populated file-by-file as each move packet
// carries a file that lives in `openBurnBarCoreExcludes` today into its new
// target — the packet deletes the entry from `openBurnBarCoreExcludes` above and
// appends the same relative path (rebased onto the new target's directory) to the
// array below. Distinct-line edits so parallel packets auto-merge. Off-Apple only;
// the `#else` (Apple) branch keeps every one of these empty so macOS/iOS compile
// each target whole, byte-identically to the pre-decomposition baseline.
let openBurnBarSQLiteReaderExcludes: [String] = []
let openBurnBarLogParsersExcludes: [String] = []
let openBurnBarQuotaExcludes: [String] = []
let openBurnBarVectorKitExcludes: [String] = []
let openBurnBarHermesExcludes: [String] = []
let openBurnBarPretextExcludes: [String] = []
let openBurnBarEngineExcludes: [String] = []
// UI/Insights/TextExpansion/LaunchServices are pruned WHOLE off-Apple (like
// OpenBurnBarData) rather than file-excluded, so their exclude arrays exist only
// for symmetry and stay empty on every host.
let openBurnBarInsightsExcludes: [String] = []
let openBurnBarUIExcludes: [String] = []
let openBurnBarTextExpansionExcludes: [String] = []
let openBurnBarLaunchServicesExcludes: [String] = []
let computerUseCoreExcludes = [
    "Mac",
    "PrivilegedInputKillSwitch.swift",
    "PrivilegedInputXPCClient.swift",
    "PrivilegedInputXPCProtocol.swift",
    "PrivilegedSocketTrust.swift",
    "RemoteUnlockSystemScreenSharingProbe.swift"
]
let openBurnBarCoreTestExcludes = [
    "AgentProviderLogoBackdropTests.swift",
    "CLITerminalSessionSupervisorTests.swift",
    "Insights/BurnBarHostedAdapterWireTests.swift",
    "Insights/InsightLiveProviderSmokeTests.swift",
    "MissionConsoleTests.swift",
    "SmartHubDisplaySettingsModelTests.swift",
    "SwitcherCLIPostLaunchFallbackTests.swift",
    "SwarmLogoShapeTests.swift",
    "SwarmSubstrateContractTests.swift",
    "SwarmSubstratePreviewRenderTests.swift",
    // P-16f (S14 UI): these two tests reach OpenBurnBarUI view types now that
    // UnifiedQuotaSignalView / UnifiedToolCallAccordion moved Core→OpenBurnBarUI
    // (UnifiedQuotaSignalCurrencyTests additionally @testable-imports the UI target for the
    // internal fullRemainingText render helper). OpenBurnBarUI is pruned WHOLE off-Apple, so
    // both are excluded off-Apple exactly like the Swarm/SmartHub/MissionConsole UI tests above.
    "UnifiedQuotaSignalCurrencyTests.swift",
    "UnifiedToolCallAccordionTests.swift"
]
let computerUseCoreTestExcludes = [
    "ComputerUseOpenTimestampsClientTests.swift",
    "PrivilegedInputKillSwitchTests.swift",
    "PrivilegedInputSocketClientTrustTests.swift",
    "PrivilegedSocketTrustTests.swift",
    "PrivilegedTrustRealValidationTests.swift",
    "RemoteUnlockPolicyTests.swift"
]
let legacyLinuxTestSources: [String]? = ["LinuxEmptyTests.swift"]
// Analytics now has a real Linux behavior suite. Keep its source list
// explicit so the target is part of the isolated Linux test inventory rather
// than being mistaken for one of the legacy compile-only targets below.
let analyticsLinuxTestSources: [String]? = ["LinuxAnalyticsBehaviorTests.swift"]
// Mercury's platform-neutral Linux contract tests are a real suite, rather
// than one of the legacy compile-only placeholders. Keep their source list
// separate so the Linux graph can execute them without widening the other
// compatibility targets.
let openBurnBarMediaTestSources: [String]? = ["LinuxMediaContractTests.swift"]
#if os(Linux)
// The remote-engine seam has a real Linux behavior suite. Keep it separate
// from the legacy placeholder source list so the Linux graph executes these
// transport-contract tests rather than reporting a compile-only target.
let remoteEngineLinuxTestSources: [String]? = ["LinuxRemoteEngineBehaviorTests.swift"]
let openBurnBarCoreOffAppleTestSources: [String]? = [
    "LiftedParserBoundaryTests.swift",
    "LLMSafeWrapVectorTests.swift",
    "ParserAutoReleasePoolTests.swift",
    "ParserParseOptionsTests.swift",
    "ParserResourceGovernorTests.swift",
    "QuotaRefreshPolicyTests.swift",
    "CodexRolloutScannerTests.swift",
    "SuperGrokLogScanTests.swift",
    "ClaudeJSONLResumeTests.swift",
    "FactoryQuotaSessionSkipTests.swift",
    "AntigravityJSONLTailTests.swift",
    "WarpTelemetryTailTests.swift",
    "GeminiCLIParserCacheTests.swift",
    "IdleUsageParserCacheTests.swift",
    "TokenUsageExplainQueryPlanTests.swift",
    "KiloCodeQuotaCacheTests.swift",
    "AiderQuotaCacheTests.swift",
    "FactoryQuotaCacheTests.swift",
    "ThreadSafeISO8601DateFormatterStaticParseTests.swift"
]
let openBurnBarCorePlaceholderExcludes = ["LinuxEmptyTests.swift"]
let computerUseCoreOffAppleTestSources: [String]? = [
    "LinuxComputerUseCoreBehaviorTests.swift",
    "LinuxSecretStorageTests.swift",
    "LinuxRemoteUnlockCapabilitySigningKeyStoreTests.swift"
]
#else
let openBurnBarCoreOffAppleTestSources: [String]? = [
    "LiftedParserBoundaryTests.swift",
    "LinuxEmptyTests.swift",
    "LLMSafeWrapVectorTests.swift",
    "ParserAutoReleasePoolTests.swift",
    "ParserParseOptionsTests.swift",
    "ParserResourceGovernorTests.swift",
    "QuotaRefreshPolicyTests.swift",
    "CodexRolloutScannerTests.swift",
    "SuperGrokLogScanTests.swift",
    "ClaudeJSONLResumeTests.swift",
    "FactoryQuotaSessionSkipTests.swift",
    "AntigravityJSONLTailTests.swift",
    "WarpTelemetryTailTests.swift",
    "GeminiCLIParserCacheTests.swift",
    "IdleUsageParserCacheTests.swift",
    "TokenUsageExplainQueryPlanTests.swift",
    "KiloCodeQuotaCacheTests.swift",
    "AiderQuotaCacheTests.swift",
    "FactoryQuotaCacheTests.swift",
    "ThreadSafeISO8601DateFormatterStaticParseTests.swift"
]
let openBurnBarCorePlaceholderExcludes: [String] = []
let computerUseCoreOffAppleTestSources: [String]? = ["LinuxComputerUseCoreBehaviorTests.swift"]
let remoteEngineLinuxTestSources: [String]? = nil
#endif
func legacyLinuxTestExcludes(targetPath: String) -> [String] {
    let targetURL = packageRoot.appendingPathComponent(targetPath, isDirectory: true)
    guard let enumerator = FileManager.default.enumerator(
        at: targetURL,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else {
        return []
    }
    return enumerator.compactMap { item -> String? in
        guard let url = item as? URL, url.pathExtension == "swift" else {
            return nil
        }
        let relativePath = String(url.path.dropFirst(targetURL.path.count + 1))
        return [
            "LinuxEmptyTests.swift",
            "LinuxComputerUseCoreBehaviorTests.swift",
            "LinuxAnalyticsBehaviorTests.swift",
            "LinuxRemoteEngineBehaviorTests.swift",
            "LinuxMediaContractTests.swift",
            "LiftedParserBoundaryTests.swift",
            "LLMSafeWrapVectorTests.swift",
            "ParserAutoReleasePoolTests.swift",
            "ParserParseOptionsTests.swift",
            "ParserResourceGovernorTests.swift",
            "QuotaRefreshPolicyTests.swift",
            "CodexRolloutScannerTests.swift",
            "SuperGrokLogScanTests.swift",
            "ClaudeJSONLResumeTests.swift",
            "FactoryQuotaSessionSkipTests.swift",
            "AntigravityJSONLTailTests.swift",
            "WarpTelemetryTailTests.swift",
            "GeminiCLIParserCacheTests.swift",
            "IdleUsageParserCacheTests.swift",
            "TokenUsageExplainQueryPlanTests.swift",
            "KiloCodeQuotaCacheTests.swift",
            "AiderQuotaCacheTests.swift",
            "FactoryQuotaCacheTests.swift",
            "ThreadSafeISO8601DateFormatterStaticParseTests.swift",
            "LinuxSecretStorageTests.swift",
            "LinuxRemoteUnlockCapabilitySigningKeyStoreTests.swift"
        ].contains(relativePath)
            ? nil
            : relativePath
    }.sorted()
}
// Windows-port Phase-2 (G2 parser lift): the off-Apple SQLite backend for the
// read-only reader seam (`Sources/OpenBurnBarCore/Services/SQLite/`). Windows and
// the dependency-minimal Linux daemon boundary compile the vendored amalgamation.
// The full Linux graph instead imports GRDB-SQLCipher's `CSQLite` system module.
// Linking both implementations into one process is not safe: their identical
// `sqlite3_*` symbols let the plaintext amalgamation preempt SQLCipher at runtime.
let vendoredSQLiteTargets: [Target]
let coreSQLiteDependencies: [Target.Dependency]
if buildOnWindows || buildForLinuxBoundary {
    vendoredSQLiteTargets = [
        .target(
            name: "OpenBurnBarCoreCSQLite",
            path: "Sources/CSQLite",
            // No run-time extension loading (no dlopen/LoadLibrary) — the parsers only
            // read a plain local file. Serialized threadsafe mode is the SQLite default.
            cSettings: [
                .define("SQLITE_OMIT_LOAD_EXTENSION"),
                .define("SQLITE_THREADSAFE", to: "1")
            ]
        )
    ]
    coreSQLiteDependencies = ["OpenBurnBarCoreCSQLite"]
} else {
    vendoredSQLiteTargets = []
    coreSQLiteDependencies = [
        .product(name: "CSQLite", package: "GRDB-SQLCipher")
    ]
}
#else
let openBurnBarCoreExcludes: [String] = []
// Core-decomposition S0: Apple-side (empty) defaults for the new decomposition
// targets' off-Apple exclude seams — same shape as `openBurnBarCoreExcludes`
// above. On Apple every target compiles whole.
let openBurnBarSQLiteReaderExcludes: [String] = []
let openBurnBarLogParsersExcludes: [String] = []
let openBurnBarQuotaExcludes: [String] = []
let openBurnBarVectorKitExcludes: [String] = []
let openBurnBarHermesExcludes: [String] = []
let openBurnBarPretextExcludes: [String] = []
let openBurnBarEngineExcludes: [String] = []
let openBurnBarInsightsExcludes: [String] = []
let openBurnBarUIExcludes: [String] = []
let openBurnBarTextExpansionExcludes: [String] = []
let openBurnBarLaunchServicesExcludes: [String] = []
let computerUseCoreExcludes: [String] = []
let openBurnBarCoreTestExcludes: [String] = []
let computerUseCoreTestExcludes: [String] = []
let legacyLinuxTestSources: [String]? = nil
let analyticsLinuxTestSources: [String]? = nil
let openBurnBarMediaTestSources: [String]? = nil
let remoteEngineLinuxTestSources: [String]? = nil
let openBurnBarCoreOffAppleTestSources: [String]? = nil
let openBurnBarCorePlaceholderExcludes: [String] = []
let computerUseCoreOffAppleTestSources: [String]? = nil
func legacyLinuxTestExcludes(targetPath _: String) -> [String] { [] }
// On Apple the reader links the system `SQLite3` module, so no vendored C target
// and no Core dependency edge — the amalgamation is not compiled on Apple builds.
let vendoredSQLiteTargets: [Target] = []
let coreSQLiteDependencies: [Target.Dependency] = []
#endif

// Core-decomposition S0 (docs/CORE_DECOMPOSITION_PROGRAM.md): the new
// `OpenBurnBarSQLiteReader` micro-target (S1 payload — the K3 fix) links the same
// per-platform SQLite backend that Core links today. At S0 both Core and the new
// reader carry this edge; S1 moves `Services/SQLite/` into the reader and drops
// Core's copy. Mirroring `coreSQLiteDependencies` keeps the reader's off-Apple
// backend (vendored `OpenBurnBarCoreCSQLite` on Windows/Linux-boundary, GRDB
// `CSQLite` on the full Linux graph, system `SQLite3` on Apple) byte-identical to
// Core's current wiring.
let sqliteReaderSQLiteDependencies: [Target.Dependency] = coreSQLiteDependencies

// Core-decomposition S0: the Apple-only presentation targets
// (OpenBurnBarUI, OpenBurnBarTextExpansion, OpenBurnBarLaunchServices) and their products are pruned from the non-Apple
// build graph exactly as `OpenBurnBarData` is pruned from the Linux-boundary
// build: host-evaluated, so on a Linux/Windows host the target/product is absent
// and Core does not depend on it. On Apple hosts they are present and Core links
// them. This mirrors the existing `buildForLinuxBoundary`/`OpenBurnBarData`
// pruning idiom rather than inventing a new seam.
//
// NOTE: `buildApplePrunedDecompositionTargets` is declared near the top of this
// manifest (with the other host-evaluated flags), NOT here, so `packageProductsBase`
// reads an initialized value. Declaring it at this point was a forward reference
// that evaluated to `false` on every host, emitting the Apple-only TARGETS but
// dropping their PRODUCTS from the package graph.

// Core-decomposition S0: OpenBurnBarCore depends on every decomposition target so
// its `@_exported import` re-export shims resolve and the umbrella keeps every
// existing consumer compiling. The cross-platform engine-layer targets are always
// present; the Apple-only presentation/insights targets are added only on Apple
// hosts (they are pruned from the target list off-Apple, so Core must not name
// them there). OpenBurnBarEngine is NOT a Core dependency — Engine re-exports the
// same leaf targets Core does and lives BELOW Core in the graph (it is what the
// daemon links); a Core→Engine edge would be circular.
let coreDecompositionDependencies: [Target.Dependency] = [
    "OpenBurnBarSQLiteReader",
    "OpenBurnBarLogParsers",
    "OpenBurnBarQuota",
    "OpenBurnBarVectorKit",
    "OpenBurnBarHermes",
    "OpenBurnBarPretext"
] + (buildApplePrunedDecompositionTargets ? [
    "OpenBurnBarInsights",
    "OpenBurnBarTextExpansion",
    "OpenBurnBarLaunchServices",
    "OpenBurnBarUI"
] : [])

// Insights remains cross-platform for daemon usage-insights RPCs. The remaining
// Apple-only decomposition targets are added to the
// package target list only on Apple hosts (pruned off-Apple like OpenBurnBarData).
let applePrunedDecompositionTargets: [Target] = buildApplePrunedDecompositionTargets ? [
    .target(
        name: "OpenBurnBarTextExpansion",
        dependencies: ["OpenBurnBarKernel"],
        exclude: openBurnBarTextExpansionExcludes
    ),
    .target(
        name: "OpenBurnBarLaunchServices",
        dependencies: ["OpenBurnBarKernel"],
        exclude: openBurnBarLaunchServicesExcludes
    ),
    .target(
        name: "OpenBurnBarUI",
        dependencies: [
            "OpenBurnBarKernel",
            "OpenBurnBarQuota",
            "OpenBurnBarInsights",
            "OpenBurnBarHermes",
            "OpenBurnBarPretext",
            "OpenBurnBarLogParsers"
        ],
        exclude: openBurnBarUIExcludes
    )
] : []

#if os(Linux)
let libsecretCFlags = [
    "-I/usr/include/libsecret-1",
    "-I/usr/include/glib-2.0",
    "-I/usr/lib/aarch64-linux-gnu/glib-2.0/include",
    "-I/usr/lib/x86_64-linux-gnu/glib-2.0/include",
    "-I/usr/include/libmount",
    "-I/usr/include/blkid",
    "-I/usr/include/gio-unix-2.0"
]
let linuxSecretServiceTargets: [Target] = [
    .target(
        name: "COpenBurnBarSecretService",
        path: "Sources/COpenBurnBarSecretService",
        publicHeadersPath: ".",
        cSettings: [
            .unsafeFlags(libsecretCFlags)
        ],
        linkerSettings: [
            .linkedLibrary("secret-1"),
            .linkedLibrary("gio-2.0"),
            .linkedLibrary("gobject-2.0"),
            .linkedLibrary("glib-2.0")
        ]
    )
]
let linuxSecretServiceDependencies: [Target.Dependency] = ["COpenBurnBarSecretService"]
#else
let linuxSecretServiceTargets: [Target] = []
let linuxSecretServiceDependencies: [Target.Dependency] = []
#endif

let firstPartyTargetsBase: [Target] = [
        .systemLibrary(
            name: "Czlib",
            pkgConfig: "zlib",
            providers: [
                .apt(["zlib1g-dev"]),
                .brew(["zlib"])
            ]
        ),
        // Cross-platform crypto, logging, and Foundation concurrency shims.
        // Kernel re-exports this lower-level leaf so moving these primitives
        // does not expand the public import surface.
        .target(
            name: "OpenBurnBarPlatformSupport",
            dependencies: [swiftCryptoNonAppleDependency]
        ),
        // Shared-Rust rollout policy and evidence primitives. This leaf stays
        // Foundation-only so Kernel, Quota, LogParsers, and platform shells can
        // share one fail-closed authority contract without regrowing Kernel.
        .target(
            name: "OpenBurnBarDomainCoreRuntime"
        ),
        // Assistant identity, manifest, persona, selection, prompt, and policy
        // models form a Foundation-only leaf. Kernel re-exports this target so
        // existing consumers retain the same public import surface.
        .target(
            name: "OpenBurnBarAssistantModels",
            dependencies: ["OpenBurnBarPlatformSupport"]
        ),
        // AI Inbox wire contracts and the Firestore mirror record form a
        // Foundation-only leaf, following the assistant-model precedent in
        // docs/CORE_DECOMPOSITION_PROGRAM.md. Kernel re-exports it so existing
        // `import OpenBurnBarKernel` consumers keep the same public surface.
        .target(
            name: "OpenBurnBarInboxModels",
            dependencies: ["OpenBurnBarPlatformSupport"]
        ),
        // Phase-1 K1 kernel (see the OpenBurnBarKernel product comment above).
        // remediation(typespec-strangler): the generated Firestore canon stays
        // linked into the production graph — the `import OpenBurnBarFirestoreModels`
        // consumer (ProviderAccountDeviceLinkTypes+Generated.swift) moved here,
        // so anything that links the kernel (which includes OpenBurnBarCore and
        // everything downstream) still transitively links the generated models
        // and drift in the generated wire schema still fails the production build.
        .target(
            name: "OpenBurnBarKernel",
            dependencies: [
                "OpenBurnBarAssistantModels",
                "OpenBurnBarInboxModels",
                "OpenBurnBarPlatformSupport",
                "OpenBurnBarDomainCoreRuntime",
                "OpenBurnBarFirestoreModels",
                swiftCryptoNonAppleDependency
            ] + domainCoreDependencies,
            resources: [.process("Resources")]
        ),
        // Core-decomposition S0 (docs/CORE_DECOMPOSITION_PROGRAM.md): cross-platform
        // engine-layer targets carved from the OpenBurnBarCore monolith. At S0 each
        // holds only `Sources/<Target>/ModuleMarker.swift`; move packets fill them.
        //
        // OpenBurnBarSQLiteReader (S1 / the K3 fix) — read-only local SQLite reader,
        // no product (package-internal). Takes over `coreSQLiteDependencies` (mirrored
        // as `sqliteReaderSQLiteDependencies`) so LogParsers and Quota extract on top
        // of it without depending on each other. Deps: SQLite backend only.
        .target(
            name: "OpenBurnBarSQLiteReader",
            dependencies: sqliteReaderSQLiteDependencies,
            exclude: openBurnBarSQLiteReaderExcludes
        ),
        .target(
            name: "OpenBurnBarParserSupport",
            dependencies: ["OpenBurnBarKernel"]
        ),
        .target(
            name: "OpenBurnBarLogParsers",
            dependencies: ["OpenBurnBarKernel", "OpenBurnBarSQLiteReader", "OpenBurnBarParserSupport"]
                + domainCoreDependencies,
            exclude: openBurnBarLogParsersExcludes
        ),
        .target(
            name: "OpenBurnBarQuota",
            dependencies: [
                "OpenBurnBarKernel",
                "OpenBurnBarSQLiteReader",
                // P-13 (integrator-authorized manifest edit, docs/CORE_DECOMPOSITION_PROGRAM.md
                // AE-IMPORT STOP override): `AiderQuotaAdapter` resumes Aider analytics JSONL via
                // `BufferedLineReader` / `ParserDiskCacheStore` in `OpenBurnBarLogParsers`
                // (LogParser/{BufferedLineSequence,ParserDiskCache}.swift).
                // The DRAFT card's "NO LogParsers edge" invariant was FALSE (its grep matched only
                // the literal `LogParser`, missing the method-name reference). This edge is acyclic:
                // `OpenBurnBarLogParsers` depends only on [Kernel, SQLiteReader], so Quota→LogParsers
                // introduces no cycle. The moved `AiderQuotaAdapter.swift` gains `import
                // OpenBurnBarLogParsers` (AE-IMPORT); Kilo and Factory quota caches share this edge.
                "OpenBurnBarLogParsers",
                swiftCryptoNonAppleDependency
            // Merge (train ← origin/main): P-13 moved the ProviderQuota adapters (incl.
            // main's #1590 `ClaudeQuotaDomainCoreAdapter.swift`) into this target. That file
            // guards on `#if canImport(OpenBurnBarDomainCoreFFI)`; carry main's conditional
            // `domainCoreDependencies` here so the module resolves when the DomainCore
            // xcframework is vendored (empty otherwise — legacy path, byte-identical to main).
            ] + domainCoreDependencies,
            exclude: openBurnBarQuotaExcludes
        ),
        .target(
            name: "OpenBurnBarVectorKit",
            dependencies: [
                "OpenBurnBarKernel",
                "OpenBurnBarDomainCoreRuntime"
            ] + domainCoreDependencies,
            exclude: openBurnBarVectorKitExcludes
        ),
        .target(
            name: "OpenBurnBarHermes",
            dependencies: ["OpenBurnBarKernel"],
            exclude: openBurnBarHermesExcludes
        ),
        // OpenBurnBarPretext gains its own `Resources/` bundle when S10 moves the
        // Pretext HTML/JS in (adding `resources: [.process("Resources")]` — the one
        // allowed manifest-structure edit, enumerated in packet P-06). At S0 it
        // declares NO resources so the manifest is valid with only a marker file.
        .target(
            name: "OpenBurnBarPretext",
            dependencies: ["OpenBurnBarKernel"],
            exclude: openBurnBarPretextExcludes,
            resources: [.process("Resources")]
        ),
        .target(
            name: "OpenBurnBarInsights",
            dependencies: ["OpenBurnBarKernel"],
            exclude: openBurnBarInsightsExcludes
        ),
        // OpenBurnBarEngine (S16) — UI-free umbrella the daemon/CLI/parity
        // executables link. Its single source file `@_exported import`s the leaf
        // engine targets. It depends on those leaves but NOT on OpenBurnBarCore
        // (Core→Engine would be circular; Engine sits below Core).
        .target(
            name: "OpenBurnBarEngine",
            dependencies: [
                "OpenBurnBarKernel",
                "OpenBurnBarLogParsers",
                "OpenBurnBarQuota",
                "OpenBurnBarVectorKit",
                "OpenBurnBarHermes",
                "OpenBurnBarPretext"
            ],
            exclude: openBurnBarEngineExcludes
        ),
        .target(
            name: "OpenBurnBarCore",
            dependencies: [
                "OpenBurnBarKernel",
                "OpenBurnBarFirestoreModels",
                swiftCryptoNonAppleDependency
            // Merge (train ← origin/main): the train dissolved Core's own SQLite edge
            // (S1 moved Services/SQLite into OpenBurnBarSQLiteReader, which is the first
            // entry of `coreDecompositionDependencies`), so Core no longer needs
            // `coreSQLiteDependencies` here. `domainCoreDependencies` is main's #1590
            // shared-Rust-quota-pilot wiring (empty unless the DomainCore xcframework is
            // vendored); kept via UNION so `import OpenBurnBarDomainCoreFFI` still resolves
            // when the framework is present.
            ] + coreDecompositionDependencies + domainCoreDependencies,
            exclude: openBurnBarCoreExcludes,
            resources: [
                // SwiftPM's `.process` rule flattens nested resource folders
                // so all files (catalog.json, MiningPickIcon*.svg, the Pretext
                // HTML + JS) end up at the root of the resource bundle. The
                // HTML's `<script src="pretext.bundle.min.js">` still
                // resolves correctly because both files are in the same
                // directory — just at the bundle root rather than a Pretext
                // subfolder. PretextEngine looks them up via Bundle.module
                // by filename.
                .process("Resources")
            ]
        ),
        // Windows-port WPD-0007: thin re-export of OpenBurnBarCore with @_cdecl exports
        // (`obb_parse_cli_stdout`, `obb_string_free`). Produces libOpenBurnBarCoreCAbi.dylib
        // on macOS and OpenBurnBarCoreCAbi.dll on Windows for DllImport binding tests.
        .target(
            name: "OpenBurnBarCoreCAbi",
            dependencies: ["OpenBurnBarCore"],
            path: "Sources/OpenBurnBarCoreCAbi",
            linkerSettings: [
                .linkedLibrary("sqlite3", .when(platforms: [.macOS, .iOS]))
            ]
        ),
        .target(
            name: "OpenBurnBarAnalytics",
            // SDK-free by design: no OpenBurnBarCore dependency, no Amplitude
            // dependency. Pure Foundation so it builds under Swift 6 strict
            // concurrency on any toolchain and the consent contract is testable
            // without Xcode/Amplitude. The iOS app supplies the real Amplitude
            // transport behind `AnalyticsTransporting`.
            dependencies: []
        ),
        .target(
            name: "OpenBurnBarIrohRelay",
            dependencies: irohRelayDependencies + [swiftCryptoDependency],
            linkerSettings: [
                .linkedFramework("SystemConfiguration", .when(platforms: [.macOS, .iOS]))
            ]
        ),
        .target(
            name: "OpenBurnBarMedia",
            dependencies: ["OpenBurnBarKernel", "OpenBurnBarIrohRelay", swiftCryptoDependency]
        ),
        .target(
            name: "BurnBarRemoteEngine",
            dependencies: burnBarRemoteEngineDependencies,
            swiftSettings: burnBarRemoteEngineSwiftSettings
        ),
        .target(
            name: "OpenBurnBarComputerUseCore",
            dependencies: ["OpenBurnBarKernel", "OpenBurnBarMedia", swiftCryptoDependency]
                + linuxSecretServiceDependencies
                + (buildOnWindows ? [] : ["Czlib"]),
            exclude: computerUseCoreExcludes,
            linkerSettings: [
                .linkedFramework("Security", .when(platforms: [.macOS])),
                .linkedFramework("LocalAuthentication", .when(platforms: [.macOS]))
            ] + (buildOnWindows ? [] : [.linkedLibrary("z")])
        ),
        .target(
            name: "OpenBurnBarFirestoreModels",
            // remediation(typespec-strangler): the generated canon imports only
            // Foundation and references no OpenBurnBarCore type, so the prior
            // `dependencies: ["OpenBurnBarCore"]` was spurious and — worse — it
            // formed a cycle that blocked Core (the natural first consumer) from
            // linking the generated models. Drop it so this stays a pure leaf
            // library that Core and the app targets can both depend on.
            path: "Sources/OpenBurnBarFirestoreModels"
        ),
        .target(
            name: "OpenBurnBarLinuxSecurity",
            dependencies: [swiftCryptoDependency],
            linkerSettings: [
                .linkedLibrary("pam", .when(platforms: [.linux]))
            ]
        ),
        .target(
            name: "OpenBurnBarSignalCore",
            dependencies: signalCoreDependencies,
            path: "Sources/OpenBurnBarSignalCore",
            exclude: signalCoreFallbackExcludes,
            sources: signalCoreSources,
            linkerSettings: signalFfiLinkerSettings
        ),
        .target(
            name: "OpenBurnBarSignalSessionTransport",
            dependencies: signalSessionTransportDependencies,
            path: "Sources/OpenBurnBarSignalSessionTransport",
            exclude: signalSessionTransportFallbackExcludes,
            sources: signalSessionTransportSources
        ),
        // Windows-port Phase-1 walking skeleton (PHASE1_CORE_SPLIT_PLAN.md, PR-5).
        // A Foundation-only executable that drives the vertical slice — one
        // provider -> parse -> auth -> one dashboard tile — over REAL Core APIs,
        // proving the split Engine is consumable end-to-end off the macOS app.
        //
        // It depends ONLY on the OpenBurnBarCore library and every Core type it
        // uses is Foundation-only and NOT in `openBurnBarCoreExcludes`, so it
        // compiles in the non-Apple Windows/Linux Engine subset while staying
        // present on the macOS host (SwiftPM manifests are host-evaluated, as the
        // `#if os(Linux)` excludes above show) so `swift run` works on macOS today.
        //
        // Deliberately NOT gated behind `#if os(Windows) || os(Linux)`: that
        // guidance exists to keep an added target out of the Apple app product
        // graph, but host-evaluation would also delete it from the macOS host and
        // break the mandated `swift run` verification. The same "never perturbs the
        // Apple product graph" outcome is achieved structurally instead — this
        // target declares NO product in `packageProducts` (only the implicit
        // executable product SwiftPM needs for `swift run`) and is absent from the
        // app's `project.yml`, so the XcodeGen app scheme never resolves, links, or
        // builds it. It is a never-referenced leaf on every platform.
        .executableTarget(
            name: "OpenBurnBarWalkingSkeleton",
            dependencies: ["OpenBurnBarCore"],
            path: "Sources/OpenBurnBarWalkingSkeleton",
            resources: [
                .copy("Fixtures/openai_stream.sse")
            ]
        ),
        // Windows-port Phase-2 parser path-remap parity gate (G2). A Foundation-only
        // executable that asserts the parser PATH layer resolves byte-identically on
        // Windows and macOS: the Claude Code `~/.claude/projects` directory-name codec
        // (PATH-021) over the committed capture corpus, plus the `LogPathPlatform`
        // `%USERPROFILE%`/`%APPDATA%`/`%LOCALAPPDATA%` root remap against an inline
        // golden. Same never-referenced-leaf shape as the walking skeleton above: it
        // declares NO product in `packageProducts` and is absent from the app's
        // `project.yml`, so the Apple app scheme never resolves/links/builds it, while
        // `swift run` works on macOS today and the Windows CI runs it natively.
        .executableTarget(
            name: "OpenBurnBarWindowsParserPathParity",
            dependencies: ["OpenBurnBarCore"],
            path: "Sources/OpenBurnBarWindowsParserPathParity",
            resources: [
                .copy("Fixtures/claude-code-project-path-fixtures.json")
            ]
        ),
        // Usage-memory Stage-0 drop-rate harness: replays a recorded agent-
        // session corpus (~/.codex/sessions) through UsageMemoryCandidateGate
        // and prints the accept/drop histogram + projected candidates/day —
        // the offline proof artifact for the usage-memory funnel's cost story.
        // Same never-referenced-leaf shape as the parity gates above: NO
        // product in `packageProducts`, absent from the app's `project.yml`;
        // `swift run OpenBurnBarUsageMemoryStage0Harness` only.
        .executableTarget(
            name: "OpenBurnBarUsageMemoryStage0Harness",
            dependencies: ["OpenBurnBarCore"],
            path: "Sources/OpenBurnBarUsageMemoryStage0Harness"
        ),
        // Windows-port Phase-2 G2 parser-OUTPUT parity gate. A Foundation-only
        // executable that runs the LIFTED parsers (ClaudeCode + FactoryDroid today;
        // Codex + Hermes ride the SQLite reader seam) over the committed
        // ParserContract fixture corpus and byte-diffs each parser's
        // token/cost(nano-USD int)/model/session projection against the macOS
        // golden (`parser-output-golden.json`). Same never-referenced-leaf shape as
        // the path-parity target above: NO product in `packageProducts`, absent
        // from the app's `project.yml`, so the Apple app scheme never resolves it,
        // while `swift run` works on macOS today and the Windows CI runs it natively.
        .executableTarget(
            name: "OpenBurnBarG2ParserParity",
            dependencies: ["OpenBurnBarCore"],
            path: "Sources/OpenBurnBarG2ParserParity",
            resources: [
                .copy("Fixtures")
            ]
        ),
        .testTarget(
            name: "OpenBurnBarLinuxCoreFoundationTests",
            dependencies: [
                "OpenBurnBarCore",
                "OpenBurnBarIrohRelay",
                "OpenBurnBarMedia",
                "OpenBurnBarComputerUseCore",
                "OpenBurnBarSignalCore",
                "OpenBurnBarSignalSessionTransport",
                swiftCryptoDependency
            ] + swiftTestingAppleDependencies,
            exclude: linuxCoreFoundationSignalTestExcludes,
            resources: [
                .process("Fixtures")
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "OpenBurnBarCoreTests",
            // Native-required migration tests must import the generated binding
            // directly so an absent or stale ABI cannot compile into a skipped assertion.
            dependencies: [
                "OpenBurnBarCore",
                "OpenBurnBarDomainCoreRuntime",
                "OpenBurnBarKernel",
                "OpenBurnBarLogParsers",
                "OpenBurnBarSQLiteReader",
                "OpenBurnBarFirestoreModels",
                "OpenBurnBarLinuxSecurity",
                // P-13 AE-TESTABLE: `ZAIQuotaAdapterTests` reaches the INTERNAL
                // `ZAIQuotaAdapter.zaiUsageQueryItems(now:)`, which moved with the
                // ProviderQuota adapters into `OpenBurnBarQuota`. `@testable import
                // OpenBurnBarQuota` (added in that test) needs the module as a test-target
                // dependency; the test file otherwise stays put with its logic unchanged.
                "OpenBurnBarQuota",
                // P-22 (S15) AE-IMPORT: `OBBCAbiUsageScanExportTests` reaches the PUBLIC
                // OBBCAbi C-ABI surface (`OBBCAbiUsageScanExport.run`, `obb_scan_usage`,
                // `obb_parse_cli_stdout`, `obb_string_free`), which moved Core →
                // OpenBurnBarCoreCAbi. The test now `import OpenBurnBarCoreCAbi` (plain, not
                // @testable — public API only); this dependency edge makes the module
                // linkable in the test host. Acyclic: OpenBurnBarCoreCAbi depends only on
                // OpenBurnBarCore, and a test target adding it introduces no product cycle.
                "OpenBurnBarCoreCAbi"
            ] + domainCoreDependencies + swiftTestingAppleDependencies,
            exclude: openBurnBarCoreTestExcludes
                + openBurnBarCorePlaceholderExcludes
                + legacyLinuxTestExcludes(targetPath: "Tests/OpenBurnBarCoreTests"),
            sources: openBurnBarCoreOffAppleTestSources,
            resources: [
                .process("Fixtures")
            ],
            // Test target stays Swift 5: harness-only code; the Swift 6 region-isolation
            // checker has known gaps (Task hand-off) that would contort correct tests.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "OpenBurnBarAnalyticsTests",
            dependencies: [
                "OpenBurnBarAnalytics",
                swiftTestingDependency
            ],
            exclude: legacyLinuxTestExcludes(targetPath: "Tests/OpenBurnBarAnalyticsTests"),
            sources: analyticsLinuxTestSources,
            // Test target stays Swift 5: harness-only code; the Swift 6
            // region-isolation checker has known gaps (Task hand-off) that would
            // contort correct tests. Matches the other Core test targets.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "OpenBurnBarLinuxSecurityTests",
            dependencies: [
                "OpenBurnBarLinuxSecurity",
                swiftCryptoDependency
            ] + swiftTestingAppleDependencies,
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "OpenBurnBarIrohRelayTests",
            dependencies: ["OpenBurnBarIrohRelay", "OpenBurnBarCore", swiftTestingDependency],
            exclude: legacyLinuxTestExcludes(targetPath: "Tests/OpenBurnBarIrohRelayTests"),
            sources: legacyLinuxTestSources,
            // Test target stays Swift 5: harness-only code; the Swift 6 region-isolation
            // checker has known gaps (Task hand-off) that would contort correct tests.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "OpenBurnBarMediaTests",
            dependencies: ["OpenBurnBarMedia", "OpenBurnBarCore", "OpenBurnBarIrohRelay", swiftTestingDependency],
            exclude: legacyLinuxTestExcludes(targetPath: "Tests/OpenBurnBarMediaTests"),
            sources: openBurnBarMediaTestSources,
            resources: [
                .process("Fixtures")
            ],
            // Test target stays Swift 5: harness-only code; the Swift 6 region-isolation
            // checker has known gaps (Task hand-off) that would contort correct tests.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "BurnBarRemoteEngineTests",
            dependencies: ["BurnBarRemoteEngine", swiftTestingDependency],
            exclude: legacyLinuxTestExcludes(targetPath: "Tests/BurnBarRemoteEngineTests"),
            sources: remoteEngineLinuxTestSources
        ),
        .testTarget(
            name: "OpenBurnBarComputerUseCoreTests",
            dependencies: [
                "OpenBurnBarComputerUseCore",
                "OpenBurnBarCore",
                "OpenBurnBarMedia"
            ] + swiftTestingAppleDependencies,
            exclude: computerUseCoreTestExcludes + legacyLinuxTestExcludes(targetPath: "Tests/OpenBurnBarComputerUseCoreTests"),
            sources: computerUseCoreOffAppleTestSources,
            resources: [
                .process("Fixtures")
            ],
            // Test target stays Swift 5: harness-only code; the Swift 6 region-isolation
            // checker has known gaps (Task hand-off) that would contort correct tests.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "OpenBurnBarSignalCoreTests",
            dependencies: [
                "OpenBurnBarSignalCore",
                "OpenBurnBarCore",
                swiftTestingDependency
            ] + (hasLibSignalSwiftPackage ? [
                .product(name: "LibSignalClient", package: "LibSignalClient")
            ] : []),
            exclude: signalCoreTestFallbackExcludes,
            sources: hasLibSignalSwiftPackage ? nil : ["OpenBurnBarSignalCoreUnavailableTests.swift"],
            resources: [
                .process("Fixtures")
            ],
            // Test target stays Swift 5: harness-only code; the Swift 6 region-isolation
            // checker has known gaps (Task hand-off) that would contort correct tests.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "OpenBurnBarSignalSessionTransportTests",
            dependencies: [
                "OpenBurnBarSignalSessionTransport",
                "OpenBurnBarSignalCore",
                "OpenBurnBarIrohRelay",
                "OpenBurnBarCore",
                swiftTestingDependency
            ] + (hasLibSignalSwiftPackage ? [
                .product(name: "LibSignalClient", package: "LibSignalClient")
            ] : []),
            exclude: signalSessionTransportTestFallbackExcludes,
            sources: hasLibSignalSwiftPackage ? nil : ["OBBSignalSessionTransportUnavailableTests.swift"],
            // Test target stays Swift 5: harness-only code; the Swift 6 region-isolation
            // checker has known gaps (Task hand-off) that would contort correct tests.
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]

#if os(Linux)
// Remaining placeholder-only targets are not tests. Keeping them out of the
// Linux SwiftPM graph avoids reporting a green suite that exercises no
// supported code; media has a real platform-neutral contract suite below.
let linuxPlaceholderTestTargetNames: Set<String> = [
    "OpenBurnBarIrohRelayTests",
    "OpenBurnBarSignalCoreTests",
    "OpenBurnBarSignalSessionTransportTests"
]
let platformFirstPartyTargetsBase = firstPartyTargetsBase.filter {
    !linuxPlaceholderTestTargetNames.contains($0.name)
}
#else
let platformFirstPartyTargetsBase = firstPartyTargetsBase
#endif

let firstPartyTargets: [Target] = platformFirstPartyTargetsBase
    // Core-decomposition S0: Apple-only presentation/insights targets, appended on
    // Apple hosts and pruned off-Apple (mirrors the OpenBurnBarData pruning below).
    + applePrunedDecompositionTargets
    + (buildForLinuxBoundary ? [] : [
    .target(
        name: "OpenBurnBarData",
        dependencies: [
            .product(name: "GRDB", package: "GRDB-SQLCipher")
        ]
    ),
    .testTarget(
        name: "OpenBurnBarDataTests",
        dependencies: [
            "OpenBurnBarData",
            .product(name: "GRDB", package: "GRDB-SQLCipher")
        ] + swiftTestingAppleDependencies,
        resources: [
            .process("Fixtures")
        ],
        swiftSettings: [.swiftLanguageMode(.v5)]
    )
])

let linuxSecurityOnlyTargets: [Target] = [
    .target(
        name: "OpenBurnBarLinuxSecurity",
        dependencies: [swiftCryptoDependency],
        linkerSettings: [
            .linkedLibrary("pam", .when(platforms: [.linux]))
        ]
    ),
    .testTarget(
        name: "OpenBurnBarLinuxSecurityTests",
        dependencies: [
            "OpenBurnBarLinuxSecurity",
            swiftCryptoDependency
        ],
        swiftSettings: [.swiftLanguageMode(.v5)]
    )
]

let allTargets: [Target] = buildLinuxSecurityOnly
    ? linuxSecurityOnlyTargets
    : irohFFITargets + domainCoreBinaryTargets + domainCoreSmokeTargets + burnBarRemoteBinaryTargets + signalBinaryTargets + linuxSecretServiceTargets + firstPartyTargets + vendoredSQLiteTargets

let package = Package(
    name: "OpenBurnBarCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: packageProducts,
    dependencies: buildLinuxSecurityOnly ? [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")
    ] : (hasLibSignalSwiftPackage ? [
        .package(name: "LibSignalClient", path: "../Vendor/libsignal/swift")
    ] : []) + (buildForLinuxBoundary ? [] : [
        .package(path: "../Vendor/GRDB-SQLCipher")
    ]) + swiftTestingPackageDependencies + [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")
    ],
    targets: allTargets,
    swiftLanguageModes: [.v6]
)
