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
#if os(Windows)
let buildOnWindows = true
#else
let buildOnWindows = false
#endif
// Windows-port Tier-A seam (PHASE1_CORE_SPLIT_PLAN.md, PR-3): this manifest is
// host-evaluated, and this marker is an *Apple-vs-non-Apple* switch (Vendor
// `.xcframework`s only exist for Apple). Windows joins Linux on the non-Apple
// side: no Vendor xcframeworks, so every `has*XCFramework` flag is false and the
// binaryTargets/products they gate are pruned exactly as on Linux. The Apple
// `#else` branch (which probes `../Vendor/*.xcframework`) stays byte-identical.
#if os(Linux) || os(Windows)
let hasIrohXCFramework = false
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
let hasLibSignalSwiftPackage = FileManager.default.fileExists(
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

let packageProductsBase: [Product] = [
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
] + (buildForLinuxBoundary ? [] : [
    .library(
        name: "OpenBurnBarData",
        targets: ["OpenBurnBarData"]
    )
]) + (buildApplePrunedDecompositionTargets ? [
    // Core-decomposition S0: Apple-only presentation/insights products, pruned off
    // the non-Apple graph like OpenBurnBarData. Populated by S11/S12/S13/S14.
    .library(
        name: "OpenBurnBarInsights",
        targets: ["OpenBurnBarInsights"]
    ),
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
] : []) + (hasIrohXCFramework ? [
    .library(
        name: "OpenBurnBarIrohFFI",
        targets: ["OpenBurnBarIrohFFI"]
    )
] : []) + (hasBurnBarRemoteXCFramework ? [
    .library(
        name: "BurnBarRemoteFFI",
        targets: ["BurnBarRemoteFFI"]
    )
] : [])

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
let irohRelayDependencies: [Target.Dependency] = hasIrohXCFramework
    ? ["OpenBurnBarKernel", "OpenBurnBarIrohFFI"]
    : ["OpenBurnBarKernel"]

let irohBinaryTargets: [Target] = hasIrohXCFramework ? [
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
let swiftTestingPackageDependencies: [Package.Dependency] = []
#else
let swiftTestingAppleDependencies: [Target.Dependency] = [swiftTestingAppleDependency]
let swiftTestingPackageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/swiftlang/swift-testing", from: "0.11.0")
]
#endif
let swiftCryptoDependency: Target.Dependency = .product(name: "Crypto", package: "swift-crypto")
// Windows-port Tier-A seam (PHASE1_CORE_SPLIT_PLAN.md, PR-2): OpenBurnBarCore's
// crypto is centralized in `Platform/PlatformSupport.swift`, which resolves to
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
let openBurnBarCoreExcludes = [
    "Views",
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
    "AgentInsights/AgentInsightsViewModel.swift",
    // P-08: AgentInsightsBundleAssembler.swift moved out of Core into the
    // Apple-only OpenBurnBarInsights target (FIX-6 re-slice), which is pruned WHOLE
    // off-Apple, so the file no longer exists in the off-Apple Core source tree and
    // its exclude entry is removed here (a stale exclude on a moved-out file makes
    // SwiftPM reject the off-Apple manifest). The mover owns the exclude deletion.
    "Demo/InsightVerdictDemoFixture.swift",
    "Services/Insights",
    "SharedModels/AgentProvider+LogoBackdrop.swift",
    "SharedModels/AgentWatchLiveActivityAttributes.swift",
    "SharedModels/BurnBarLiveActivityAttributes.swift",
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
    "SharedModels/PixelClockSettingsModel.swift",
    "SharedModels/SmartHubDisplaySettingsModel.swift",
    "SharedModels/SwarmColorDriver.swift",
    "SharedModels/ThemePrimitives.swift"
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
    "SwarmSubstratePreviewRenderTests.swift"
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
#if os(Linux)
let openBurnBarCoreOffAppleTestSources: [String]? = ["LLMSafeWrapVectorTests.swift"]
let openBurnBarCorePlaceholderExcludes = ["LinuxEmptyTests.swift"]
let computerUseCoreOffAppleTestSources: [String]? = [
    "LinuxSecretStorageTests.swift",
    "LinuxRemoteUnlockCapabilitySigningKeyStoreTests.swift"
]
#else
let openBurnBarCoreOffAppleTestSources: [String]? = ["LinuxEmptyTests.swift", "LLMSafeWrapVectorTests.swift"]
let openBurnBarCorePlaceholderExcludes: [String] = []
let computerUseCoreOffAppleTestSources: [String]? = ["LinuxEmptyTests.swift"]
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
            "LLMSafeWrapVectorTests.swift",
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

// Core-decomposition S0: the Apple-only presentation/insights targets
// (OpenBurnBarUI, OpenBurnBarInsights, OpenBurnBarTextExpansion,
// OpenBurnBarLaunchServices) and their products are pruned from the non-Apple
// build graph exactly as `OpenBurnBarData` is pruned from the Linux-boundary
// build: host-evaluated, so on a Linux/Windows host the target/product is absent
// and Core does not depend on it. On Apple hosts they are present and Core links
// them. This mirrors the existing `buildForLinuxBoundary`/`OpenBurnBarData`
// pruning idiom rather than inventing a new seam.
#if os(Linux) || os(Windows)
let buildApplePrunedDecompositionTargets = false
#else
let buildApplePrunedDecompositionTargets = true
#endif

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

// Core-decomposition S0: the Apple-only decomposition targets, added to the
// package target list only on Apple hosts (pruned off-Apple like OpenBurnBarData).
let applePrunedDecompositionTargets: [Target] = buildApplePrunedDecompositionTargets ? [
    .target(
        name: "OpenBurnBarInsights",
        dependencies: ["OpenBurnBarKernel"],
        exclude: openBurnBarInsightsExcludes
    ),
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
                "OpenBurnBarFirestoreModels",
                swiftCryptoNonAppleDependency
            ],
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
            name: "OpenBurnBarLogParsers",
            dependencies: ["OpenBurnBarKernel", "OpenBurnBarSQLiteReader"],
            exclude: openBurnBarLogParsersExcludes
        ),
        .target(
            name: "OpenBurnBarQuota",
            dependencies: [
                "OpenBurnBarKernel",
                "OpenBurnBarSQLiteReader",
                swiftCryptoNonAppleDependency
            ],
            exclude: openBurnBarQuotaExcludes
        ),
        .target(
            name: "OpenBurnBarVectorKit",
            dependencies: ["OpenBurnBarKernel"],
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
            ] + coreDecompositionDependencies,
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
            dependencies: burnBarRemoteEngineDependencies
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
            resources: [
                .process("Fixtures")
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "OpenBurnBarCoreTests",
            dependencies: [
                "OpenBurnBarCore",
                "OpenBurnBarFirestoreModels",
                "OpenBurnBarLinuxSecurity"
            ] + swiftTestingAppleDependencies,
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
            sources: legacyLinuxTestSources,
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
            sources: legacyLinuxTestSources,
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
            sources: legacyLinuxTestSources
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
// Placeholder-only targets are not tests. Keeping them in the Linux SwiftPM
// graph lets `swift test` report success while exercising no supported code.
let linuxPlaceholderTestTargetNames: Set<String> = [
    "OpenBurnBarAnalyticsTests",
    "OpenBurnBarIrohRelayTests",
    "OpenBurnBarMediaTests",
    "BurnBarRemoteEngineTests",
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
    : irohBinaryTargets + burnBarRemoteBinaryTargets + signalBinaryTargets + linuxSecretServiceTargets + firstPartyTargets + vendoredSQLiteTargets

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
