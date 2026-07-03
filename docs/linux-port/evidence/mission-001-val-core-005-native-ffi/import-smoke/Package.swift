// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VALCore005ImportSmoke",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(name: "OpenBurnBarCore", path: "../../../../../OpenBurnBarCore"),
        .package(name: "LibSignalClient", path: "../../../../../Vendor/libsignal/swift")
    ],
    targets: [
        .executableTarget(
            name: "ImportSmoke",
            dependencies: [
                .product(name: "LibSignalClient", package: "LibSignalClient"),
                .product(name: "OpenBurnBarSignalCore", package: "OpenBurnBarCore"),
                .product(name: "OpenBurnBarSignalSessionTransport", package: "OpenBurnBarCore"),
                .product(name: "OpenBurnBarIrohFFI", package: "OpenBurnBarCore"),
                .product(name: "OpenBurnBarIrohRelay", package: "OpenBurnBarCore"),
                .product(name: "OpenBurnBarMedia", package: "OpenBurnBarCore"),
                .product(name: "OpenBurnBarComputerUseCore", package: "OpenBurnBarCore")
            ]
        )
    ]
)
