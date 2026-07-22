// swift-tools-version: 6.0
// SPDX-License-Identifier: AGPL-3.0-only

import PackageDescription
import Foundation

var packagePlatforms: [SupportedPlatform]? = [.macOS(.v14)]
var packageDependencies: [Package.Dependency] = [
    .package(path: "../OpenBurnBarCore")
]
let buildForLinuxBoundary = ProcessInfo.processInfo.environment["OPENBURNBAR_DAEMON_LINUX_BOUNDARY_BUILD"] == "1"
// Core-decomposition S17 (docs/CORE_DECOMPOSITION_PROGRAM.md) — THE SECURITY PAYOFF:
// the daemon + CLI link the UI-free `OpenBurnBarEngine` umbrella instead of the
// SwiftUI/AppKit `OpenBurnBarCore` monolith, so the most-privileged binaries gain NO
// transitive path to the presentation layer (OpenBurnBarUI / OpenBurnBarInsights /
// OpenBurnBarLaunchServices / OpenBurnBarTextExpansion). Engine re-exports the six
// engine leaves {Kernel, LogParsers, Quota, VectorKit, Hermes, Pretext}; every symbol
// the daemon used from Core resolves through them (the CLI-launch cluster is now
// Kernel-resident — P-15b + P-18). ComputerUseCore / IrohRelay / Media / LinuxSecurity
// stay as-is (K2 privileged closure, orthogonal to the UI monolith).
var daemonTargetDependencies: [Target.Dependency] = [
    .product(name: "OpenBurnBarEngine", package: "OpenBurnBarCore"),
    .product(name: "OpenBurnBarComputerUseCore", package: "OpenBurnBarCore"),
    .product(name: "OpenBurnBarIrohRelay", package: "OpenBurnBarCore"),
    .product(name: "OpenBurnBarMedia", package: "OpenBurnBarCore"),
    .product(name: "OpenBurnBarLinuxSecurity", package: "OpenBurnBarCore")
]
var daemonLinkerSettings: [LinkerSetting] = []
var daemonSwiftSettings: [SwiftSetting] = []
var daemonExecutableDependencies: [Target.Dependency] = ["OpenBurnBarDaemon"]
var daemonExcludes: [String] = []
var linuxSupportTargets: [Target] = []

#if os(Linux)
struct LinuxMediaCaptureLibrary {
    let directory: String
    let staticLibrary: String?
    let dynamicLibrary: String?
}

func linuxMediaCaptureLibraryIfPresent() -> LinuxMediaCaptureLibrary? {
    let environment = ProcessInfo.processInfo.environment
    if let configured = environment["OPENBURNBAR_MEDIA_CAPTURE_LIBRARY_DIR"],
       configured.isEmpty == false {
        let directory = URL(fileURLWithPath: configured).standardizedFileURL
        let staticLibrary = directory.appendingPathComponent("libopenburnbar_media.a")
        let dynamicLibrary = directory.appendingPathComponent("libopenburnbar_media.so")
        let staticPath = FileManager.default.fileExists(atPath: staticLibrary.path) ? staticLibrary.path : nil
        let dynamicPath = FileManager.default.fileExists(atPath: dynamicLibrary.path) ? dynamicLibrary.path : nil
        if staticPath != nil || dynamicPath != nil {
            return LinuxMediaCaptureLibrary(
                directory: directory.path,
                staticLibrary: staticPath,
                dynamicLibrary: dynamicPath
            )
        }
    }

    let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot = packageRoot.deletingLastPathComponent()
    let releaseBuild = environment["OPENBURNBAR_MEDIA_CAPTURE_RELEASE"] == "1"
    let targetSubdir = releaseBuild ? "release" : "debug"
    let libraryDirectory = repoRoot
        .appendingPathComponent("crates/openburnbar-media")
        .appendingPathComponent("target/\(targetSubdir)")
        .standardizedFileURL
    let staticLibrary = libraryDirectory.appendingPathComponent("libopenburnbar_media.a")
    let dynamicLibrary = libraryDirectory.appendingPathComponent("libopenburnbar_media.so")

    let staticPath = FileManager.default.fileExists(atPath: staticLibrary.path) ? staticLibrary.path : nil
    let dynamicPath = FileManager.default.fileExists(atPath: dynamicLibrary.path) ? dynamicLibrary.path : nil
    if staticPath != nil || dynamicPath != nil {
        return LinuxMediaCaptureLibrary(
            directory: libraryDirectory.path,
            staticLibrary: staticPath,
            dynamicLibrary: dynamicPath
        )
    }
    return nil
}
#endif

#if os(macOS)
if !buildForLinuxBoundary {
    packageDependencies.append(contentsOf: [
        .package(path: "../Vendor/GRDB-SQLCipher"),
        .package(url: "https://github.com/sqlcipher/SQLCipher.swift.git", exact: "4.16.0"),
        .package(url: "https://github.com/getsentry/sentry-cocoa", from: "9.18.0")
    ])
    daemonTargetDependencies.append(.product(name: "GRDB", package: "GRDB-SQLCipher"))
    daemonTargetDependencies.append(.product(name: "SQLCipher", package: "SQLCipher.swift"))
    daemonTargetDependencies.append(.product(name: "GRDB", package: "GRDB-SQLCipher"))
    daemonLinkerSettings = [.unsafeFlags(["-framework", "Network", "-framework", "CoreServices"])]
    daemonExecutableDependencies.append(.product(name: "Sentry", package: "sentry-cocoa"))
} else {
    // Linux boundary builds intentionally avoid remote-only macOS-heavy deps.
    daemonLinkerSettings = []
}
#endif

