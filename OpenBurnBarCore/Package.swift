// swift-tools-version: 6.0
// SPDX-License-Identifier: AGPL-3.0-only

import PackageDescription
import Foundation

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let buildForLinuxBoundary = ProcessInfo.processInfo.environment["OPENBURNBAR_DAEMON_LINUX_BOUNDARY_BUILD"] == "1"
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

let packageProducts: [Product] = [
    .library(
        name: "OpenBurnBarCore",
        targets: ["OpenBurnBarCore"]
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
    "ChromeProfileDiscovery.swift",
    "OpenBurnBarAgentContracts.swift",
    "Services/Insights/InsightAnalysisCache.swift",
    "Services/Insights/InsightAnalysisEngine.swift",
    "Services/Insights/InsightAnalysisModelPrompt.swift",
    "Services/Insights/InsightCache.swift",
    "Services/Insights/InsightDigestBuilder.swift",
    "Services/Insights/Verdict/RuleBasedVerdictEngine.swift",
    "Services/Insights/Verdict/VerdictCache.swift",
    "SwitcherBrowserLaunchService.swift",
    "TextExpansion/TextExpansionKeyEventCharacters.swift",
    "UIMode.swift",
    "SharedModels/AgentProvider+LogoBackdrop.swift",
    "SharedModels/AgentWatchLiveActivityAttributes.swift",
    "SharedModels/BurnBarLiveActivityAttributes.swift",
    "SharedModels/CloudVaultCrypto.swift",
    "SharedModels/CloudVaultDeviceKeypair.swift",
    "SharedModels/EscrowDeviceSafetyCode.swift",
    "SharedModels/HermesRatchetCrypto.swift",
    "SharedModels/HermesRelayCrypto.swift",
    "SharedModels/Insights/InsightAnalysis.swift",
    "SharedModels/PensieveKnowledgeChunker.swift",
    "SharedModels/PensieveVectorCloak.swift",
    "SharedModels/PixelClockSettingsModel.swift",
    "SharedModels/SmartHubDisplaySettingsModel.swift",
    "SharedModels/SwarmColorDriver.swift",
    "SharedModels/ThemePrimitives.swift",
    "Services/Insights/Share"
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
#else
let openBurnBarCoreExcludes: [String] = []
let computerUseCoreExcludes: [String] = []
let openBurnBarCoreTestExcludes: [String] = []
let computerUseCoreTestExcludes: [String] = []
let legacyLinuxTestSources: [String]? = nil
func legacyLinuxTestExcludes(targetPath _: String) -> [String] { [] }
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
            ],
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
            sources: legacyLinuxTestSources,
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

let allTargets: [Target] = irohBinaryTargets + burnBarRemoteBinaryTargets + signalBinaryTargets + firstPartyTargets

let package = Package(
    name: "OpenBurnBarCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: packageProducts,
    dependencies: (hasLibSignalSwiftPackage ? [
        .package(name: "LibSignalClient", path: "../Vendor/libsignal/swift"),
    ] : []) + (buildForLinuxBoundary ? [] : [
        .package(path: "../Vendor/GRDB-SQLCipher"),
    ]) + [
        .package(url: "https://github.com/swiftlang/swift-testing", from: "0.11.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")
    ],
    targets: allTargets,
    swiftLanguageModes: [.v6]
)
