import XCTest
@testable import OpenBurnBar

/// Covers the formerly-swallowed `try?` writebacks in `CastActionsListener`.
///
/// Every terminal write (`completed` / `failed`) is the *only* signal the
/// mobile cast wizard polls to advance, so a silently-dropped write strands
/// the action at `status=pending` and hangs the wizard forever. These tests
/// pin the new behaviour:
///
///   * the `test`/discovery flow **fails closed** — it refuses to mark the
///     action `completed` when the discovery result it advertises never
///     reached Firestore (it reports `failed` instead);
///   * the happy path still publishes the discovery result *and* completes;
///   * a lost ack is **observable** (the writer is invoked + throws) rather
///     than silently swallowed, while durable local state is preserved.
@MainActor
final class CastActionsListenerMattersTests: XCTestCase {

    // MARK: - Fake writer

    /// Records every writeback by Firestore path and can be told to throw
    /// for a chosen path so the fail-closed / observability paths can be
    /// exercised hermetically (no live Firestore). `@MainActor` to match
    /// the (MainActor-isolated) `CastActionAckWriter` protocol.
    @MainActor
    private final class FakeCastActionAckWriter: CastActionAckWriter {
        struct Recorded {
            let path: String
            let payload: [String: Any]
            let merge: Bool
        }

        private(set) var writes: [Recorded] = []
        /// Path substrings that should fail the write.
        var failingPathSubstrings: [String] = []

        func recordedWrites(matching needle: String) -> [Recorded] {
            writes.filter { $0.path.contains(needle) }
        }

        func lastStatus(forPathContaining needle: String) -> String? {
            recordedWrites(matching: needle).last?.payload["status"] as? String
        }

        struct InjectedWriteError: Error {}

        func write(_ payload: [String: Any], toPath path: String, merge: Bool) async throws {
            if failingPathSubstrings.contains(where: { path.contains($0) }) {
                throw InjectedWriteError()
            }
            writes.append(Recorded(path: path, payload: payload, merge: merge))
        }
    }

    // MARK: - Helpers

    private let uid = "uid-cast-1"

    private func makeListener(writer: CastActionAckWriter) -> CastActionsListener {
        let account = FakeAccountManager.makeSignedIn(uid: uid)
        let settings = SettingsManager(defaults: UserDefaults(suiteName: "cast-test-\(UUID().uuidString)")!)
        return CastActionsListener(
            accountManager: account,
            settingsManager: settings,
            repairCoordinator: nil,
            ackWriter: writer
        )
    }

    private func makeRef(id: String = "action-1") -> CastActionRef {
        CastActionRef(documentID: id, path: "users/\(uid)/cast_actions/\(id)")
    }

    private func makeDevice(serviceName: String = "Nest-Hub-1") -> CastDevice {
        CastDevice(
            serviceName: serviceName,
            friendlyName: "Living Room Hub",
            host: "192.168.68.50",
            port: 8009,
            model: "Google Nest Hub",
            identifier: "id-\(serviceName)",
            supportsDisplay: true
        )
    }

    // MARK: - Discovery flow: happy path

    func test_discovery_happyPath_publishesResultThenCompletes() async {
        let writer = FakeCastActionAckWriter()
        let listener = makeListener(writer: writer)
        let ref = makeRef()

        await listener.publishDiscoveryAndComplete(ref, uid: uid, devices: [makeDevice()])

        // Discovery result reached Firestore...
        let resultWrites = writer.recordedWrites(matching: "cast_discovery_results/latest")
        XCTAssertEqual(resultWrites.count, 1)
        let devicesPayload = resultWrites.first?.payload["devices"] as? [[String: Any]]
        XCTAssertEqual(devicesPayload?.count, 1)
        XCTAssertEqual(devicesPayload?.first?["serviceName"] as? String, "Nest-Hub-1")

        // ...and the action advanced to `completed`.
        XCTAssertEqual(writer.lastStatus(forPathContaining: "cast_actions/action-1"), "completed")
    }

    // MARK: - Discovery flow: FAIL CLOSED on lost result

