// swift-tools-version: 5.10
// SPDX-License-Identifier: AGPL-3.0-only

import PackageDescription
import Foundation

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let hasIrohXCFramework = FileManager.default.fileExists(
    atPath: packageRoot
        .appendingPathComponent("../Vendor/OpenBurnBarIroh.xcframework")
        .standardizedFileURL
        .path
)
let hasSignalFfiXCFramework = FileManager.default.fileExists(
    atPath: packageRoot
        .appendingPathComponent("../Vendor/OpenBurnBarSignalFfi.xcframework")
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
    ),
    // Computer Use substrate (Agent Watch, Browser CU, Mac CU,
    // Phone-as-controller). See
    // `plans/2026-05-16-computer-use-master-plan.md`. Pure-Swift
    // cross-platform shared types — session metadata, scope rules,
    // deny registry, audit chain, action descriptors, capability gate,
    // budget envelope. No AppKit. No AVFoundation. Mac runtime + iOS
    // runtime types live in `AgentLens/Services/ComputerUse/` and
    // `OpenBurnBarMobile/Services/ComputerUse/`.
    .library(
        name: "OpenBurnBarComputerUseCore",
        targets: ["OpenBurnBarComputerUseCore"]
    ),
    .library(
        name: "OpenBurnBarFirestoreModels",
        targets: ["OpenBurnBarFirestoreModels"]
    ),
    .library(
        name: "OpenBurnBarSignalCore",
        targets: ["OpenBurnBarSignalCore"]
    ),
    .library(
        name: "OpenBurnBarSignalSessionTransport",
        targets: ["OpenBurnBarSignalSessionTransport"]
    )
] + (hasIrohXCFramework ? [
    .library(
        name: "OpenBurnBarIrohFFI",
        targets: ["OpenBurnBarIrohFFI"]
    )
] : []) + (hasSignalFfiXCFramework ? [
    .library(
        name: "OpenBurnBarSignalFfi",
        targets: ["OpenBurnBarSignalFfi"]
    )
] : [])

let irohRelayDependencies: [Target.Dependency] = hasIrohXCFramework
    ? ["OpenBurnBarCore", "OpenBurnBarIrohFFI"]
    : ["OpenBurnBarCore"]

let irohBinaryTargets: [Target] = hasIrohXCFramework ? [
    .binaryTarget(
        name: "OpenBurnBarIroh",
        path: "../Vendor/OpenBurnBarIroh.xcframework"
    ),
    .target(
        name: "OpenBurnBarIrohFFI",
        dependencies: ["OpenBurnBarIroh"],
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

let signalCoreDependencies: [Target.Dependency] = [
    "OpenBurnBarCore",
    .product(name: "LibSignalClient", package: "LibSignalClient")
] + (hasSignalFfiXCFramework ? ["OpenBurnBarSignalFfi"] : [])

let signalBinaryTargets: [Target] = hasSignalFfiXCFramework ? [
    .binaryTarget(
        name: "OpenBurnBarSignalFfi",
        path: "../Vendor/OpenBurnBarSignalFfi.xcframework"
    )
] : []

let package = Package(
    name: "OpenBurnBarCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: packageProducts,
    dependencies: [
        .package(name: "LibSignalClient", path: "../Vendor/libsignal/swift"),
        .package(url: "https://github.com/swiftlang/swift-testing", from: "0.11.0")
    ],
    targets: irohBinaryTargets + signalBinaryTargets + [
        .target(
            name: "OpenBurnBarCore",
            // remediation(typespec-strangler): link the generated Firestore
            // canon into the production graph so it is no longer test-only.
            // Core gains a real `import OpenBurnBarFirestoreModels` consumer
            // (ProviderAccountDeviceLinkTypes+Generated.swift); anything that
            // links OpenBurnBarCore now transitively links the generated
            // models, so drift in the generated wire schema fails the
            // production build, not just the test target.
            dependencies: ["OpenBurnBarFirestoreModels"],
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
        .target(
            name: "OpenBurnBarComputerUseCore",
            dependencies: ["OpenBurnBarCore", "OpenBurnBarMedia"],
            linkerSettings: [
                .linkedFramework("Security", .when(platforms: [.macOS])),
                .linkedFramework("LocalAuthentication", .when(platforms: [.macOS]))
            ]
        ),
        .target(
            name: "OpenBurnBarFirestoreModels",
            // remediation(typespec-strangler): the generated canon imports only
            // Foundation and references no OpenBurnBarCore type, so the prior
            // `dependencies: ["OpenBurnBarCore"]` was spurious and — worse — it
            // formed a cycle that blocked Core (the natural first consumer) from
            // linking the generated models. Drop it so this stays a pure leaf
            // library that Core and the app targets can both depend on.
            path: "Sources/OpenBurnBarFirestoreModels"
        ),
        .target(
            name: "OpenBurnBarSignalCore",
            dependencies: signalCoreDependencies,
            path: "Sources/OpenBurnBarSignalCore"
        ),
        .target(
            name: "OpenBurnBarSignalSessionTransport",
            dependencies: [
                "OpenBurnBarCore",
                "OpenBurnBarIrohRelay",
                "OpenBurnBarSignalCore",
                .product(name: "LibSignalClient", package: "LibSignalClient")
            ],
            path: "Sources/OpenBurnBarSignalSessionTransport"
        ),
        .testTarget(
            name: "OpenBurnBarCoreTests",
            dependencies: [
                "OpenBurnBarCore",
                "OpenBurnBarFirestoreModels",
                .product(name: "Testing", package: "swift-testing")
            ],
            resources: [
                .process("Fixtures")
            ]
        ),
        .testTarget(
            name: "OpenBurnBarIrohRelayTests",
            dependencies: ["OpenBurnBarIrohRelay", "OpenBurnBarCore"]
        ),
        .testTarget(
            name: "OpenBurnBarMediaTests",
            dependencies: ["OpenBurnBarMedia", "OpenBurnBarCore", "OpenBurnBarIrohRelay"],
            resources: [
                .process("Fixtures")
            ]
        ),
        .testTarget(
            name: "OpenBurnBarComputerUseCoreTests",
            dependencies: [
                "OpenBurnBarComputerUseCore",
                "OpenBurnBarCore",
                "OpenBurnBarMedia"
            ],
            resources: [
                .process("Fixtures")
            ]
        ),
        .testTarget(
            name: "OpenBurnBarSignalCoreTests",
            dependencies: [
                "OpenBurnBarSignalCore",
                "OpenBurnBarCore",
                .product(name: "LibSignalClient", package: "LibSignalClient")
            ],
            resources: [
                .process("Fixtures")
            ]
        ),
        .testTarget(
            name: "OpenBurnBarSignalSessionTransportTests",
            dependencies: [
                "OpenBurnBarSignalSessionTransport",
                "OpenBurnBarSignalCore",
                "OpenBurnBarIrohRelay",
                "OpenBurnBarCore",
                .product(name: "LibSignalClient", package: "LibSignalClient")
            ]
        )
    ]
)
