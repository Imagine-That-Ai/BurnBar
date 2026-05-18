// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "CUClickSmoke",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../OpenBurnBarCore"),
    ],
    targets: [
        .executableTarget(
            name: "CUClickSmoke",
            dependencies: [
                .product(name: "OpenBurnBarComputerUseCore", package: "OpenBurnBarCore"),
            ],
            path: "Sources/CUClickSmoke"
        ),
    ]
)
