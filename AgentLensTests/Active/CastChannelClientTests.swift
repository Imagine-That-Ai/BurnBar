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
}
