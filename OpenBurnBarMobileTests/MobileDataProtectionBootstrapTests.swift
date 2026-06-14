import XCTest
import OpenBurnBarCore
@testable import OpenBurnBarMobile

// MARK: - Data-protection bootstrap + App Group hardening (T-IOS-01 / T-IOS-11)
//
// Locks the at-rest posture: the bootstrap targets the App Group container,
// uses the strong protection class everywhere (including the asserted Firestore
// on-disk cache class), and the App Group writer hardening applies the same
// class. These exercise the constants + the App-Group protection seam against a
// temp directory so no device / real container is required.

final class MobileDataProtectionBootstrapTests: XCTestCase {

    func testBootstrapTargetsSharedAppGroup() {
        XCTAssertEqual(
            MobileDataProtectionBootstrap.appGroupIdentifier,
            TextExpansionSnapshotStore.appGroupIdentifier,
            "The bootstrap must sweep the same App Group the keyboard/widget share"
        )
    }

    func testFirestoreCacheProtectionClassIsStrong() {
        // T-IOS-11 — the Firestore offline cache holds decrypted query results;
        // it must inherit the strong protection class, not the weaker
        // first-unlock default.
        XCTAssertEqual(
            MobileDataProtectionBootstrap.firestoreCacheProtectionClass,
            .completeUnlessOpen
        )
    }

    func testAppGroupProtectionUsesStrongClass() {
        XCTAssertEqual(AppGroupDataProtection.desiredProtection, .completeUnlessOpen)
    }

    func testProtectExcludesFileFromBackup() throws {
        let fileManager = FileManager.default
        let dir = fileManager.temporaryDirectory
            .appendingPathComponent("appgroup-protect-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: dir) }

        let file = dir.appendingPathComponent("snapshot.json")
        try Data("{}".utf8).write(to: file)

        AppGroupDataProtection.protect(file, fileManager: fileManager)

        let values = try file.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(
            values.isExcludedFromBackup, true,
            "A hardened App Group file must be excluded from backup"
        )
    }
}