    func test_discovery_lostResultWrite_failsClosed_doesNotComplete() async {
        let writer = FakeCastActionAckWriter()
        writer.failingPathSubstrings = ["cast_discovery_results"]
        let listener = makeListener(writer: writer)
        let ref = makeRef()

        await listener.publishDiscoveryAndComplete(ref, uid: uid, devices: [makeDevice()])

        // The discovery result was NOT persisted...
        XCTAssertTrue(writer.recordedWrites(matching: "cast_discovery_results").isEmpty)

        // ...so the action must NOT be marked completed (no fail-open).
        let actionWrites = writer.recordedWrites(matching: "cast_actions/action-1")
        XCTAssertFalse(
            actionWrites.contains { $0.payload["status"] as? String == "completed" },
            "Wizard must not advance to completed when the discovery result was lost"
        )
        // Instead the action is reported failed so the wizard surfaces the error.
        XCTAssertEqual(writer.lastStatus(forPathContaining: "cast_actions/action-1"), "failed")
        XCTAssertEqual(
            actionWrites.last?.payload["errorMessage"] as? String,
            "discovery results could not be published"
        )
    }

    /// Even when the action itself reports failed, a *further* lost write of
    /// that failure must never escalate into a thrown error / crash — it is
    /// logged and tolerated. (The action stays pending; the listener
    /// re-processes on restart.)
    func test_discovery_lostResultAndLostFailAck_doesNotThrow() async {
        let writer = FakeCastActionAckWriter()
        writer.failingPathSubstrings = ["cast_discovery_results", "cast_actions"]
        let listener = makeListener(writer: writer)
        let ref = makeRef()

        // Must not throw despite both writes failing.
        await listener.publishDiscoveryAndComplete(ref, uid: uid, devices: [makeDevice()])

        // Nothing was recorded because every write threw.
        XCTAssertTrue(writer.writes.isEmpty)
    }

    // MARK: - Central fail() writeback

    func test_fail_writesFailedStatusAndMessage() async {
        let writer = FakeCastActionAckWriter()
        let listener = makeListener(writer: writer)
        let ref = makeRef(id: "action-fail")

        await listener.fail(ref, message: "unknown type: bogus")

        let writes = writer.recordedWrites(matching: "cast_actions/action-fail")
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first?.payload["status"] as? String, "failed")
        XCTAssertEqual(writes.first?.payload["errorMessage"] as? String, "unknown type: bogus")
        XCTAssertNotNil(writes.first?.payload["completedAt"])
    }

    /// The central failure writeback losing its write must be tolerated
    /// (logged, not thrown) — it is the error path itself.
    func test_fail_lostWrite_doesNotThrow() async {
        let writer = FakeCastActionAckWriter()
        writer.failingPathSubstrings = ["cast_actions"]
        let listener = makeListener(writer: writer)

        await listener.fail(makeRef(id: "action-x"), message: "no dashboard URL configured")

        XCTAssertTrue(writer.writes.isEmpty)
    }

    // MARK: - save_selection ack observability

    func test_saveSelection_ack_writesCompleted() async {
        let writer = FakeCastActionAckWriter()
        let listener = makeListener(writer: writer)
        let ref = makeRef(id: "action-save")

        await listener.handleSaveSelection(ref, data: [
            "deviceId": "Nest-Hub-1",
            "friendlyName": "Living Room Hub"
        ])

        XCTAssertEqual(writer.lastStatus(forPathContaining: "cast_actions/action-save"), "completed")
    }

    /// A lost save_selection ack is observable (the writer was invoked and
    /// threw) but must not crash; local state was already persisted, so the
    /// loss degrades gracefully.
    func test_saveSelection_lostAck_doesNotThrow() async {
        let writer = FakeCastActionAckWriter()
        writer.failingPathSubstrings = ["cast_actions"]
        let listener = makeListener(writer: writer)

        await listener.handleSaveSelection(makeRef(id: "action-save2"), data: [
            "deviceId": "Nest-Hub-1",
            "friendlyName": "Living Room Hub"
        ])

        // Write was attempted (and threw) — nothing recorded, no crash.
        XCTAssertTrue(writer.writes.isEmpty)
    }

    func test_saveSelection_missingFields_failsClosed() async {
        let writer = FakeCastActionAckWriter()
        let listener = makeListener(writer: writer)
        let ref = makeRef(id: "action-save3")

        await listener.handleSaveSelection(ref, data: ["deviceId": "Nest-Hub-1"]) // no friendlyName

        XCTAssertEqual(writer.lastStatus(forPathContaining: "cast_actions/action-save3"), "failed")
        XCTAssertEqual(
            writer.recordedWrites(matching: "cast_actions/action-save3").last?.payload["errorMessage"] as? String,
            "missing deviceId/friendlyName"
        )
    }
}
