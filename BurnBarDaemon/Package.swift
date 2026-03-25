// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "BurnBarDaemon",
    platforms: [.macOS(.v14)],
    products: [
        .executable(
            name: "BurnBarDaemon",
            targets: ["BurnBarDaemonExecutable"]
        )
    ],
    dependencies: [
        .package(path: "../BurnBarCore"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0")
    ],
    targets: [
        .target(
            name: "BurnBarDaemon",
            dependencies: [
                .product(name: "BurnBarCore", package: "BurnBarCore"),
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),
        .executableTarget(
            name: "BurnBarDaemonExecutable",
            dependencies: ["BurnBarDaemon"]
        ),
        .testTarget(
            name: "BurnBarDaemonTests",
            dependencies: ["BurnBarDaemon"]
        )
    ]
)
