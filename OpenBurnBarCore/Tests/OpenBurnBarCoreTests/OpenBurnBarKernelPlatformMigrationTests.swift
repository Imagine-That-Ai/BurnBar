import Foundation
import XCTest
@testable import OpenBurnBarKernel

final class OpenBurnBarKernelPlatformMigrationTests: XCTestCase {
    func testPublicMigrationInitializersAreUsableFromTheKernelProduct() throws {
        let suiteName = "com.openburnbar.kernel-platform-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let defaultsMigration = OpenBurnBarDefaultsMigration(
            defaults: defaults,
            legacyDomains: ["com.agentlens.legacy.\(UUID().uuidString)"]
        )
        defaultsMigration.migrateIfNeeded()

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-kernel-platform-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = OpenBurnBarAppPaths(applicationSupportRoot: root)
        let filesystemMigration = OpenBurnBarFilesystemMigration(
            fileManager: .default,
            paths: paths
        )

        XCTAssertEqual(try filesystemMigration.prepareSupportDirectory(), paths.supportDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.supportDirectory.path))
    }
}
