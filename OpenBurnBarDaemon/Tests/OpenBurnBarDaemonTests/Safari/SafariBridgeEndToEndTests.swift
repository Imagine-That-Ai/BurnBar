import XCTest
import OpenBurnBarEngine
@testable import OpenBurnBarDaemon

/// End-to-end proof that the Safari native bridge round-trips.
///
/// Every other Safari test stubs one side. This one wires the real pieces
/// together in one process:
///
///   web-extension JSON envelope
///     -> `BurnBarSafariNativeBridgeController` (the exact class the appex's
///        `SafariWebExtensionHandler` calls)
///     -> `BurnBarSafariDaemonSocketClient` over a real AF_UNIX socket
///     -> a real `BurnBarDaemonServer` and its `daemon.safari.*` handlers
///     -> back out as a `bridge.*` response envelope
///
/// The request envelopes are byte-shaped exactly as `extensions/safari/dist/
/// background.js` emits them, and the responses are asserted against the strict
/// schema that the same file's parsers enforce (unknown keys are rejected there,
/// so an extra field here would be a runtime break, not a warning).
final class SafariBridgeEndToEndTests: XCTestCase {
    private static let authToken = "safari-bridge-e2e-token"

    func testBridgeHelloPollAndBootstrapRoundTripThroughARealDaemon() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-safari-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let socketPath = "/tmp/obb-safari-e2e-\(String(UUID().uuidString.prefix(8))).sock"
        let server = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketPath: socketPath,
                socketAuthToken: Self.authToken,
                daemonVersion: "safari-bridge-e2e",
                startsMissionControlBackgroundLoops: false
            )
        )
        try await server.start()
        addTeardownBlock { await server.stop() }

        // The appex reads its daemon credential from the App Group container.
        let tokenFileURL = root.appendingPathComponent("daemon-socket-auth-token")
        try Self.authToken.write(to: tokenFileURL, atomically: true, encoding: .utf8)
        // The resolver refuses anything the owner does not exclusively control.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: tokenFileURL.path
        )

        let controller = BurnBarSafariNativeBridgeController(
            daemon: .live(
                socketClient: BurnBarSafariDaemonSocketClient(
                    socketURL: URL(fileURLWithPath: socketPath),
                    tokenResolver: .live(tokenFileURL: tokenFileURL)
                ),
                payloadStore: BurnBarSafariAppGroupPayloadStore(trustedRoot: root)
            ),
            chunkStore: BurnBarSafariBridgeChunkStore(
                trustedRoot: root,
                profileIdentifier: "safari-bridge-e2e"
            )
        )

        // 1. bridge.hello — exactly what background.js sends on startup.
        let hello = try Self.asObject(controller.handle(propertyList: [
            "protocolVersion": 1,
            "id": "e2e-hello",
            "method": "bridge.hello",
            "params": [
                "extensionInstanceId": "e2e-extension-instance",
                "clientName": "OpenBurnBar Safari WebExtension/1.0.0",
                "supportedProtocolVersions": [1],
                "capabilities": [
                    "captureVisibleTab": true,
                    "scripting": true,
                    "nativeMessaging": true,
                    "activeTabPermission": true,
                    "siteAccessGranted": true
                ]
            ]
        ]))
        let helloResult = try Self.requireResult(hello, id: "e2e-hello")
        XCTAssertEqual(
            Set(helloResult.keys),
            ["sessionId", "protocolVersion", "leaseExpiresAt", "pollAfterMillis"],
            "bridge.hello result must match background.js's exact key set — its parser rejects unknown keys."
        )
        let sessionID = try XCTUnwrap(helloResult["sessionId"] as? String)
        XCTAssertFalse(sessionID.isEmpty)
        XCTAssertEqual(helloResult["protocolVersion"] as? Int, 1)
        let lease = try XCTUnwrap(helloResult["leaseExpiresAt"] as? String)
        XCTAssertNotNil(ISO8601DateFormatter().date(from: lease) ?? Self.fractionalDate(lease))
        XCTAssertGreaterThan(try XCTUnwrap(helloResult["pollAfterMillis"] as? Int), 0)

        // 2. bridge.poll — the drain loop. No command is queued, so the daemon
        //    must answer with a lease renewal and no `command` key.
        let poll = try Self.asObject(controller.handle(propertyList: [
            "protocolVersion": 1,
            "id": "e2e-poll",
            "method": "bridge.poll",
            "params": ["sessionId": sessionID, "knownTabs": []]
        ]))
        let pollResult = try Self.requireResult(poll, id: "e2e-poll")
        XCTAssertTrue(
            Set(pollResult.keys).isSubset(of: ["command", "leaseExpiresAt", "pollAfterMillis"]),
            "bridge.poll result carried unexpected keys: \(Set(pollResult.keys))"
        )
        XCTAssertNotNil(pollResult["leaseExpiresAt"])
        XCTAssertNotNil(pollResult["pollAfterMillis"])

        // 3. bridge.popupAction/bootstrap — the gateway handshake. Its key set is
        //    pinned because `parseSafariBootstrapResponse` also rejects unknowns.
        let bootstrap = try Self.asObject(controller.handle(propertyList: [
            "protocolVersion": 1,
            "id": "e2e-bootstrap",
            "method": "bridge.popupAction",
            "params": [
                "sessionId": sessionID,
                "action": "bootstrap",
                "payload": ["safariSessionId": sessionID]
            ]
        ]))
        let bootstrapResult = try Self.requireResult(bootstrap, id: "e2e-bootstrap")
        XCTAssertEqual(bootstrapResult["accepted"] as? Bool, true)
        let output = try XCTUnwrap(bootstrapResult["output"] as? [String: Any])
        let allowed: Set<String> = [
            "daemonVersion", "protocolVersion", "gatewayBaseURL", "gatewayBearerToken",
            "gatewayAvailable", "computerUseAvailable", "learningAvailable",
            "learningOptedIn", "tier"
        ]
        XCTAssertTrue(
            Set(output.keys).isSubset(of: allowed),
            "safari.bootstrap emitted keys the shipped dist rejects: \(Set(output.keys).subtracting(allowed))"
        )
        XCTAssertEqual(output["daemonVersion"] as? String, "safari-bridge-e2e")
        XCTAssertEqual(output["protocolVersion"] as? Int, 1)

        // Capture the real wire bytes so the JS-side contract check can replay them.
        let evidence: [String: Any] = [
            "bridge.hello": hello,
            "bridge.poll": poll,
            "bridge.popupAction/bootstrap": bootstrap
        ]
        let evidenceURL = URL(fileURLWithPath: "/tmp/safari-bridge-e2e-evidence.json")
        try JSONSerialization
            .data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
            .write(to: evidenceURL)
        print("SAFARI_BRIDGE_EVIDENCE=\(evidenceURL.path)")
    }

    private static func asObject(_ value: Any) throws -> [String: Any] {
        guard let object = value as? [String: Any] else {
            XCTFail("Bridge response was not a JSON object.")
            throw BridgeEvidenceError.missingResult
        }
        return object
    }

    /// Rejects an error envelope loudly — a bridge that answers
    /// `native_bridge_unavailable` must fail this test, not silently pass.
    private static func requireResult(
        _ response: [String: Any],
        id: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String: Any] {
        XCTAssertEqual(response["protocolVersion"] as? Int, 1, file: file, line: line)
        XCTAssertEqual(response["id"] as? String, id, file: file, line: line)
        if let error = response["error"] as? [String: Any] {
            XCTFail(
                "Bridge returned an error envelope: \(error["code"] ?? "?") — \(error["message"] ?? "?")",
                file: file, line: line
            )
            throw BridgeEvidenceError.errorEnvelope
        }
        guard let result = response["result"] as? [String: Any] else {
            XCTFail("Bridge response carried no result object.", file: file, line: line)
            throw BridgeEvidenceError.missingResult
        }
        return result
    }

    private static func fractionalDate(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw)
    }

    private enum BridgeEvidenceError: Error {
        case errorEnvelope
        case missingResult
    }
}
