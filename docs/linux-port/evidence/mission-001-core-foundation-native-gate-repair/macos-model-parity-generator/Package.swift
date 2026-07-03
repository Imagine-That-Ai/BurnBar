// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenBurnBarModelParityGenerator",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ModelParityGenerator", targets: ["ModelParityGenerator"])
    ],
    dependencies: [
        .package(path: "../../../../../OpenBurnBarCore")
    ],
    targets: [
        .executableTarget(
            name: "ModelParityGenerator",
            dependencies: [
                .product(name: "OpenBurnBarCore", package: "OpenBurnBarCore"),
                .product(name: "OpenBurnBarComputerUseCore", package: "OpenBurnBarCore"),
                .product(name: "OpenBurnBarMedia", package: "OpenBurnBarCore")
            ]
        )
    ]
)
