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

    // MARK: - PaneDropZone.classify

    func test_paneDropZone_classify_interiorPoint_returnsCenter() {
        let size = CGSize(width: 400, height: 300)
        XCTAssertEqual(PaneDropZone.classify(CGPoint(x: 200, y: 150), in: size), .center)
    }

    func test_paneDropZone_classify_edgeRegions_returnMatchingZones() {
        let size = CGSize(width: 400, height: 300)
        XCTAssertEqual(PaneDropZone.classify(CGPoint(x: 20, y: 150), in: size), .leading)
        XCTAssertEqual(PaneDropZone.classify(CGPoint(x: 380, y: 150), in: size), .trailing)
        XCTAssertEqual(PaneDropZone.classify(CGPoint(x: 200, y: 10), in: size), .top)
        XCTAssertEqual(PaneDropZone.classify(CGPoint(x: 200, y: 290), in: size), .bottom)
    }

    func test_paneDropZone_classify_topLeftCorner_tieBreaksToLeading() {
        let size = CGSize(width: 400, height: 300)
        XCTAssertEqual(PaneDropZone.classify(CGPoint(x: 0, y: 0), in: size), .leading)
    }

    func test_paneDropZone_classify_zeroSize_returnsCenter() {
        XCTAssertEqual(PaneDropZone.classify(CGPoint(x: 10, y: 10), in: .zero), .center)
    }

    func test_paneDropZone_classify_outOfBounds_clampsToNearestEdge() {
        let size = CGSize(width: 400, height: 300)
        XCTAssertEqual(PaneDropZone.classify(CGPoint(x: -50, y: 150), in: size), .leading)
        XCTAssertEqual(PaneDropZone.classify(CGPoint(x: 500, y: 150), in: size), .trailing)
    }

    func test_paneDropZone_derivedProperties_matchZoneSemantics() {
        let expectations: [(PaneDropZone, PaneSplitAxis?, Bool, CGRect)] = [
            (.center, nil, false, CGRect(x: 0, y: 0, width: 1, height: 1)),
            (.leading, .horizontal, true, CGRect(x: 0, y: 0, width: 0.5, height: 1)),
            (.trailing, .horizontal, false, CGRect(x: 0.5, y: 0, width: 0.5, height: 1)),
            (.top, .vertical, true, CGRect(x: 0, y: 0, width: 1, height: 0.5)),
            (.bottom, .vertical, false, CGRect(x: 0, y: 0.5, width: 1, height: 0.5)),
        ]
        for (zone, axis, placesFirst, highlight) in expectations {
            XCTAssertEqual(zone.splitAxis, axis, "\(zone) splitAxis")
            XCTAssertEqual(zone.placesNewLeafFirst, placesFirst, "\(zone) placesNewLeafFirst")
            XCTAssertEqual(zone.highlightUnitRect, highlight, "\(zone) highlightUnitRect")
        }
    }

    // MARK: - splitLeaf (drag-to-split)

    func test_splitLeaf_horizontal_newLeafSecond_bindsDraggedThread() throws {
        let ws = try makeWorkspace()
        let rootLeafID = ws.activeLeafID
        let draggedThread = "dragged-thread-1"

        ws.splitLeaf(rootLeafID, axis: .horizontal, placingThreadID: draggedThread, newLeafFirst: false)

        XCTAssertEqual(ws.paneCount, 2)
        guard case .split(let split) = ws.root else { return XCTFail("root should be a split") }
        XCTAssertEqual(split.axis, .horizontal)
        XCTAssertEqual(split.fraction, 0.5, accuracy: 0.0001)
        guard case .leaf(let firstLeaf) = split.first else { return XCTFail("first child should be a leaf") }
        guard case .leaf(let secondLeaf) = split.second else { return XCTFail("second child should be a leaf") }
        XCTAssertEqual(firstLeaf.id, rootLeafID, "original leaf stays first")
        XCTAssertEqual(secondLeaf.id, ws.activeLeafID, "new leaf is second and active")
        XCTAssertEqual(secondLeaf.controller.activeThreadID, draggedThread)
        XCTAssertEqual(draggedThread, secondLeaf.controller.activeThreadID,
                       "bound thread is the passed string, not a minted id")
    }

    func test_splitLeaf_horizontal_newLeafFirst_placesDraggedLeafFirst() throws {
        let ws = try makeWorkspace()
        let rootLeafID = ws.activeLeafID
        let draggedThread = "dragged-thread-first"

        ws.splitLeaf(rootLeafID, axis: .horizontal, placingThreadID: draggedThread, newLeafFirst: true)

        guard case .split(let split) = ws.root else { return XCTFail("root should be a split") }
        guard case .leaf(let firstLeaf) = split.first else { return XCTFail("first child should be a leaf") }
        guard case .leaf(let secondLeaf) = split.second else { return XCTFail("second child should be a leaf") }
        XCTAssertEqual(firstLeaf.controller.activeThreadID, draggedThread)
        XCTAssertEqual(secondLeaf.id, rootLeafID, "target leaf moves to second")
        XCTAssertEqual(ws.activeLeafID, firstLeaf.id)
    }

    func test_splitLeaf_vertical_setsVerticalAxis() throws {
        let ws = try makeWorkspace()
        ws.splitLeaf(ws.activeLeafID, axis: .vertical, placingThreadID: "dragged-vertical", newLeafFirst: false)
        guard case .split(let split) = ws.root else { return XCTFail("root should be a split") }
        XCTAssertEqual(split.axis, .vertical)
    }

    func test_splitLeaf_nonActiveLeaf_splitsUnderTargetAndActivatesNewLeaf() throws {
        let ws = try makeWorkspace()
        ws.splitActive(axis: .horizontal)
        guard case .split(let rootSplit) = ws.root else { return XCTFail("root should be a split") }
        let activeAfterFirstSplit = ws.activeLeafID
        let inactiveLeafID = rootSplit.first.id == activeAfterFirstSplit ? rootSplit.second.id : rootSplit.first.id
        XCTAssertNotEqual(inactiveLeafID, activeAfterFirstSplit)

        let draggedThread = "dragged-thread-non-active"
        ws.splitLeaf(inactiveLeafID, axis: .horizontal, placingThreadID: draggedThread, newLeafFirst: false)

        XCTAssertEqual(ws.paneCount, 3)
        let newLeaf = try XCTUnwrap(ws.leaves.first { $0.controller.activeThreadID == draggedThread })
        XCTAssertEqual(ws.activeLeafID, newLeaf.id)
        XCTAssertNotEqual(newLeaf.id, inactiveLeafID)

        guard case .split(let outer) = ws.root else { return XCTFail("root should remain a split") }
        let nestedBranch: PaneNode
        switch outer.first {
        case .split:
            nestedBranch = outer.first
        case .leaf:
            guard case .split = outer.second else { return XCTFail("inactive branch should be a nested split") }
            nestedBranch = outer.second
        }
        guard case .split(let inner) = nestedBranch else { return XCTFail("expected nested split under inactive leaf") }
        let nestedChildIDs = Set([inner.first.id, inner.second.id])
        XCTAssertTrue(nestedChildIDs.contains(inactiveLeafID), "target leaf remains under the split")
        XCTAssertTrue(nestedChildIDs.contains(newLeaf.id), "new leaf sits beside the target")
    }

}
