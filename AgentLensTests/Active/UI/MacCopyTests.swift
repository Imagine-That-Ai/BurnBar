import XCTest
@testable import OpenBurnBar

final class MacCopyTests: XCTestCase {

    func test_requiredLabelsArePresent() {
        XCTAssertEqual(MacCopy.cloudSyncHealthy, "Cloud sync healthy")
        XCTAssertEqual(MacCopy.cloudSyncDegraded, "Cloud sync degraded")
        XCTAssertEqual(MacCopy.lastPublished, "Last published")
        XCTAssertEqual(MacCopy.approveDevice, "Approve device")
        XCTAssertEqual(MacCopy.revokeDevice, "Revoke device")
        XCTAssertEqual(MacCopy.transferEncryptedCredential, "Transfer encrypted credential")
        XCTAssertEqual(MacCopy.credentialTransferUnavailable, "Credential transfer unavailable")
    }

    func test_forbiddenStringsAbsent() {
        let allCopy = [
            MacCopy.cloudSyncSectionTitle,
            MacCopy.thisDeviceSectionTitle,
            MacCopy.otherDevicesSectionTitle,
            MacCopy.activeGrantsSectionTitle,
            MacCopy.bootstrapPrompt,
            MacCopy.transferConfirmCopy,
            MacCopy.unsupportedBrowserSession,
            MacCopy.unsupportedNotPortable,
            MacCopy.unsupportedNoExport,
            MacCopy.unsupportedKindUnknown,
            MacCopy.transferableAPIKey,
            MacCopy.transferableOAuth,
            MacCopy.transferableBearer
        ]
        for copy in allCopy {
            XCTAssertFalse(copy.contains(MacCopy.Forbidden.credentialsSyncAuto),
                           "Forbidden phrase 'All credentials sync automatically' present in: \(copy)")
            XCTAssertFalse(copy.contains(MacCopy.Forbidden.firebaseStoresKeys),
                           "Forbidden phrase 'Firebase stores your provider keys' present in: \(copy)")
        }
    }

    func test_settingsTabIncludesDevicesAndSync() {
        XCTAssertTrue(SettingsTab.allCases.contains(.devicesAndSync))
        XCTAssertEqual(SettingsTab.devicesAndSync.title, MacCopy.devicesAndSyncTitle)
    }
}
