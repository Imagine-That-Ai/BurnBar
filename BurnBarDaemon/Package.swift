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
        .package(path: "../BurnBarCore")
    ],
    targets: [
        .target(
            name: "BurnBarDaemon",
            dependencies: [
                .product(name: "BurnBarCore", package: "BurnBarCore")
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
