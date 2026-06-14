import XCTest
@testable import OpenBurnBarMobile

/// T-TRN-02 (NodeId pin) + T-TRN-05 (monotonic replay protection) for phone-side
/// iroh pairing admission. Pure decision over an in-memory backing.
final class IrohPairingAdmissionStoreTests: XCTestCase {

    private final class InMemoryBacking: IrohPairingAdmissionStore.Backing, @unchecked Sendable {
        private let lock = NSLock()
        private var store: [String: IrohPairingAdmissionStore.Admission] = [:]
        private var forcedReadError: Int32?
        private var forcedWriteError: Int32?

        func failReads(with status: Int32) { lock.lock(); forcedReadError = status; lock.unlock() }
        func failWrites(with status: Int32) { lock.lock(); forcedWriteError = status; lock.unlock() }

        func load(account: String) -> IrohPairingAdmissionStore.LoadResult {
            lock.lock(); defer { lock.unlock() }
            if let forcedReadError { return .unreadable(forcedReadError) }
            if let admission = store[account] { return .found(admission) }
            return .absent
        }

        @discardableResult
        func save(_ admission: IrohPairingAdmissionStore.Admission, account: String) -> Int32 {
            lock.lock(); defer { lock.unlock() }
            if let forcedWriteError { return forcedWriteError }
            store[account] = admission
            return errSecSuccessCompatAdmission
        }

        func delete(account: String) {
            lock.lock(); defer { lock.unlock() }
            store[account] = nil
        }
    }

    private let uid = "uid-1"
    private let conn = "conn-1"

    func testFirstUsePinsNodeIdAndSeedsHighWater() {
        let store = IrohPairingAdmissionStore(backing: InMemoryBacking())
        let result = store.admit(nodeId: "node-A", publishedAtMillis: 1000, uid: uid, connectionId: conn)
        XCTAssertEqual(result, .admittedFirstUse)
        XCTAssertTrue(result.allowsDial)
        XCTAssertEqual(store.pinnedNodeId(uid: uid, connectionId: conn), "node-A")
        XCTAssertEqual(store.highWaterPublishedAtMillis(uid: uid, connectionId: conn), 1000)
    }

    func testNewerRecordForSameNodeAdvancesHighWater() {
        let store = IrohPairingAdmissionStore(backing: InMemoryBacking())
        _ = store.admit(nodeId: "node-A", publishedAtMillis: 1000, uid: uid, connectionId: conn)
        let result = store.admit(nodeId: "node-A", publishedAtMillis: 2000, uid: uid, connectionId: conn)
        XCTAssertEqual(result, .admitted)
        XCTAssertEqual(store.highWaterPublishedAtMillis(uid: uid, connectionId: conn), 2000)
    }

    func testReplayOfOlderRecordIsRefused() {
        let store = IrohPairingAdmissionStore(backing: InMemoryBacking())
        _ = store.admit(nodeId: "node-A", publishedAtMillis: 2000, uid: uid, connectionId: conn)
        let replay = store.admit(nodeId: "node-A", publishedAtMillis: 1500, uid: uid, connectionId: conn)
        XCTAssertEqual(replay, .staleReplay(highWater: 2000, candidate: 1500))
        XCTAssertFalse(replay.allowsDial, "A within-window replay of an older signed record must be refused (T-TRN-05).")
    }

    func testEqualTimestampIsTreatedAsReplay() {
        let store = IrohPairingAdmissionStore(backing: InMemoryBacking())
        _ = store.admit(nodeId: "node-A", publishedAtMillis: 2000, uid: uid, connectionId: conn)
        let again = store.admit(nodeId: "node-A", publishedAtMillis: 2000, uid: uid, connectionId: conn)
        XCTAssertFalse(again.allowsDial, "Re-consuming the exact same record must not be admitted again.")
    }

    func testNodeIdSwapIsRefused() {
        let store = IrohPairingAdmissionStore(backing: InMemoryBacking())
        _ = store.admit(nodeId: "node-A", publishedAtMillis: 1000, uid: uid, connectionId: conn)
        let swapped = store.admit(nodeId: "node-EVIL", publishedAtMillis: 5000, uid: uid, connectionId: conn)
        XCTAssertEqual(swapped, .nodeIdMismatch(pinned: "node-A"))
        XCTAssertFalse(swapped.allowsDial, "A reassigned/swapped NodeId must be refused until re-pair (T-TRN-02).")
    }

    func testEmptyNodeIdRefused() {
        let store = IrohPairingAdmissionStore(backing: InMemoryBacking())
        let result = store.admit(nodeId: "   ", publishedAtMillis: 1000, uid: uid, connectionId: conn)
        XCTAssertFalse(result.allowsDial)
    }

    func testKeychainReadErrorFailsClosed() {
        let backing = InMemoryBacking()
        backing.failReads(with: errSecMissingEntitlement)
        let store = IrohPairingAdmissionStore(backing: backing)
        let result = store.admit(nodeId: "node-A", publishedAtMillis: 1000, uid: uid, connectionId: conn)
        XCTAssertFalse(result.allowsDial)
    }

    func testWriteErrorOnFirstUseFailsClosed() {
        let backing = InMemoryBacking()
        backing.failWrites(with: errSecIO)
        let store = IrohPairingAdmissionStore(backing: backing)
        let result = store.admit(nodeId: "node-A", publishedAtMillis: 1000, uid: uid, connectionId: conn)
        XCTAssertFalse(result.allowsDial, "A non-durable admission must fail closed.")
    }

    func testClearAllowsRepair() {
        let store = IrohPairingAdmissionStore(backing: InMemoryBacking())
        _ = store.admit(nodeId: "node-A", publishedAtMillis: 5000, uid: uid, connectionId: conn)
        store.clear(uid: uid, connectionId: conn)
        XCTAssertNil(store.pinnedNodeId(uid: uid, connectionId: conn))
        // After re-pair, a brand-new NodeId + lower timestamp is trusted afresh.
        let result = store.admit(nodeId: "node-B", publishedAtMillis: 100, uid: uid, connectionId: conn)
        XCTAssertEqual(result, .admittedFirstUse)
    }

    func testScopedPerConnection() {
        let store = IrohPairingAdmissionStore(backing: InMemoryBacking())
        _ = store.admit(nodeId: "node-A", publishedAtMillis: 5000, uid: uid, connectionId: "conn-a")
        XCTAssertNil(store.pinnedNodeId(uid: uid, connectionId: "conn-b"))
    }
}
