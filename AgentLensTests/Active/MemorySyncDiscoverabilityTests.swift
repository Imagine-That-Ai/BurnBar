import XCTest
@testable import OpenBurnBar

/// Memory sync used to be unfindable, and these cases are what "findable" means
/// in code rather than in a screenshot.
///
/// The bug: every memory-sync control lived on the *Indexing & Search* page,
/// three levels down the General tab, behind a row whose subtitle read "Local
/// index, embeddings, cross-encoder reranking". Meanwhile the Devices & Sync
/// tab carried a section literally headed "Sync" that held exactly one row —
/// about conversations. Someone looking for memory sync landed in the section
/// named after what they wanted and concluded the feature did not exist.
///
/// Each test below fails if a future edit puts it back.
final class MemorySyncDiscoverabilityTests: XCTestCase {

    // MARK: - The words a member actually types

    /// The three searches Alberto named. Each must land on the Memory Sync
    /// pane rather than on an indexing page or nothing at all.
    func test_searchingForSyncFindsTheMemorySyncPane() {
        for query in ["sync", "memory sync", "devices"] {
            let hits = SettingsSearchEngine.search(query, in: SettingsManifest.all)
            XCTAssertTrue(
                hits.contains { $0.pageRoute == .memorySync },
                "Searching \"\(query)\" must surface at least one Memory Sync setting"
            )
        }
    }

    /// The words somebody uses when they are describing the symptom rather than
    /// the feature: a second machine that is not seeing what the first learned.
    func test_searchingForTheSymptomFindsIt() {
        for query in ["other devices", "second mac", "cross-device"] {
            let hits = SettingsSearchEngine.search(query, in: SettingsManifest.all)
            XCTAssertTrue(
                hits.contains { $0.pageRoute == .memorySync },
                "Searching \"\(query)\" must surface the Memory Sync pane"
            )
        }
    }

    // MARK: - Where the settings actually live

    /// Every memory-sync control is filed under the Devices & Sync tab, which
    /// is where a member looks first.
    func test_everyMemorySyncSettingLivesUnderDevicesAndSync() {
        let items = SettingsManifest.all.filter { $0.pageRoute == .memorySync }
        XCTAssertFalse(items.isEmpty, "The Memory Sync pane must be represented in the manifest")
        for item in items {
            XCTAssertEqual(
                item.tab, .devicesAndSync,
                "\(item.id) routes to the Memory Sync pane but is filed under \(item.tab.rawValue)"
            )
        }
    }

    /// The two consent switches and the diagnostic are all present, so search
    /// can land on the specific control rather than only on the page.
    func test_theConsentSwitchesAndTheDiagnosticAreEachIndexed() {
        let ids = Set(SettingsManifest.all.filter { $0.pageRoute == .memorySync }.map(\.id))
        XCTAssertTrue(ids.contains("devices.memorySync.backup"))
        XCTAssertTrue(ids.contains("devices.memorySync.deviceToggle"))
        XCTAssertTrue(ids.contains("devices.memorySync.status"))
    }

    /// No memory-sync control may be left behind on the indexing page. A copy
    /// there would be a second switch bound to the same consent, and two
    /// switches for one consent is how a member ends up reading "On" in one
    /// place and "Off" in another.
    func test_noMemorySyncControlIsStillFiledUnderIndexing() {
        let strandedIDs = SettingsManifest.all
            .filter { $0.pageRoute == .indexing }
            .map(\.id)
            .filter { $0.contains("DeviceSync") || $0.contains("SyncStatus") || $0.contains("teamMemory") }
        XCTAssertEqual(
            strandedIDs, [],
            "These settings still claim to live on the Indexing page: \(strandedIDs)"
        )
    }

    // MARK: - One pane, two doors

    /// Both entry points push the SAME route, so there is one implementation
    /// of the switch and not two that can disagree.
    func test_bothEntryPointsResolveToTheOneCanonicalRoute() {
        // The signpost that stays on the Search & Memory page…
        let signpost = SettingsManifest.all.first { $0.id == "general.indexing.memorySyncLink" }
        XCTAssertEqual(signpost?.tab, .general)
        XCTAssertEqual(signpost?.pageRoute, .indexing, "The signpost is a row ON the indexing page")

        // …and the row in the Devices & Sync tab both name the same pane.
        let devicesRow = SettingsManifest.all.first { $0.id == "devices.memorySync" }
        XCTAssertEqual(devicesRow?.tab, .devicesAndSync)
        XCTAssertEqual(devicesRow?.pageRoute, .memorySync)

        // Both rows are labelled with the same words as the pane they open.
        XCTAssertEqual(devicesRow?.title, MemorySyncCopy.title)
    }

    // MARK: - Honesty

    /// The pull half and the engine merge are on `main` (#2519), so the copy is
    /// allowed to say memories arrive on another device — and it must say it
    /// plainly rather than implying a one-way backup.
    func test_theSummaryNamesBothHalvesAndTheDefault() {
        let summary = MemorySyncCopy.summary
        XCTAssertTrue(summary.contains("Off by default"), "Consent copy must lead with the default")
        XCTAssertTrue(
            summary.localizedCaseInsensitiveContains("arrive on your other signed-in devices"),
            "The pull half ships; the copy must say what actually happens"
        )
        XCTAssertTrue(
            summary.localizedCaseInsensitiveContains("sealed"),
            "The copy must say the memories are sealed before they leave the Mac"
        )
        XCTAssertTrue(
            summary.localizedCaseInsensitiveContains("holds no key"),
            "The copy must name what BurnBar can and cannot read"
        )
    }

    /// The boundary that will otherwise be discovered as a bug report: a
    /// non-git folder's memories travel but never converge, because its project
    /// identity is a per-machine path fingerprint.
    func test_theGitBoundaryIsStatedWhereTheMemberWillMeetIt() {
        XCTAssertTrue(MemorySyncCopy.gitBoundaryNote.localizedCaseInsensitiveContains("git repository"))
        XCTAssertTrue(MemorySyncCopy.gitBoundaryNote.localizedCaseInsensitiveContains("separate entries"))
    }

    /// The row summary reads the EFFECTIVE gate. A row that reported the raw
    /// sub-toggle would say "On" for a member whose entitlement lapsed, whose
    /// backup opt-in is off, or whose fleet ceiling is closed — none of whom is
    /// syncing anything.
    @MainActor
    func test_theRowSummaryReadsTheEffectiveGateNotTheRawSubToggle() {
        let settings = SettingsManager.shared
        let backup = settings.memoryApprovedCloudBackupOptIn
        let subToggle = settings.memoryDeviceSyncOptIn
        let entitlement = settings.memoryDeviceSyncEntitlementSatisfied
        defer {
            settings.memoryApprovedCloudBackupOptIn = backup
            settings.memoryDeviceSyncOptIn = subToggle
            settings.memoryDeviceSyncEntitlementSatisfied = entitlement
        }

        // Sub-toggle on, every other lever closed: the row must not claim "On".
        settings.memoryDeviceSyncOptIn = true
        settings.memoryApprovedCloudBackupOptIn = false
        settings.memoryDeviceSyncEntitlementSatisfied = false
        XCTAssertEqual(MemorySyncCopy.rowValue(settings), "Off")

        // Every lever open: the row says so.
        settings.memoryApprovedCloudBackupOptIn = true
        settings.memoryDeviceSyncEntitlementSatisfied = true
        XCTAssertEqual(
            MemorySyncCopy.rowValue(settings),
            settings.memoryDeviceSyncEnabled ? "On" : "Off"
        )
    }
}
