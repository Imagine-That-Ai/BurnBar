// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ComputerUseMediaSecurityEvidence",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ComputerUseMediaSecurityEvidence", targets: ["ComputerUseMediaSecurityEvidence"])
    ],
    dependencies: [
        .package(path: "../../../../../OpenBurnBarCore")
    ],
    targets: [
        .executableTarget(
            name: "ComputerUseMediaSecurityEvidence",
            dependencies: [
                .product(name: "OpenBurnBarCore", package: "OpenBurnBarCore"),
                .product(name: "OpenBurnBarComputerUseCore", package: "OpenBurnBarCore"),
                .product(name: "OpenBurnBarMedia", package: "OpenBurnBarCore")
            ]
        )
    ]
)
