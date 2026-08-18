import XCTest
@testable import OpenBurnBarCore

/// Shared Hermes / Mercury / Computer Use vectors. Source: iOS cancel + MercuryPeer.
final class MobileHermesMercuryComputerUseParityTests: XCTestCase {
    func testHermesStopMidStream() throws {
        let vector = try hermesVector("hermes.stop-mid-stream")
        assertStreamTerminal(vector)
    }

    func testHermesCancelVsError() throws {
        let vector = try hermesVector("hermes.cancel-vs-error")
        let cancel = MobileHermesConversationPolicy.terminal(forEvent: string(vector["event"]))
        let error = MobileHermesConversationPolicy.terminal(forEvent: string(vector["compareEvent"]))
        let expected = dict(vector["expected"])
        XCTAssertEqual(cancel.rawValue, string(expected["terminal"]))
        XCTAssertTrue(MobileHermesConversationPolicy.keepsPartial(cancel))
        XCTAssertFalse(MobileHermesConversationPolicy.marksError(cancel))
        XCTAssertEqual(error.rawValue, string(expected["compareTerminal"]))
        XCTAssertEqual(MobileHermesConversationPolicy.marksError(error), bool(expected["compareIsError"]))
        XCTAssertEqual(MobileHermesConversationPolicy.keepsPartial(error), bool(expected["compareKeepPartial"]))
        XCTAssertNotEqual(cancel, error)
    }

    func testHermesPartialResultKept() throws {
        assertStreamTerminal(try hermesVector("hermes.partial-result-kept"))
    }

    func testHermesReconnectNoDuplicateUser() throws {
        let vector = try hermesVector("hermes.reconnect-no-duplicate-user")
        XCTAssertEqual(
            MobileHermesConversationPolicy.shouldAppendUserMessage(
                lastRole: vector["lastRole"] as? String,
                lastText: vector["lastText"] as? String,
                incomingText: string(vector["incomingText"]),
                reason: string(vector["reason"])
            ),
            bool(dict(vector["expected"])["appendUser"])
        )
    }

    func testHermesToolCallAfterStop() throws {
        let vector = try hermesVector("hermes.tool-call-after-stop")
        let terminal = MobileHermesConversationPolicy.terminal(forEvent: string(vector["event"]))
        let expected = dict(vector["expected"])
        XCTAssertEqual(terminal.rawValue, string(expected["terminal"]))
        XCTAssertTrue(
            MobileHermesConversationPolicy.shouldRenderToolCalls(
                toolCallCount: int(vector["toolCallCount"]),
                terminal: terminal
            )
        )
        XCTAssertFalse(
            MobileHermesConversationPolicy.shouldDropEmptyAssistant(
                text: string(vector["text"]),
                toolCallCount: int(vector["toolCallCount"]),
                isError: bool(vector["isError"]),
                terminal: terminal
            )
        )
    }

    func testHermesAttachmentMalformedRejected() throws {
        let vector = try hermesVector("hermes.attachment-malformed-rejected")
        XCTAssertEqual(
            MobileHermesConversationPolicy.attachmentDisposition(
                id: string(vector["attachmentId"]),
                mimeType: string(vector["mimeType"]),
                byteSize: int(vector["byteSize"]),
                path: string(vector["path"])
            ).rawValue,
            string(dict(vector["expected"])["disposition"])
        )
    }

    func testHermesDeepLinkMissingConversation() throws {
        let vector = try hermesVector("hermes.deep-link-missing-conversation")
        let outcome = MobileHermesConversationPolicy.conversationDeepLink(
            threadId: string(vector["threadId"]),
            exists: bool(vector["exists"])
        )
        XCTAssertEqual(outcome.rawValue, string(dict(vector["expected"])["outcome"]))
        XCTAssertEqual(
            MobileHermesConversationPolicy.missingConversationMessage(outcome),
            string(dict(vector["expected"])["message"])
        )
    }

    func testHermesThreadIsolationLateChunk() throws {
        let vector = try hermesVector("hermes.thread-isolation-late-chunk")
        XCTAssertFalse(
            MobileHermesConversationPolicy.shouldApplyChunk(
                chunkThreadId: vector["chunkThreadId"] as? String,
                activeThreadId: vector["activeThreadId"] as? String,
                chunkGeneration: int(vector["chunkGeneration"]),
                activeGeneration: int(vector["activeGeneration"])
            )
        )
    }

