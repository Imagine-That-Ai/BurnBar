// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "OpenBurnBarCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(
            name: "OpenBurnBarCore",
            type: .dynamic,
            targets: ["OpenBurnBarCore"]
        ),
        // Transport-agnostic iroh relay protocol + pairing + loopback
        // transport. The actual iroh QUIC transport lives behind the
        // `OpenBurnBarIrohTransport` Swift package (added once the
        // `OpenBurnBarIroh.xcframework` build lands in `Vendor/`).
        // This target is pure Swift and ships today so iOS + Mac can wire
        // the spine in their respective transport adapters and tests.
        .library(
            name: "OpenBurnBarIrohRelay",
            type: .dynamic,
            targets: ["OpenBurnBarIrohRelay"]
        )
    ],
    targets: [
        .target(
            name: "OpenBurnBarCore",
            resources: [
                // SwiftPM's `.process` rule flattens nested resource folders
                // so all files (catalog.json, MiningPickIcon*.svg, the Pretext
                // HTML + JS) end up at the root of the resource bundle. The
                // HTML's `<script src="pretext.bundle.min.js">` still
                // resolves correctly because both files are in the same
                // directory — just at the bundle root rather than a Pretext
                // subfolder. PretextEngine looks them up via Bundle.module
                // by filename.
                .process("Resources")
            ]
        ),
        .target(
            name: "OpenBurnBarIrohRelay",
            dependencies: ["OpenBurnBarCore"]
        ),
        .testTarget(
            name: "OpenBurnBarCoreTests",
            dependencies: ["OpenBurnBarCore"]
        ),
        .testTarget(
            name: "OpenBurnBarIrohRelayTests",
            dependencies: ["OpenBurnBarIrohRelay", "OpenBurnBarCore"]
        )
    ]
)
