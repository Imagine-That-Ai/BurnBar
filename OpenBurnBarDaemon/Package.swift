// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "OpenBurnBarDaemon",
    platforms: [.macOS(.v14)],
    products: [
        .executable(
            name: "OpenBurnBarDaemon",
            targets: ["OpenBurnBarDaemonExecutable"]
        ),
        .executable(
            name: "OpenBurnBarCLI",
            targets: ["OpenBurnBarCLI"]
        )
    ],
    dependencies: [
        .package(path: "../OpenBurnBarCore"),
        // Pinned to same revision as `project.yml` (OpenBurnBar app target).
        .package(url: "https://github.com/SahebRoy92/GRDB-SQLCipher.git", exact: "6.29.3"),
        .package(url: "https://github.com/getsentry/sentry-cocoa", from: "8.0.0")
    ],
    targets: [
        .target(
            name: "OpenBurnBarDaemon",
            dependencies: [
                .product(name: "OpenBurnBarCore", package: "OpenBurnBarCore"),
                .product(name: "GRDB", package: "GRDB-SQLCipher"),
                .product(name: "Sentry", package: "sentry-cocoa")
            ],
            linkerSettings: [.unsafeFlags(["-framework", "Network"])]
        ),
        .executableTarget(
            name: "OpenBurnBarDaemonExecutable",
            dependencies: ["OpenBurnBarDaemon"]
        ),
        .executableTarget(
            name: "OpenBurnBarCLI",
            dependencies: ["OpenBurnBarDaemon"]
        ),
        .testTarget(
            name: "OpenBurnBarDaemonTests",
            dependencies: ["OpenBurnBarDaemon"]
        )
    ]
)
