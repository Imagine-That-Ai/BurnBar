// swift-tools-version: 6.0
// SPDX-License-Identifier: AGPL-3.0-only

import PackageDescription

let package = Package(
    name: "OpenBurnBarMatchedPerformance",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "OpenBurnBarPerfProbe", targets: ["OpenBurnBarPerfProbe"]),
        .executable(name: "OpenBurnBarStreamPerfProbe", targets: ["OpenBurnBarStreamPerfProbe"])
    ],
    dependencies: [
        .package(path: "../../OpenBurnBarCore"),
        .package(path: "../../Vendor/GRDB-SQLCipher")
    ],
    targets: [
        .executableTarget(
            name: "OpenBurnBarPerfProbe",
            dependencies: [
                .product(name: "GRDB", package: "GRDB-SQLCipher")
            ]
        ),
        .executableTarget(
            name: "OpenBurnBarStreamPerfProbe",
            dependencies: [
                .product(name: "OpenBurnBarCore", package: "OpenBurnBarCore")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
