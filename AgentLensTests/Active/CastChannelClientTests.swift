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

    func testCastProbeAndWatchdogCleanupDoesNotStopReceiverApp() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let bridgeSource = try String(contentsOf: repoRoot.appendingPathComponent("AgentLens/Services/SmartHub/SmartHubBridgeController.swift"))
        XCTAssertFalse(bridgeSource.contains("await probeClient.stop()"))
        XCTAssertFalse(bridgeSource.contains("await refreshClient.stop()"))
        XCTAssertFalse(bridgeSource.contains("await kickClient.stop()"))
        XCTAssertFalse(bridgeSource.contains("await recastClient.stop()"))

        let strategySource = try String(contentsOf: repoRoot.appendingPathComponent("AgentLens/Services/Cast/CastReconnectStrategy.swift"))
        XCTAssertTrue(strategySource.contains("client.disconnect()"))
    }
}
