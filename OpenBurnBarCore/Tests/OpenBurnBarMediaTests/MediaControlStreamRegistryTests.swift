import XCTest
@testable import OpenBurnBarCore
@testable import OpenBurnBarIrohRelay
@testable import OpenBurnBarMedia

/// Verifies the Risk-1 control-stream registry behaves correctly under
/// the contract `MacFileTransferService` relies on:
/// register-replaces-stale, invalidate-removes, latest-stream-by-time,
/// await-blocks-until-register, and idempotent close on the displaced
/// stream when a re-register happens.
final class MediaControlStreamRegistryTests: XCTestCase {
    func testRegisterAndLookupByConnection() async {
        let registry = MediaControlStreamRegistry()
        let stream = RecordingStream()
        await registry.register(stream: stream, uid: "u", connectionID: "c1")
        let fetched = await registry.stream(uid: "u", connectionID: "c1")
        XCTAssertNotNil(fetched)
        let count = await registry.activeStreamCount()
        XCTAssertEqual(count, 1)
    }

    func testInvalidateRemoves() async {
        let registry = MediaControlStreamRegistry()
        let stream = RecordingStream()
        await registry.register(stream: stream, uid: "u", connectionID: "c1")
        await registry.invalidate(uid: "u", connectionID: "c1")
        let activeAfterInvalidate = await registry.activeStreamCount()
        XCTAssertEqual(activeAfterInvalidate, 0)
        // Close should propagate to the displaced stream so we never
        // leak QUIC half-streams.
        try? await Task.sleep(nanoseconds: 50_000_000)
        let closedCount = await stream.closedCount()
        XCTAssertGreaterThanOrEqual(closedCount, 1)
    }

    func testReRegisterClosesPriorStream() async {
        let registry = MediaControlStreamRegistry()
        let oldStream = RecordingStream()
        let newStream = RecordingStream()
        await registry.register(stream: oldStream, uid: "u", connectionID: "c1")
        await registry.register(stream: newStream, uid: "u", connectionID: "c1")
        try? await Task.sleep(nanoseconds: 50_000_000)
        let oldClosed = await oldStream.closedCount()
        let newClosed = await newStream.closedCount()
        XCTAssertGreaterThanOrEqual(oldClosed, 1)
        XCTAssertEqual(newClosed, 0)
    }

    func testLatestStreamPicksMostRecent() async {
        let registry = MediaControlStreamRegistry()
        let first = RecordingStream()
        let second = RecordingStream()
        await registry.register(stream: first, uid: "u", connectionID: "c1")
        try? await Task.sleep(nanoseconds: 10_000_000)
        await registry.register(stream: second, uid: "u", connectionID: "c2")
        let latest = await registry.latestStream(uid: "u")
        XCTAssertEqual(latest?.key.connectionID, "c2")
    }

    func testAwaitStreamReturnsImmediatelyWhenRegistered() async {
        let registry = MediaControlStreamRegistry()
        let stream = RecordingStream()
        await registry.register(stream: stream, uid: "u", connectionID: "c1")
        let resolved = await registry.awaitStream(uid: "u", timeout: 0.5)
        XCTAssertNotNil(resolved)
    }

    func testAwaitStreamTimesOutWhenNothingRegistered() async {
        let registry = MediaControlStreamRegistry(pollIntervalNanoseconds: 20_000_000)
        let started = Date()
        let resolved = await registry.awaitStream(uid: "u", timeout: 0.3)
        XCTAssertNil(resolved)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.25)
    }

    func testAwaitStreamResolvesAfterDelayedRegister() async {
        let registry = MediaControlStreamRegistry(pollIntervalNanoseconds: 20_000_000)
        let stream = RecordingStream()
        async let resolved = registry.awaitStream(uid: "u", timeout: 2.0)
        // Simulate iOS finishing its dial 150 ms after Mac starts
        // waiting.
        try? await Task.sleep(nanoseconds: 150_000_000)
        await registry.register(stream: stream, uid: "u", connectionID: "c-late")
        let observed = await resolved
        XCTAssertNotNil(observed)
    }

    func testAwaitStreamIgnoresOtherUid() async {
        let registry = MediaControlStreamRegistry(pollIntervalNanoseconds: 20_000_000)
        let stream = RecordingStream()
        await registry.register(stream: stream, uid: "other", connectionID: "c1")
        let resolved = await registry.awaitStream(uid: "u", timeout: 0.2)
        XCTAssertNil(resolved)
    }
}

/// Test-only `IrohRelayStream` implementation that records every
/// `send` / `close` so tests can assert lifecycle ordering without a
/// real iroh endpoint.
private actor StreamLedger {
    var sent: [HermesRealtimeRelayFrame] = []
    var closed: Int = 0

    func recordSent(_ frame: HermesRealtimeRelayFrame) { sent.append(frame) }
    func recordClose() { closed += 1 }
    func snapshotSent() -> [HermesRealtimeRelayFrame] { sent }
    func snapshotClosed() -> Int { closed }
}

private final class RecordingStream: IrohRelayStream, @unchecked Sendable {
    private let ledger = StreamLedger()

    func send(_ frame: HermesRealtimeRelayFrame) async throws {
        await ledger.recordSent(frame)
    }

    func receive() async throws -> HermesRealtimeRelayFrame? {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        return nil
    }

    func close() async {
        await ledger.recordClose()
    }

    func closedCount() async -> Int {
        await ledger.snapshotClosed()
    }

    func sentFrames() async -> [HermesRealtimeRelayFrame] {
        await ledger.snapshotSent()
    }
}
