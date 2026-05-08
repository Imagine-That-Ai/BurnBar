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
        .testTarget(
            name: "OpenBurnBarCoreTests",
            dependencies: ["OpenBurnBarCore"]
        )
    ]
)
