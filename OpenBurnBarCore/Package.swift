// swift-tools-version: 5.10

import PackageDescription
import Foundation

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let hasIrohXCFramework = FileManager.default.fileExists(
    atPath: packageRoot
        .appendingPathComponent("../Vendor/OpenBurnBarIroh.xcframework")
        .standardizedFileURL
        .path
)

let packageProducts: [Product] = [
    .library(
        name: "OpenBurnBarCore",
        targets: ["OpenBurnBarCore"]
    ),
    // Transport-agnostic iroh relay protocol + pairing + loopback
    // transport. When `Vendor/OpenBurnBarIroh.xcframework` exists, this
    // product also links the UniFFI-backed iroh QUIC bridge.
    .library(
        name: "OpenBurnBarIrohRelay",
        targets: ["OpenBurnBarIrohRelay"]
    ),
    // Mercury media substrate (file transfer, screen share, 1:1 video) —
    // see `plans/2026-05-15-mercury-media-master-plan.md`. Pure-Swift
    // shared types (frame codec, stream classes, bitrate controller,
    // capability gate, budget envelope). Platform implementations live
    // in `AgentLens/Services/Media/` and `OpenBurnBarMobile/Services/Media/`.
    .library(
        name: "OpenBurnBarMedia",
        targets: ["OpenBurnBarMedia"]
    )
] + (hasIrohXCFramework ? [
    .library(
        name: "OpenBurnBarIrohFFI",
        targets: ["OpenBurnBarIrohFFI"]
    )
] : [])

let irohRelayDependencies: [Target.Dependency] = hasIrohXCFramework
    ? ["OpenBurnBarCore", "OpenBurnBarIrohFFI"]
    : ["OpenBurnBarCore"]

let irohBinaryTargets: [Target] = hasIrohXCFramework ? [
    .binaryTarget(
        name: "openburnbar_irohFFI",
        path: "../Vendor/OpenBurnBarIroh.xcframework"
    ),
    .target(
        name: "OpenBurnBarIrohFFI",
        dependencies: ["openburnbar_irohFFI"],
        path: "Sources/OpenBurnBarIroh/Generated",
        exclude: [
            "openburnbar_iroh.modulemap",
            "openburnbar_irohFFI.h"
        ],
        linkerSettings: [
            .linkedFramework("SystemConfiguration")
        ]
    )
] : []

let package = Package(
    name: "OpenBurnBarCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: packageProducts,
    targets: irohBinaryTargets + [
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
            dependencies: irohRelayDependencies,
            linkerSettings: [
                .linkedFramework("SystemConfiguration")
            ]
        ),
        .target(
            name: "OpenBurnBarMedia",
            dependencies: ["OpenBurnBarCore", "OpenBurnBarIrohRelay"]
        ),
        .testTarget(
            name: "OpenBurnBarCoreTests",
            dependencies: ["OpenBurnBarCore"]
        ),
        .testTarget(
            name: "OpenBurnBarIrohRelayTests",
            dependencies: ["OpenBurnBarIrohRelay", "OpenBurnBarCore"]
        ),
        .testTarget(
            name: "OpenBurnBarMediaTests",
            dependencies: ["OpenBurnBarMedia", "OpenBurnBarCore", "OpenBurnBarIrohRelay"]
        )
    ]
)
