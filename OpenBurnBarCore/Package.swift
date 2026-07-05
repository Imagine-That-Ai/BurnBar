// swift-tools-version: 6.0
// SPDX-License-Identifier: AGPL-3.0-only

import PackageDescription
import Foundation

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let buildForLinuxBoundary = ProcessInfo.processInfo.environment["OPENBURNBAR_DAEMON_LINUX_BOUNDARY_BUILD"] == "1"
let buildLinuxSecurityOnly = ProcessInfo.processInfo.environment["OPENBURNBAR_LINUX_SECURITY_ONLY_BUILD"] == "1"
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
let hasBurnBarRemoteXCFramework = FileManager.default.fileExists(
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
]) + (hasIrohXCFramework ? [
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

let irohRelayDependencies: [Target.Dependency] = hasIrohXCFramework
    ? ["OpenBurnBarCore", "OpenBurnBarIrohFFI"]
    : ["OpenBurnBarCore"]

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
    "CLITerminalSessionSupervisor.swift",
    "BrowserLaunchAdapter.swift",
    "BurnBarPersistentVectorIndex.swift",
    // HNSW index references BurnBarPersistentVectorIndexError (excluded above);
    // the vector index is not part of the Foundation Engine subset.
    "BurnBarHNSWVectorIndex.swift",
    "ChromeProfileDiscovery.swift",
    "OpenBurnBarAgentContracts.swift",
    // Firebase App Check debug-token env writer uses POSIX setenv (Windows CRT
    // uses _putenv_s); App Check is not part of the Engine subset.
    "AppCheckDebugTokenEnvironment.swift",
    // Contracts referencing types defined in excluded files:
    //   BurnBarRunContracts   -> BurnBarAgentLoopState (OpenBurnBarAgentContracts)
    //   MissionGroupContracts -> MissionConsoleForecast (Views)
    "Contracts/BurnBarRunContracts.swift",
    // Consumes BurnBarRunStateSnapshot (defined in the excluded BurnBarRunContracts).
    "Contracts/BurnBarEventContracts.swift",
    "Contracts/MissionGroupContracts.swift",
    // Insights + Verdict subsystem: heavy, model-gateway/LLM-analysis coupled, and
    // consumed only by Views/ (excluded) — drop the whole tree off-Apple rather than
    // the prior partial set that left model files referencing excluded types.
    "AgentInsights",
    "Demo/InsightVerdictDemoFixture.swift",
    "Services/Insights",
    "SwitcherBrowserLaunchService.swift",
    // TextExpansion is an Apple keyboard-extension feature (App Group stores); not
    // in the Engine subset and not referenced outside its own directory.
    "TextExpansion",
    "UIMode.swift",
    "SharedModels/AgentProvider+LogoBackdrop.swift",
    "SharedModels/AgentWatchLiveActivityAttributes.swift",
    "SharedModels/BurnBarLiveActivityAttributes.swift",
    // Uses CloudVaultCrypto (excluded) for sealed-payload encryption.
    "SharedModels/CLIAgentSessionRecord.swift",
    // References CLIAgentRuntime + CLIAgentSessionRecord (excluded above).
    "SharedModels/CLIAgentResumePresentation.swift",
    // Uses PiAgentRelayCrypto (defined in the excluded HermesRelayCrypto).
    "SharedModels/PiConnectionTypes.swift",
    "SharedModels/CloudVaultDeviceKeypair.swift",
    "SharedModels/EscrowDeviceSafetyCode.swift",
    "SharedModels/HermesRatchetCrypto.swift",
    // Uses authenticated-request trust/runtime types outside the Engine subset.
    "SharedModels/HermesRelayAuthenticatedRequest.swift",
    "SharedModels/Insights",
    "SharedModels/InsightVerdictWidgetSnapshot.swift",
    "SharedModels/PensieveKnowledgeChunker.swift",
    "SharedModels/PensieveVectorCloak.swift",
    "SharedModels/PixelClockSettingsModel.swift",
    "SharedModels/SmartHubDisplaySettingsModel.swift",
    "SharedModels/SwarmColorDriver.swift",
    "SharedModels/ThemePrimitives.swift"
]
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
let openBurnBarCoreOffAppleTestSources: [String]? = ["LinuxEmptyTests.swift", "LLMSafeWrapVectorTests.swift"]
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
        return relativePath == "LinuxEmptyTests.swift" ? nil : relativePath
    }.sorted()
}
// Windows-port Phase-2 (G2 parser lift): the off-Apple SQLite backend for the
// read-only reader seam (`Sources/OpenBurnBarCore/Services/SQLite/`). The Swift
// Windows SDK ships NO system SQLite, so the Foundation-only Engine subset compiles
// the vendored public-domain SQLite amalgamation (`Sources/CSQLite/sqlite3.c`) as a
// first-party C target. The module is intentionally named `OpenBurnBarCoreCSQLite`
// instead of `CSQLite` so it can coexist with GRDB-SQLCipher's own system-library
// `CSQLite` target in Linux package graphs. On Apple this target is ABSENT and
// the reader links the system `SQLite3` module instead (`#if canImport(SQLite3)`),
// so the 8.8 MB amalgamation never compiles on macOS/iOS. Host-evaluated, so it
// is included only on the non-Apple Windows/Linux CI hosts — exactly where the
// Engine is exercised.
let vendoredSQLiteTargets: [Target] = [
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
let coreSQLiteDependencies: [Target.Dependency] = ["OpenBurnBarCoreCSQLite"]
#else
let openBurnBarCoreExcludes: [String] = []
let computerUseCoreExcludes: [String] = []
let openBurnBarCoreTestExcludes: [String] = []
let computerUseCoreTestExcludes: [String] = []
let legacyLinuxTestSources: [String]? = nil
let openBurnBarCoreOffAppleTestSources: [String]? = nil
func legacyLinuxTestExcludes(targetPath _: String) -> [String] { [] }
// On Apple the reader links the system `SQLite3` module, so no vendored C target
// and no Core dependency edge — the amalgamation is not compiled on Apple builds.
let vendoredSQLiteTargets: [Target] = []
let coreSQLiteDependencies: [Target.Dependency] = []
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
        .target(
            name: "OpenBurnBarCore",
            // remediation(typespec-strangler): link the generated Firestore
            // canon into the production graph so it is no longer test-only.
            // Core gains a real `import OpenBurnBarFirestoreModels` consumer
            // (ProviderAccountDeviceLinkTypes+Generated.swift); anything that
            // links OpenBurnBarCore now transitively links the generated
            // models, so drift in the generated wire schema fails the
            // production build, not just the test target.
            dependencies: [
                "OpenBurnBarFirestoreModels",
                swiftCryptoNonAppleDependency
            ] + coreSQLiteDependencies,
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
            dependencies: ["OpenBurnBarCore", "OpenBurnBarIrohRelay", swiftCryptoDependency]
        ),
        .target(
            name: "BurnBarRemoteEngine",
            dependencies: burnBarRemoteEngineDependencies
        ),
        .target(
            name: "OpenBurnBarComputerUseCore",
            dependencies: ["OpenBurnBarCore", "OpenBurnBarMedia", "Czlib", swiftCryptoDependency],
            exclude: computerUseCoreExcludes,
            linkerSettings: [
                .linkedFramework("Security", .when(platforms: [.macOS])),
                .linkedFramework("LocalAuthentication", .when(platforms: [.macOS])),
                .linkedLibrary("z")
            ]
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
            dependencies: [swiftCryptoDependency]
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
                swiftCryptoDependency,
                swiftTestingAppleDependency
            ],
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
                swiftTestingDependency
            ],
            exclude: openBurnBarCoreTestExcludes + legacyLinuxTestExcludes(targetPath: "Tests/OpenBurnBarCoreTests"),
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
                swiftCryptoDependency,
                swiftTestingAppleDependency
            ],
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
                "OpenBurnBarMedia",
                swiftTestingDependency
            ],
            exclude: computerUseCoreTestExcludes + legacyLinuxTestExcludes(targetPath: "Tests/OpenBurnBarComputerUseCoreTests"),
            sources: legacyLinuxTestSources,
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

let firstPartyTargets: [Target] = firstPartyTargetsBase + (buildForLinuxBoundary ? [] : [
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
            .product(name: "GRDB", package: "GRDB-SQLCipher"),
            swiftTestingAppleDependency
        ],
        resources: [
            .process("Fixtures")
        ],
        swiftSettings: [.swiftLanguageMode(.v5)]
    )
])

let linuxSecurityOnlyTargets: [Target] = [
    .target(
        name: "OpenBurnBarLinuxSecurity",
        dependencies: [swiftCryptoDependency]
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
    : irohBinaryTargets + burnBarRemoteBinaryTargets + signalBinaryTargets + firstPartyTargets + vendoredSQLiteTargets

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
    ]) + [
        .package(url: "https://github.com/swiftlang/swift-testing", from: "0.11.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")
    ],
    targets: allTargets,
    swiftLanguageModes: [.v6]
)
