// swift-tools-version:5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import Foundation
import PackageDescription

var swiftSettings: [SwiftSetting] = [
    .define("SQLITE_ENABLE_FTS5"),
    .define("SQLITE_HAS_CODEC"),
    .define("GRDBCIPHER"),
]
var cSettings: [CSetting] = []
let configuredSQLCipherDirectory = ProcessInfo.processInfo.environment["OPENBURNBAR_SQLCIPHER_LIB_DIR"]?
    .trimmingCharacters(in: .whitespacesAndNewlines)
let explicitSQLCipherLibrary: String? = configuredSQLCipherDirectory.flatMap { directory in
    guard directory.isEmpty == false else { return nil }
    let path = URL(fileURLWithPath: directory)
        .appendingPathComponent("libsqlcipher.so.0")
        .standardizedFileURL
        .path
    return FileManager.default.fileExists(atPath: path) ? path : nil
}
let useSystemSQLCipher = ProcessInfo.processInfo.environment["OPENBURNBAR_USE_SYSTEM_SQLCIPHER"] == "1"
    || ProcessInfo.processInfo.environment["OPENBURNBAR_SQLCIPHER_PREFIX"] != nil
    || explicitSQLCipherLibrary != nil
let sqlcipherLinkerSettings: [LinkerSetting] = explicitSQLCipherLibrary.map { library in
    [
        .unsafeFlags([library]),
        .unsafeFlags([
            "-Xlinker", "-rpath", "-Xlinker", configuredSQLCipherDirectory ?? ""
        ])
    ]
}.flatMap { $0 } ?? []
var dependencies: [PackageDescription.Package.Dependency] = useSystemSQLCipher ? [] : [
    .package(url: "https://github.com/sqlcipher/SQLCipher.swift.git", exact: "4.16.0"),
]

// For Swift 5.8+
//swiftSettings.append(.enableUpcomingFeature("ExistentialAny"))

// Don't rely on those environment variables. They are ONLY testing conveniences:
// $ SQLITE_ENABLE_PREUPDATE_HOOK=1 make test_SPM
if ProcessInfo.processInfo.environment["SQLITE_ENABLE_PREUPDATE_HOOK"] == "1" {
    swiftSettings.append(.define("SQLITE_ENABLE_PREUPDATE_HOOK"))
    cSettings.append(.define("GRDB_SQLITE_ENABLE_PREUPDATE_HOOK"))
}

// The SPI_BUILDER environment variable enables documentation building
// on <https://swiftpackageindex.com/groue/GRDB.swift>. See
// <https://github.com/SwiftPackageIndex/SwiftPackageIndex-Server/issues/2122>
// for more information.
//
// SPI_BUILDER also enables the `make docs-localhost` command.
if ProcessInfo.processInfo.environment["SPI_BUILDER"] == "1" {
    dependencies.append(.package(url: "https://github.com/apple/swift-docc-plugin", from: "1.0.0"))
}

let package = Package(
    name: "GRDB-SQLCipher",
    platforms: [
        .iOS(.v11),
        .macOS(.v10_13),
        .tvOS(.v11),
        .watchOS(.v4),
    ],
    products: [
        .library(name: "CSQLite", targets: ["CSQLite"]),
        .library(name: "GRDB", targets: ["GRDB"]),
        .library(name: "GRDB-dynamic", type: .dynamic, targets: ["GRDB"]),
    ],
    dependencies: dependencies,
    targets: [
        .systemLibrary(
            name: "CSQLite",
            // The SQLCipher.swift binary target supplies the Apple-platform
            // framework and link directive. Asking pkg-config for SQLCipher at
            // the same time silently adds a second, machine-local Homebrew
            // libsqlcipher.dylib to every SwiftPM executable; hardened runtime
            // then rejects that foreign-team library. Only system-runtime
            // builds (Linux or an explicit local override) may consult
            // pkg-config. An explicitly staged Linux .so is linked below.
            pkgConfig: useSystemSQLCipher && explicitSQLCipherLibrary == nil ? "sqlcipher" : nil,
            providers: [
                .apt(["libsqlcipher-dev"]),
                .brew(["sqlcipher"])
            ]
        ),
        .target(
            name: "GRDB",
            dependencies: useSystemSQLCipher ? [
                "CSQLite",
            ] : [
                "CSQLite",
                .product(name: "SQLCipher", package: "SQLCipher.swift"),
            ],
            path: "GRDB",
            resources: [.copy("PrivacyInfo.xcprivacy")],
            cSettings: cSettings,
            swiftSettings: swiftSettings,
            linkerSettings: sqlcipherLinkerSettings)
    ],
    swiftLanguageVersions: [.v5]
)
