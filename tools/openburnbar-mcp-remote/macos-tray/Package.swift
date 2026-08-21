// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OpenBurnBarGatewayTray",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "OpenBurnBarGatewayTray",
            path: "Sources"
        ),
    ]
)
