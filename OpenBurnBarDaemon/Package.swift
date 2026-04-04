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
        .package(url: "https://github.com/groue/GRDB.swift", from: "6.29.3")
    ],
    targets: [
        .target(
            name: "OpenBurnBarDaemon",
            dependencies: [
                .product(name: "OpenBurnBarCore", package: "OpenBurnBarCore"),
                .product(name: "GRDB", package: "GRDB.swift")
            ]
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
