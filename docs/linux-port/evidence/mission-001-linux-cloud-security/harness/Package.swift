// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LinuxSecurityEvidence",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LinuxSecurityEvidence", targets: ["LinuxSecurityEvidence"])
    ],
    dependencies: [
        .package(path: "../../../../../OpenBurnBarCore")
    ],
    targets: [
        .executableTarget(
            name: "LinuxSecurityEvidence",
            dependencies: [
                .product(name: "OpenBurnBarLinuxSecurity", package: "OpenBurnBarCore")
            ]
        )
    ]
)
