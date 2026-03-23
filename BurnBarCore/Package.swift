// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "BurnBarCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(
            name: "BurnBarCore",
            targets: ["BurnBarCore"]
        )
    ],
    targets: [
        .target(
            name: "BurnBarCore",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "BurnBarCoreTests",
            dependencies: ["BurnBarCore"]
        )
    ]
)