    func testMercuryHeartbeatInterval60s() throws {
        let vector = try hermesVector("mercury.heartbeat-interval-60s")
        XCTAssertEqual(MobileMercuryMediaPolicy.heartbeatIntervalMs, int64(dict(vector["expected"])["intervalMs"]))
    }

    func testMercuryUnknownCapabilityFiltered() throws {
        let vector = try hermesVector("mercury.unknown-capability-filtered")
        XCTAssertEqual(
            MobileMercuryMediaPolicy.filterCapabilities(strings(vector["raw"])),
            strings(dict(vector["expected"])["capabilities"])
        )
    }

    func testMercuryInviteAckPairing() throws {
        let vector = try hermesVector("mercury.invite-ack-pairing")
        XCTAssertEqual(
            MobileMercuryMediaPolicy.inviteAckPair(
                inviteId: string(vector["inviteId"]),
                ackId: string(vector["ackId"]),
                accepted: bool(vector["accepted"])
            ).rawValue,
            string(dict(vector["expected"])["pair"])
        )
    }

    func testMercuryDenialNotConnected() throws {
        let vector = try hermesVector("mercury.denial-not-connected")
        XCTAssertEqual(
            MobileMercuryMediaPolicy.sessionPresentation(
                phase: string(vector["phase"]),
                denied: bool(vector["denied"])
            ).rawValue,
            string(dict(vector["expected"])["presentation"])
        )
        XCTAssertNotEqual(
            MobileMercuryMediaPolicy.sessionPresentation(phase: "live", denied: true),
            .connected
        )
    }

    func testMercuryReconnect() throws {
        let vector = try hermesVector("mercury.reconnect")
        XCTAssertEqual(
            MobileMercuryMediaPolicy.sessionPresentation(
                phase: string(vector["phase"]),
                denied: bool(vector["denied"])
            ).rawValue,
            string(dict(vector["expected"])["presentation"])
        )
    }

    func testComputerUseReplayRejected() throws {
        assertSafety(try hermesVector("computeruse.replay-rejected"))
    }

    func testComputerUseTamperRejected() throws {
        assertSafety(try hermesVector("computeruse.tamper-rejected"))
    }

    func testComputerUseExpiredGrantRejected() throws {
        assertSafety(try hermesVector("computeruse.expired-grant-rejected"))
    }

    func testComputerUseUnauthenticatedSenderRejected() throws {
        assertSafety(try hermesVector("computeruse.unauthenticated-sender-rejected"))
    }

    func testComputerUseBindingMismatchRejected() throws {
        assertSafety(try hermesVector("computeruse.binding-mismatch-rejected"))
    }

    private func assertStreamTerminal(_ vector: [String: Any]) {
        let terminal = MobileHermesConversationPolicy.terminal(forEvent: string(vector["event"]))
        let expected = dict(vector["expected"])
        XCTAssertEqual(terminal.rawValue, string(expected["terminal"]))
        XCTAssertEqual(MobileHermesConversationPolicy.keepsPartial(terminal), bool(expected["keepPartial"]))
        XCTAssertEqual(MobileHermesConversationPolicy.marksError(terminal), bool(expected["isError"]))
        if expected["dropEmptyAssistant"] != nil {
            XCTAssertEqual(
                MobileHermesConversationPolicy.shouldDropEmptyAssistant(
                    text: string(vector["text"]),
                    toolCallCount: int(vector["toolCallCount"]),
                    isError: bool(vector["isError"]),
                    terminal: terminal
                ),
                bool(expected["dropEmptyAssistant"])
            )
        }
    }

