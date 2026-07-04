// swift-tools-version: 6.0
// SPDX-License-Identifier: AGPL-3.0-only

import PackageDescription
import Foundation

var packagePlatforms: [SupportedPlatform]? = [.macOS(.v14)]
var packageDependencies: [Package.Dependency] = [
    .package(path: "../OpenBurnBarCore")
]
let buildForLinuxBoundary = ProcessInfo.processInfo.environment["OPENBURNBAR_DAEMON_LINUX_BOUNDARY_BUILD"] == "1"
var daemonTargetDependencies: [Target.Dependency] = [
    .product(name: "OpenBurnBarCore", package: "OpenBurnBarCore"),
    .product(name: "OpenBurnBarComputerUseCore", package: "OpenBurnBarCore")
]
var daemonLinkerSettings: [LinkerSetting] = []
var daemonExecutableDependencies: [Target.Dependency] = ["OpenBurnBarDaemon"]
var daemonExcludes: [String] = []

#if os(macOS)
if !buildForLinuxBoundary {
    packageDependencies.append(contentsOf: [
        .package(path: "../Vendor/GRDB-SQLCipher"),
        .package(url: "https://github.com/sqlcipher/SQLCipher.swift.git", exact: "4.16.0"),
        .package(url: "https://github.com/getsentry/sentry-cocoa", from: "9.18.0")
    ])
    daemonTargetDependencies.append(.product(name: "GRDB", package: "GRDB-SQLCipher"))
    daemonTargetDependencies.append(.product(name: "SQLCipher", package: "SQLCipher.swift"))
    daemonLinkerSettings = [.unsafeFlags(["-framework", "Network", "-framework", "CoreServices"])]
    daemonExecutableDependencies.append(.product(name: "Sentry", package: "sentry-cocoa"))
} else {
    // Linux boundary builds intentionally avoid remote-only macOS-heavy deps.
    daemonLinkerSettings = []
}
#endif

#if os(Linux)
packagePlatforms = nil
daemonExcludes = [
    "BurnBarDaemonDatabaseCipher.swift",
    "OpenBurnBarHTTPGatewayElderWandIntegration.swift",
    "OpenBurnBarHTTPGatewayError.swift",
    "OpenBurnBarHTTPGatewayRequests.swift",
    "OpenBurnBarHTTPGatewayResponseTypes.swift",
    "OpenBurnBarHTTPGatewayServer.swift",
    "OpenBurnBarHTTPGatewayServer+Connection.swift",
    "OpenBurnBarHTTPGatewayServer+CrossVendorDegrade.swift",
    "OpenBurnBarHTTPGatewayServer+Endpoints.swift",
    "OpenBurnBarHTTPGatewayServer+HTTPTransport.swift",
    "OpenBurnBarHTTPGatewayServer+ModelCatalog.swift",
    "OpenBurnBarHTTPGatewayServer+RoutePipeline.swift",
    "OpenBurnBarHTTPGatewayServer+UsageLogging.swift",
    "GatewayModelCatalogSource.swift",
    "GatewayRouteLogging.swift",
    "GatewayStreamingUsageAccumulator.swift",
    "PensieveKnowledgeWatcher.swift",
    "DaemonSelfCodeSignatureVerifier.swift",
    "ElderWandFusionOrchestrator.swift",
    "OpenBurnBarSwitcherShell.swift",
    "PTYInteractiveSession.swift"
]
#endif

let package = Package(
    name: "OpenBurnBarDaemon",
    platforms: packagePlatforms,
    products: [
        .executable(
            name: "OpenBurnBarDaemon",
            targets: ["OpenBurnBarDaemonExecutable"]
        ),
        .executable(
            name: "OpenBurnBarCLI",
            targets: ["OpenBurnBarCLI"]
        ),
        .executable(
            name: "OpenBurnBarRemoteAccessAgent",
            targets: ["OpenBurnBarRemoteAccessAgent"]
        ),
        .executable(
            name: "OpenBurnBarVirtualHIDBridge",
            targets: ["OpenBurnBarVirtualHIDBridge"]
        ),
        .executable(
            name: "OpenBurnBarPrivilegedInputExecution",
            targets: ["OpenBurnBarPrivilegedInputExecution"]
        ),
        .executable(
            name: "OpenBurnBarPrivilegedSocketRedTeamProbe",
            targets: ["OpenBurnBarPrivilegedSocketRedTeamProbe"]
        ),
        .executable(
            name: "OpenBurnBarPrivilegedInputKillSwitchWatchdog",
            targets: ["OpenBurnBarPrivilegedInputKillSwitchWatchdog"]
        ),
        .library(
            name: "OpenBurnBarRemoteAccessAgentCore",
            targets: ["OpenBurnBarRemoteAccessAgentCore"]
        )
    ],
    dependencies: packageDependencies,
    targets: [
        .target(
            name: "OpenBurnBarDaemon",
            dependencies: daemonTargetDependencies,
            exclude: daemonExcludes,
            cSettings: [
                .define("SQLITE_HAS_CODEC")
            ],
            linkerSettings: daemonLinkerSettings
        ),
        .executableTarget(
            name: "OpenBurnBarDaemonExecutable",
            dependencies: daemonExecutableDependencies
        ),
        .executableTarget(
            name: "OpenBurnBarCLI",
            dependencies: ["OpenBurnBarDaemon"]
        ),
        .target(
            name: "OpenBurnBarRemoteAccessAgentCore",
            dependencies: [
                .product(name: "OpenBurnBarComputerUseCore", package: "OpenBurnBarCore")
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-framework", "Security",
                    "-framework", "CoreGraphics",
                    "-framework", "IOKit"
                ])
            ]
        ),
        .executableTarget(
            name: "OpenBurnBarRemoteAccessAgent",
            dependencies: ["OpenBurnBarRemoteAccessAgentCore"],
            linkerSettings: [
                .unsafeFlags([
                    "-framework", "ApplicationServices",
                    "-framework", "IOKit",
                    "-framework", "SystemConfiguration"
                ])
            ]
        ),
        .executableTarget(
            name: "OpenBurnBarVirtualHIDBridge",
            dependencies: [
                "OpenBurnBarRemoteAccessAgentCore",
                .product(name: "OpenBurnBarComputerUseCore", package: "OpenBurnBarCore")
            ],
            linkerSettings: [
                .unsafeFlags(["-framework", "SystemConfiguration"])
            ]
        ),
        .executableTarget(
            name: "OpenBurnBarPrivilegedInputExecution",
            dependencies: ["OpenBurnBarRemoteAccessAgentCore"]
        ),
        .testTarget(
            name: "OpenBurnBarDaemonTests",
            dependencies: ["OpenBurnBarDaemon"],
            // Harness-only test target stays Swift 5 (region-isolation checker gaps).
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "OpenBurnBarPrivilegedSocketRedTeamProbe",
            dependencies: ["OpenBurnBarRemoteAccessAgentCore"]
        ),
        .executableTarget(
            name: "OpenBurnBarPrivilegedInputKillSwitchWatchdog",
            dependencies: [
                .product(name: "OpenBurnBarComputerUseCore", package: "OpenBurnBarCore")
            ]
        ),
        .testTarget(
            name: "OpenBurnBarRemoteAccessAgentCoreTests",
            dependencies: [
                "OpenBurnBarRemoteAccessAgentCore",
                .product(name: "OpenBurnBarComputerUseCore", package: "OpenBurnBarCore")
            ],
            // Harness-only test target stays Swift 5 (region-isolation checker gaps).
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ],
    swiftLanguageModes: [.v6]
)