#if os(Linux)
packageDependencies.append(.package(path: "../Vendor/GRDB-SQLCipher"))
daemonTargetDependencies.append(.product(name: "GRDB", package: "GRDB-SQLCipher"))
daemonTargetDependencies.append("COpenBurnBarMediaCapture")
daemonTargetDependencies.append("COpenBurnBarPortal")
daemonLinkerSettings.append(contentsOf: [
    .linkedLibrary("gio-2.0"),
    .linkedLibrary("gobject-2.0"),
    .linkedLibrary("glib-2.0")
])
if let mediaLibrary = linuxMediaCaptureLibraryIfPresent() {
    daemonLinkerSettings.append(.unsafeFlags(["-L", mediaLibrary.directory]))
    if let staticLibrary = mediaLibrary.staticLibrary {
        daemonLinkerSettings.append(.unsafeFlags([staticLibrary]))
    } else if mediaLibrary.dynamicLibrary != nil {
        daemonLinkerSettings.append(contentsOf: [
            .linkedLibrary("openburnbar_media"),
            .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", mediaLibrary.directory])
        ])
    }
    daemonLinkerSettings.append(contentsOf: [
        .linkedLibrary("gstreamer-1.0"),
        .linkedLibrary("gstbase-1.0"),
        .linkedLibrary("gstapp-1.0"),
        .linkedLibrary("gstvideo-1.0"),
        .linkedLibrary("gobject-2.0"),
        .linkedLibrary("glib-2.0")
    ])
    daemonSwiftSettings.append(.define("OPENBURNBAR_MEDIA_CAPTURE_LINKED"))
} else {
    daemonSwiftSettings.append(.define("OPENBURNBAR_MEDIA_CAPTURE_UNAVAILABLE"))
}
linuxSupportTargets.append(
    .systemLibrary(
        name: "COpenBurnBarMediaCapture",
        path: "Sources/COpenBurnBarMediaCapture"
    )
)
linuxSupportTargets.append(
    .target(
        name: "COpenBurnBarPortal",
        path: "Sources/COpenBurnBarPortal",
        publicHeadersPath: ".",
        cSettings: [
            .unsafeFlags([
                "-I/usr/include/glib-2.0",
                "-I/usr/include/gio-unix-2.0",
                "-I/usr/lib/aarch64-linux-gnu/glib-2.0/include",
                "-I/usr/lib/x86_64-linux-gnu/glib-2.0/include"
            ])
        ]
    )
)
#endif

#if os(Linux)
packagePlatforms = nil
daemonExcludes = [
    "ElderWandToolLoop.swift",
    "ElderWandWebTools.swift",
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
    "PensieveKnowledgeWatcher.swift",
    "DaemonSelfCodeSignatureVerifier.swift",
    "ElderWandFusionOrchestrator.swift",
    "OpenBurnBarSwitcherShell.swift",
    "PTYInteractiveSession.swift"
]
#endif

var packageProducts: [Product] = [
    .executable(
        name: "OpenBurnBarDaemon",
        targets: ["OpenBurnBarDaemonExecutable"]
    ),
    .executable(
        name: "OpenBurnBarCLI",
        targets: ["OpenBurnBarCLI"]
    )
]

var packageTargets: [Target] = [
    .target(
        name: "OpenBurnBarDaemon",
        dependencies: daemonTargetDependencies,
        exclude: daemonExcludes,
        cSettings: [
            .define("SQLITE_HAS_CODEC")
        ],
        swiftSettings: daemonSwiftSettings,
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
    .testTarget(
        name: "OpenBurnBarDaemonLinuxGatewayTests",
        dependencies: [
            "OpenBurnBarDaemon",
            // S17 repoint: the Linux-gateway harness links the UI-free Engine umbrella,
            // matching the daemon target under test (no path to the UI monolith).
            .product(name: "OpenBurnBarEngine", package: "OpenBurnBarCore"),
            .product(name: "OpenBurnBarComputerUseCore", package: "OpenBurnBarCore"),
            .product(name: "OpenBurnBarIrohRelay", package: "OpenBurnBarCore"),
            .product(name: "OpenBurnBarMedia", package: "OpenBurnBarCore")
        ],
        // Socket-level Linux gateway harness stays Swift 5 to avoid
        // region-isolation noise around POSIX buffers in XCTest helpers.
        swiftSettings: [.swiftLanguageMode(.v5)]
    )
] + linuxSupportTargets

#if os(macOS)
packageProducts.append(contentsOf: [
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
])

packageTargets.append(contentsOf: [
    .target(
        name: "OpenBurnBarRemoteAccessAgentCore",
        dependencies: [
            .product(name: "OpenBurnBarComputerUseCore", package: "OpenBurnBarCore"),
            // Phase-1 K2: the privileged-input binaries reach the OpenBurnBarCore
            // package ONLY through this target. Depend on the UI-free kernel
            // explicitly (for `Locked`) instead of transitively pulling the
            // SwiftUI/AppKit OpenBurnBarCore target through ComputerUseCore.
            .product(name: "OpenBurnBarKernel", package: "OpenBurnBarCore")
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
])
#endif

let package = Package(
    name: "OpenBurnBarDaemon",
    platforms: packagePlatforms,
    products: packageProducts,
    dependencies: packageDependencies,
    targets: packageTargets,
    swiftLanguageModes: [.v6]
)
