import Foundation
import XCTest
@testable import OpenBurnBarMobile

final class MediaInboxFileProtectionTests: XCTestCase {
    func testApplyMarksInboxFileCompleteAndBackupExcluded() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("media-inbox-protection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("blake3-feedface.heic")
        try Data([0x01, 0x02, 0x03]).write(to: fileURL)

        try MobileMediaInboxFileProtection.apply(to: fileURL)

        // NSFileProtectionComplete is enforced only on real devices with a
        // passcode; the iOS Simulator reports the attribute back as nil. Verify
        // it where the platform honors it, and always verify backup exclusion
        // (which the simulator does honor).
        #if !targetEnvironment(simulator)
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual(
            (attributes[.protectionKey] as? FileProtectionType)?.rawValue,
            FileProtectionType.complete.rawValue
        )
        #endif
        let resourceValues = try fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(resourceValues.isExcludedFromBackup, .some(true))
    }
}
