import XCTest
@testable import OpenBurnBar

@MainActor
final class CastChannelClientTests: XCTestCase {

    func testDashCastConstants_matchPychromecastController() {
        XCTAssertEqual(CastChannelClient.dashCastAppId, "84912283")
        XCTAssertEqual(CastChannelClient.nsDashCast, "urn:x-cast:com.madmod.dashcast")
    }

    func testDashCastLoadPayload_matchesPychromecastShape() throws {
        let url = try XCTUnwrap(URL(string: "http://192.168.68.87:8787/render.html"))
        let payload = CastChannelClient.dashCastLoadPayload(
            url: url,
            sessionId: "session-1",
            reloadSeconds: 60
        )

        XCTAssertEqual(payload["url"] as? String, url.absoluteString)
        XCTAssertEqual(payload["force"] as? Bool, false)
        XCTAssertEqual(payload["reload"] as? Bool, true)
        XCTAssertEqual(payload["reload_time"] as? Double, 60_000)
        XCTAssertEqual(payload["sessionId"] as? String, "session-1")
        XCTAssertNil(payload["force_reload"])
    }

    func testDashCastLoadPayload_omitsBlankSessionId() throws {
        let url = try XCTUnwrap(URL(string: "http://example.local/render.html"))
        let payload = CastChannelClient.dashCastLoadPayload(
            url: url,
            sessionId: "",
            reloadSeconds: 0
        )

        XCTAssertNil(payload["sessionId"])
        XCTAssertEqual(payload["reload"] as? Bool, false)
        XCTAssertEqual(payload["reload_time"] as? Int, 0)
    }

    func testDashCastLoadPayload_disablesReloadWhenForceLoading() throws {
        let url = try XCTUnwrap(URL(string: "http://192.168.68.87:8787/render.html"))
        let payload = CastChannelClient.dashCastLoadPayload(
            url: url,
            sessionId: "session-1",
            reloadSeconds: 60,
            force: true
        )

        XCTAssertEqual(payload["url"] as? String, url.absoluteString)
        XCTAssertEqual(payload["force"] as? Bool, true)
        XCTAssertEqual(payload["reload"] as? Bool, false)
        XCTAssertEqual(payload["reload_time"] as? Int, 0)
        XCTAssertEqual(payload["sessionId"] as? String, "session-1")
    }

    /// Regression: when `reloadSeconds` is 0 the payload must disable
    /// DashCast's periodic reload entirely. We rely on this in the
    /// runtime LOAD path so the Nest Hub does not auto-navigate every
    /// minute on top of the page's own `/state.json` polling, which
    /// previously caused the "Hub displays OpenBurnBar briefly, blanks,
    /// re-displays" reset cycle.
    func testDashCastLoadPayload_disablesReloadWhenSecondsIsZero() throws {
        let url = try XCTUnwrap(URL(string: "http://192.168.68.87:8787/render.html"))
        let payload = CastChannelClient.dashCastLoadPayload(
            url: url,
            sessionId: "session-1",
            reloadSeconds: 0,
            force: false
        )

        XCTAssertEqual(payload["force"] as? Bool, false)
        XCTAssertEqual(payload["reload"] as? Bool, false)
        XCTAssertEqual(payload["reload_time"] as? Int, 0)
    }

    func testNonDestructiveCastCleanupDisconnectsWithoutStoppingReceiver() {
        let client = CastReceiverClientLifecycleSpy()

        CastReceiverClientCleanup.disconnectOnly(client)

        XCTAssertEqual(client.disconnectCount, 1)
        XCTAssertEqual(client.stopCount, 0)
    }

    // MARK: - serializedPayload (control-channel send observability)

    /// A well-formed Cast control payload round-trips to the exact UTF-8 JSON
    /// the wire format expects. This is the happy path that `sendVirtual`
    /// relies on for every CONNECT / LAUNCH / LOAD / PING / GET_STATUS frame.
    func testSerializedPayload_encodesWellFormedPayload() throws {
        let utf8 = try XCTUnwrap(
            CastChannelClient.serializedPayload(
                ["type": "CONNECT", "userAgent": "OpenBurnBar/1.0"],
                namespace: CastChannelClient.nsConnection
            )
        )

        let data = try XCTUnwrap(utf8.data(using: .utf8))
        let decoded = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(decoded["type"] as? String, "CONNECT")
        XCTAssertEqual(decoded["userAgent"] as? String, "OpenBurnBar/1.0")
    }

    /// Regression for the silently-swallowed `try?` at the JSON-serialization
    /// site: a payload carrying a value JSON cannot represent (`Double.infinity`,
    /// rejected by `JSONSerialization`) must fail the encode and return `nil`
    /// so `sendVirtual` skips the send. Returning the original (drop) behavior
    /// is intentional; the fix is that the failure is now logged rather than
    /// surfacing only as a downstream request timeout. We assert the contract
    /// callers depend on: no frame string is produced for an unencodable payload.
    func testSerializedPayload_returnsNilForUnserializablePayload() {
        let unserializable: [String: Any] = [
            "type": "LOAD",
            "reload_time": Double.infinity
        ]

        XCTAssertNil(
            CastChannelClient.serializedPayload(
                unserializable,
                namespace: CastChannelClient.nsDashCast
            ),
            "An unserializable payload must not yield a wire frame"
        )
    }

    /// NaN is likewise not representable in JSON; the helper must reject it
    /// rather than emit a malformed / silently-dropped frame.
    func testSerializedPayload_returnsNilForNaNValue() {
        let unserializable: [String: Any] = [
            "type": "LOAD",
            "reload_time": Double.nan
        ]

        XCTAssertNil(
            CastChannelClient.serializedPayload(
                unserializable,
                namespace: CastChannelClient.nsDashCast
            )
        )
    }
}

@MainActor
private final class CastReceiverClientLifecycleSpy: CastReceiverClientLifecycle {
    private(set) var stopCount = 0
    private(set) var disconnectCount = 0

    func stop() async {
        stopCount += 1
    }

    func disconnect() {
        disconnectCount += 1
    }
}
