// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "OpenBurnBarCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(
            name: "OpenBurnBarCore",
            type: .dynamic,
            targets: ["OpenBurnBarCore"]
        )
    ],
    targets: [
        .target(
            name: "OpenBurnBarCore",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "OpenBurnBarCoreTests",
            dependencies: ["OpenBurnBarCore"]
        )
    ]
)
