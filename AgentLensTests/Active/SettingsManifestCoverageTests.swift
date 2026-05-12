import XCTest
@testable import OpenBurnBar

/// Guards the macOS Settings manifest against drift:
/// - every item has a unique stable id
/// - every anchor id is unique (collisions break scroll targets)
/// - every focus id appears in `SettingsFocus`
/// - every `tab` is a real `SettingsTab` case (compile-time, but verify
///   coverage breadth so we don't accidentally drop a tab)
final class SettingsManifestCoverageTests: XCTestCase {

    func test_manifest_isNotEmpty() {
        XCTAssertFalse(SettingsManifest.all.isEmpty,
                       "Manifest must contain at least one entry")
    }

    func test_allIdentifiersAreUnique() {
        let ids = SettingsManifest.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count,
                       "Duplicate SettingsItem ids in SettingsManifest")
    }

    func test_allAnchorsAreUnique() {
        let anchors = SettingsManifest.all.map(\.anchorID)
        XCTAssertEqual(anchors.count, Set(anchors).count,
                       "Duplicate anchorIDs in SettingsManifest")
    }

    func test_anchorIndexCoversEveryItem() {
        for item in SettingsManifest.all {
            XCTAssertEqual(SettingsManifest.anchorIndex[item.anchorID],
                           item.pageRoute,
                           "Anchor \(item.anchorID) missing from anchorIndex")
        }
    }

    func test_focusIDsMatchKnownVocabulary() {
        let known: Set<String> = [
            SettingsFocus.gatewayHost,
            SettingsFocus.gatewayPort,
            SettingsFocus.gatewayAuthToken,
            SettingsFocus.hermesGatewayURL,
            SettingsFocus.hermesGatewayToken,
            SettingsFocus.alertsDailySpend,
        ]
        for item in SettingsManifest.all {
            guard let focus = item.focusID else { continue }
            XCTAssertTrue(known.contains(focus),
                          "Unknown focusID \(focus) on item \(item.id)")
        }
    }

    func test_eachTabHasAtLeastOneEntry() {
        let tabs = Set(SettingsManifest.all.map(\.tab))
        for tab in SettingsTab.allCases {
            XCTAssertTrue(tabs.contains(tab),
                          "SettingsTab.\(tab.rawValue) is not represented in the manifest")
        }
    }
}
