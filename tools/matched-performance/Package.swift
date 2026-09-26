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
            // 3.3: narrowed off the OpenBurnBarCore umbrella (leaf types
            // resolve through Kernel's re-exports).
            dependencies: [
                .product(name: "OpenBurnBarComputerUseCore", package: "OpenBurnBarCore"),
                .product(name: "OpenBurnBarInsights", package: "OpenBurnBarCore"),
                .product(name: "OpenBurnBarKernel", package: "OpenBurnBarCore"),
                .product(name: "OpenBurnBarMedia", package: "OpenBurnBarCore"),
                .product(name: "OpenBurnBarQuota", package: "OpenBurnBarCore")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