    private func assertSafety(_ vector: [String: Any]) {
        let expected = dict(vector["expected"])
        let decision = MobileComputerUseSafetyPolicy.decision(
            kind: string(vector["decisionKind"]),
            authenticated: vector["authenticated"] as? Bool ?? true,
            grantExpired: bool(vector["grantExpired"]),
            bindingMatches: vector["bindingMatches"] as? Bool ?? true,
            replayed: bool(vector["replayed"]),
            tampered: bool(vector["tampered"])
        )
        XCTAssertEqual(decision.rawValue, string(expected["decision"]))
        XCTAssertEqual(
            MobileComputerUseSafetyPolicy.reason(
                kind: string(vector["decisionKind"]),
                authenticated: vector["authenticated"] as? Bool ?? true,
                grantExpired: bool(vector["grantExpired"]),
                bindingMatches: vector["bindingMatches"] as? Bool ?? true,
                replayed: bool(vector["replayed"]),
                tampered: bool(vector["tampered"])
            ),
            string(expected["reason"])
        )
    }

    func testSafetyRejectsPanicSessionExpiryRateLimitAndViewOnly() {
        XCTAssertEqual(
            MobileComputerUseSafetyPolicy.decision(kind: "valid-control", panic: true),
            .reject
        )
        XCTAssertEqual(
            MobileComputerUseSafetyPolicy.reason(kind: "valid-control", panic: true),
            "panic"
        )
        XCTAssertEqual(
            MobileComputerUseSafetyPolicy.decision(kind: "valid-control", sessionExpired: true),
            .reject
        )
        XCTAssertEqual(
            MobileComputerUseSafetyPolicy.reason(kind: "valid-control", sessionExpired: true),
            "session-expiry"
        )
        XCTAssertEqual(
            MobileComputerUseSafetyPolicy.decision(kind: "valid-control", rateLimited: true),
            .reject
        )
        XCTAssertEqual(
            MobileComputerUseSafetyPolicy.reason(kind: "valid-control", rateLimited: true),
            "rate-limit"
        )
        XCTAssertEqual(
            MobileComputerUseSafetyPolicy.decision(kind: "valid-control", viewOnly: true, intentKind: "tap"),
            .reject
        )
        XCTAssertEqual(
            MobileComputerUseSafetyPolicy.reason(kind: "valid-control", viewOnly: true, intentKind: "tap"),
            "view-only"
        )
        XCTAssertEqual(
            MobileComputerUseSafetyPolicy.decision(kind: "valid-control", viewOnly: true, intentKind: "panic"),
            .allow
        )
        XCTAssertEqual(
            MobileComputerUseSafetyPolicy.reason(kind: "valid-control", viewOnly: true, intentKind: "panic"),
            "ok"
        )
        XCTAssertEqual(MobileComputerUseSafetyPolicy.decision(kind: "unknown-kind"), .reject)
        XCTAssertEqual(MobileComputerUseSafetyPolicy.reason(kind: "unknown-kind"), "unknown-kind")
        XCTAssertTrue(
            MobileComputerUseSafetyPolicy.shouldSendPhoneControl(
                authenticated: true,
                grantExpired: false,
                bindingMatches: true,
                replayed: false,
                tampered: false,
                rateLimited: false,
                sessionExpired: false,
                panic: false,
                viewOnly: false,
                intentKind: "tap"
            )
        )
        XCTAssertFalse(
            MobileComputerUseSafetyPolicy.shouldSendPhoneControl(
                authenticated: true,
                grantExpired: false,
                bindingMatches: true,
                replayed: false,
                tampered: false,
                rateLimited: true,
                sessionExpired: false,
                panic: false,
                viewOnly: false,
                intentKind: "tap"
            )
        )
    }

    private func hermesVector(_ id: String) throws -> [String: Any] {
        try vector(id, in: "docs/mobile-parity/fixtures/product/hermes-mercury-computer-use-vectors.json")
    }

    private func vector(_ id: String, in relative: String) throws -> [String: Any] {
        let root = repoRoot()
        let url = root.appendingPathComponent(relative)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let vectors = json?["vectors"] as? [[String: Any]] ?? []
        return try XCTUnwrap(vectors.first { $0["id"] as? String == id }, "missing vector \(id)")
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func dict(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }
    private func strings(_ value: Any?) -> [String] { (value as? [String]) ?? [] }
    private func string(_ value: Any?) -> String { value as? String ?? "" }
    private func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }
    private func int64(_ value: Any?) -> Int64 { (value as? NSNumber)?.int64Value ?? 0 }
    private func bool(_ value: Any?) -> Bool { value as? Bool ?? false }
}
