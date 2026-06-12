// swift-tools-version: 5.10
// SPDX-License-Identifier: AGPL-3.0-only
import PackageDescription

let package = Package(
    name: "CUClickSmoke",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../OpenBurnBarCore")
    ],
    targets: [
        .executableTarget(
            name: "CUClickSmoke",
            dependencies: [
                .product(name: "OpenBurnBarComputerUseCore", package: "OpenBurnBarCore")
            ],
            path: "Sources/CUClickSmoke"
        )
    ]
)
