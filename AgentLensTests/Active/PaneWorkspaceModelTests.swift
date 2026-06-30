import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

/// Unit tests for the cmux-style pane-tiling tree (`PaneWorkspaceModel`): split, close
/// (non-primary reflow + primary re-home), the last-pane invariant, persistence round-trip,
/// the exactly-one-primary enforcement on restore, and the Codable snapshot.
@MainActor
final class PaneWorkspaceModelTests: XCTestCase {

    private let layoutKey = PaneWorkspaceModel.udPaneLayout

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: layoutKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: layoutKey)
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeController() throws -> ChatSessionController {
        let dataStore = try makeDiscoveryInMemoryStore()
        return ChatSessionController(
            dataStore: dataStore,
            searchService: ControlledChatSessionSearchProvider(responses: [:])
        )
    }

    private func makeWorkspace() throws -> PaneWorkspaceModel {
        let primary = try makeController()
        return PaneWorkspaceModel.restore(
            primaryController: primary,
            dataStore: primary.dataStore,
            settingsManager: primary.settingsManager
        )
    }

    // MARK: - Restore defaults

    func test_restore_noPersistedLayout_yieldsSinglePrimaryPane() throws {
        let ws = try makeWorkspace()
        XCTAssertEqual(ws.paneCount, 1)
        XCTAssertFalse(ws.isTiled)
        guard case .leaf(let leaf) = ws.root else { return XCTFail("root should be a leaf") }
        XCTAssertTrue(leaf.isPrimary)
        XCTAssertEqual(ws.activeLeafID, leaf.id)
        XCTAssertTrue(ws.activeController === ws.primaryController)
    }

    // MARK: - Split

    func test_splitActive_horizontal_makesTwoPanes_newOneActiveAndIsolated() throws {
        let ws = try makeWorkspace()
        let primaryLeafID = ws.activeLeafID
        ws.splitActive(axis: .horizontal)

        XCTAssertEqual(ws.paneCount, 2)
        XCTAssertTrue(ws.isTiled)
        guard case .split(let split) = ws.root else { return XCTFail("root should be a split") }
        XCTAssertEqual(split.axis, .horizontal)
        XCTAssertEqual(split.fraction, 0.5, accuracy: 0.0001)
        XCTAssertEqual(split.first.id, primaryLeafID, "original pane is the first child")
        XCTAssertEqual(ws.activeLeafID, split.second.id, "new pane becomes active")
        XCTAssertNotEqual(ws.activeLeafID, primaryLeafID)

        let newLeaf = try XCTUnwrap(ws.leaf(ws.activeLeafID))
        XCTAssertFalse(newLeaf.isPrimary)
        XCTAssertFalse(newLeaf.controller === ws.primaryController, "new pane has its own controller")
        XCTAssertFalse(newLeaf.controller.persistsViewState, "pane controllers never write global keys")
        XCTAssertNotEqual(newLeaf.controller.activeThreadID, ws.primaryController.activeThreadID,
                          "new pane is bound to its own thread")
        XCTAssertNotEqual(newLeaf.controller.activeThreadID, DataStore.legacyChatThreadID,
                          "new pane is never bound to the legacy thread")
    }

    func test_splitActive_vertical_setsVerticalAxis() throws {
        let ws = try makeWorkspace()
        ws.splitActive(axis: .vertical)
        guard case .split(let split) = ws.root else { return XCTFail("root should be a split") }
        XCTAssertEqual(split.axis, .vertical)
    }

    func test_split_twice_buildsThreeDistinctlyBoundPanes() throws {
        let ws = try makeWorkspace()
        ws.splitActive(axis: .horizontal)
        ws.splitActive(axis: .vertical)
        XCTAssertEqual(ws.paneCount, 3)
        let threadIDs = Set(ws.leaves.map { $0.controller.activeThreadID })
        XCTAssertEqual(threadIDs.count, 3, "every pane has a distinct bound thread")
        XCTAssertEqual(ws.leaves.filter { $0.isPrimary }.count, 1)
    }

    // MARK: - Close

    func test_closeActive_nonPrimary_reflowsToSurvivingPrimary() throws {
        let ws = try makeWorkspace()
        let primaryLeafID = ws.activeLeafID
        ws.splitActive(axis: .horizontal)
        XCTAssertEqual(ws.paneCount, 2)

        ws.closeActive() // closes the non-primary active pane
        XCTAssertEqual(ws.paneCount, 1)
        guard case .leaf(let leaf) = ws.root else { return XCTFail("root should collapse to a leaf") }
        XCTAssertEqual(leaf.id, primaryLeafID)
        XCTAssertTrue(leaf.isPrimary)
        XCTAssertEqual(ws.activeLeafID, primaryLeafID)
        XCTAssertTrue(ws.activeController === ws.primaryController)
    }

    func test_closeActive_primary_rehomesPrimaryControllerNotDropped() throws {
        let ws = try makeWorkspace()
        let primaryLeafID = ws.activeLeafID
        ws.splitActive(axis: .horizontal) // primary | A (A active)
        ws.setActive(primaryLeafID)        // focus the PRIMARY pane
        ws.closeActive()                   // close the primary pane → re-home onto survivor

        XCTAssertEqual(ws.paneCount, 1)
        guard case .leaf(let leaf) = ws.root else { return XCTFail("root should collapse to a leaf") }
        XCTAssertTrue(leaf.isPrimary, "exactly one primary leaf survives")
        XCTAssertTrue(leaf.controller === ws.primaryController,
                      "primary controller is preserved (re-homed), never dropped")
        XCTAssertEqual(ws.activeLeafID, leaf.id)
        XCTAssertTrue(ws.activeController === ws.primaryController)
    }

    func test_closeActive_lastPane_isIndestructible() throws {
        let ws = try makeWorkspace()
        let only = ws.activeLeafID
        ws.closeActive()
        XCTAssertEqual(ws.paneCount, 1)
        XCTAssertEqual(ws.activeLeafID, only)
    }

    func test_closeActive_keepsExactlyOnePrimaryAcrossNestedClose() throws {
        let ws = try makeWorkspace()
        ws.splitActive(axis: .horizontal) // primary | A
        ws.splitActive(axis: .vertical)   // primary | (A / B)
        XCTAssertEqual(ws.paneCount, 3)
        ws.closeActive()                  // close B
        XCTAssertEqual(ws.paneCount, 2)
        XCTAssertEqual(ws.leaves.filter { $0.isPrimary }.count, 1)
        XCTAssertTrue(ws.leaves.contains { $0.controller === ws.primaryController })
    }

    // MARK: - Persistence round-trip

    func test_persist_thenRestore_roundTripsStructureAndNonPrimaryThreads() throws {
        let ws = try makeWorkspace()
        ws.splitActive(axis: .horizontal)
        ws.splitActive(axis: .vertical)
        let beforeCount = ws.paneCount
        let beforeNonPrimaryThreads = Set(ws.leaves.filter { !$0.isPrimary }.map { $0.controller.activeThreadID })
        ws.persist()

        let primary2 = try makeController()
        let restored = PaneWorkspaceModel.restore(
            primaryController: primary2,
            dataStore: primary2.dataStore,
            settingsManager: primary2.settingsManager
        )
        XCTAssertEqual(restored.paneCount, beforeCount)
        XCTAssertEqual(restored.leaves.filter { $0.isPrimary }.count, 1, "exactly one primary after restore")
        XCTAssertTrue(restored.leaves.contains { $0.controller === primary2 }, "primary leaf reuses the app-wide controller")
        let restoredNonPrimaryThreads = Set(restored.leaves.filter { !$0.isPrimary }.map { $0.controller.activeThreadID })
        XCTAssertEqual(restoredNonPrimaryThreads, beforeNonPrimaryThreads,
                       "non-primary panes restore their exact bound threads")
    }

    // MARK: - Exactly-one-primary enforcement on a corrupt blob

    func test_restore_zeroPrimaryBlob_promotesFirstLeafToPrimary() throws {
        let snap = PaneWorkspaceSnapshot(
            root: .split(axis: .horizontal, fraction: 0.5,
                         first: .leaf(paneID: UUID(), threadID: "thread-a", isPrimary: false),
                         second: .leaf(paneID: UUID(), threadID: "thread-b", isPrimary: false)),
            activePaneID: UUID())
        UserDefaults.standard.set(try JSONEncoder().encode(snap), forKey: layoutKey)

        let primary = try makeController()
        let ws = PaneWorkspaceModel.restore(primaryController: primary, dataStore: primary.dataStore, settingsManager: primary.settingsManager)
        XCTAssertEqual(ws.leaves.filter { $0.isPrimary }.count, 1, "zero-primary blob is repaired to exactly one")
        XCTAssertTrue(ws.leaves.contains { $0.controller === primary })
        XCTAssertEqual(ws.paneCount, 2)
    }

    func test_restore_multiplePrimaryBlob_demotesExtras() throws {
        let snap = PaneWorkspaceSnapshot(
            root: .split(axis: .vertical, fraction: 0.5,
                         first: .leaf(paneID: UUID(), threadID: "thread-a", isPrimary: true),
                         second: .leaf(paneID: UUID(), threadID: "thread-b", isPrimary: true)),
            activePaneID: UUID())
        UserDefaults.standard.set(try JSONEncoder().encode(snap), forKey: layoutKey)

        let primary = try makeController()
        let ws = PaneWorkspaceModel.restore(primaryController: primary, dataStore: primary.dataStore, settingsManager: primary.settingsManager)
        XCTAssertEqual(ws.leaves.filter { $0.isPrimary }.count, 1, "only the first primary is kept")
        XCTAssertEqual(ws.paneCount, 2)
    }

    func test_restore_invalidActivePaneID_fallsBackToFirstLeaf() throws {
        let snap = PaneWorkspaceSnapshot(
            root: .leaf(paneID: UUID(), threadID: "thread-a", isPrimary: true),
            activePaneID: UUID()) // not present in the tree
        UserDefaults.standard.set(try JSONEncoder().encode(snap), forKey: layoutKey)

        let primary = try makeController()
        let ws = PaneWorkspaceModel.restore(primaryController: primary, dataStore: primary.dataStore, settingsManager: primary.settingsManager)
        XCTAssertEqual(ws.activeLeafID, try XCTUnwrap(ws.leaves.first).id)
    }

    func test_restore_fractionOutOfRange_isClamped() throws {
        let snap = PaneWorkspaceSnapshot(
            root: .split(axis: .horizontal, fraction: 0.99,
                         first: .leaf(paneID: UUID(), threadID: "a", isPrimary: true),
                         second: .leaf(paneID: UUID(), threadID: "b", isPrimary: false)),
            activePaneID: UUID())
        UserDefaults.standard.set(try JSONEncoder().encode(snap), forKey: layoutKey)

        let primary = try makeController()
        let ws = PaneWorkspaceModel.restore(primaryController: primary, dataStore: primary.dataStore, settingsManager: primary.settingsManager)
        guard case .split(let split) = ws.root else { return XCTFail("root should be a split") }
        XCTAssertLessThanOrEqual(split.fraction, PaneWorkspaceModel.maxFraction)
        XCTAssertGreaterThanOrEqual(split.fraction, PaneWorkspaceModel.minFraction)
    }

    // MARK: - boundThreadIDs

    func test_boundThreadIDs_includesEveryPane() throws {
        let ws = try makeWorkspace()
        ws.splitActive(axis: .horizontal)
        XCTAssertEqual(ws.boundThreadIDs, Set(ws.leaves.map { $0.controller.activeThreadID }))
        XCTAssertEqual(ws.boundThreadIDs.count, 2)
    }

    // MARK: - Codable snapshot (pure)

    func test_snapshot_codableRoundTrip() throws {
        let p = UUID(), q = UUID(), active = UUID()
        let snap = PaneWorkspaceSnapshot(
            root: .split(axis: .horizontal, fraction: 0.42,
                         first: .leaf(paneID: p, threadID: "t1", isPrimary: true),
                         second: .leaf(paneID: q, threadID: "t2", isPrimary: false)),
            activePaneID: active)
        let data = try JSONEncoder().encode(snap)
        let decoded = try JSONDecoder().decode(PaneWorkspaceSnapshot.self, from: data)

        XCTAssertEqual(decoded.activePaneID, active)
        guard case .split(let axis, let frac, let f, let s) = decoded.root else { return XCTFail("root should be a split") }
        XCTAssertEqual(axis, .horizontal)
        XCTAssertEqual(frac, 0.42, accuracy: 0.0001)
        guard case .leaf(let pid, let t1, let primary1) = f else { return XCTFail("first should be a leaf") }
        XCTAssertEqual(pid, p)
        XCTAssertEqual(t1, "t1")
        XCTAssertTrue(primary1)
        guard case .leaf(_, let t2, let primary2) = s else { return XCTFail("second should be a leaf") }
        XCTAssertEqual(t2, "t2")
        XCTAssertFalse(primary2)
    }
}
