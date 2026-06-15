import Foundation
import XCTest
@testable import OpenBurnBarMobile

final class MediaInboxFileProtectionTests: XCTestCase {
    func testApplyMarksInboxFileCompleteAndBackupExcluded() throws {
        let directory = try Self.makeDataProtectionCapableTestDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("blake3-feedface.heic")
        try Data([0x01, 0x02, 0x03]).write(to: fileURL)

        try MobileMediaInboxFileProtection.apply(to: fileURL)

        let resourceValues = try fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(
            resourceValues.isExcludedFromBackup,
            .some(true),
            "Inbox files must be backup-excluded so received media never lands in a device backup"
        )

        #if os(iOS)
        if !Self.isRunningInIOSSimulator {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            let observedProtection = (attributes[.protectionKey] as? FileProtectionType)?.rawValue
            XCTAssertEqual(
                observedProtection,
                FileProtectionType.complete.rawValue,
                "Inbox files must carry NSFileProtectionComplete on device"
            )
        }
        #endif
    }

    private static func makeDataProtectionCapableTestDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appendingPathComponent("media-inbox-protection-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private static var isRunningInIOSSimulator: Bool {
        ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] != nil
    }
}
