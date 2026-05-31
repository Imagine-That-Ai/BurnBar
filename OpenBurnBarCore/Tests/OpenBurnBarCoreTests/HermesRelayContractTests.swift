import XCTest
@testable import OpenBurnBarCore

final class HermesRelayContractTests: XCTestCase {
    func testRelayRequestRecordCodableRoundTrip() throws {
        let now = Date(timeIntervalSince1970: 1_714_200_000)
        let record = HermesRelayRequestRecord(
            id: "relay-request-1",
            connectionId: "relay-mac",
            operation: .chatCompletions,
            status: .streaming,
            method: "POST",
            payloadCiphertext: "ciphertext",
            wrappedKey: "wrapped-key",
            relayEncryption: HermesRelayCrypto.algorithm,
            relayKeyVersion: HermesRelayCrypto.keyVersion,
            chunkCount: 2,
            createdAt: now,
            updatedAt: now,
            expiresAt: now.addingTimeInterval(90)
        )

        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(HermesRelayRequestRecord.self, from: data)

        XCTAssertEqual(decoded, record)
        XCTAssertEqual(decoded.operation.rawValue, "chatCompletions")
        XCTAssertEqual(decoded.status.rawValue, "streaming")
    }

    func testRelayChunkRecordCodableRoundTrip() throws {
        let record = HermesRelayChunkRecord(
            id: "00000001",
            requestId: "relay-request-1",
            sequence: 1,
            kind: .sse,
            ciphertext: "ciphertext"
        )

        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(HermesRelayChunkRecord.self, from: data)

        XCTAssertEqual(decoded, record)
        XCTAssertEqual(decoded.kind.rawValue, "sse")
    }

    func testCLIAgentChatRelayRequestAndEventRoundTrip() throws {
        let request = CLIAgentRelayChatRequest(
            runtime: "codex",
            prompt: "Hello from iPhone",
            clientThreadID: "mobile-codex-123",
            modelID: "gpt-test",
            title: "Hello",
            parentSessionID: nil,
            resumeAction: "continue"
        )
        let requestData = try JSONEncoder().encode(request)
        let decodedRequest = try JSONDecoder().decode(CLIAgentRelayChatRequest.self, from: requestData)

        XCTAssertEqual(decodedRequest, request)
        XCTAssertEqual(HermesRelayOperation(rawValue: "cliAgentChat"), .cliAgentChat)
        XCTAssertEqual(HermesRelayOperation(rawValue: "cliAgentModelCatalog"), .cliAgentModelCatalog)
        XCTAssertEqual(HermesRelayOperation(rawValue: "cliAgentSessionAction"), .cliAgentSessionAction)

        let event = CLIAgentRelayChatEvent(
            kind: .completed,
            text: "Mac Codex answered.",
            modelID: "gpt-test",
            transcriptPieces: [
                CLIAgentRelayTranscriptPiece(id: "p1", kind: .text, value: "Mac Codex answered."),
                CLIAgentRelayTranscriptPiece(id: "p2", kind: .toolUse, value: "Read", detail: "File.swift")
            ]
        )
        let eventData = try JSONEncoder().encode(event)
        let decodedEvent = try JSONDecoder().decode(CLIAgentRelayChatEvent.self, from: eventData)

        XCTAssertEqual(decodedEvent, event)
        XCTAssertTrue(decodedEvent.isTerminal)
        XCTAssertFalse(decodedEvent.isError)
    }

    func testCLIAgentSessionActionRoundTrip() throws {
        let request = CLIAgentSessionActionRequest(
            sessionID: "codex:session-123",
            action: .resume,
            targetRuntime: "grok",
            targetModelID: "grok-4",
            presentationMode: .macInteractiveCLI
        )
        let requestData = try JSONEncoder().encode(request)
        let decodedRequest = try JSONDecoder().decode(CLIAgentSessionActionRequest.self, from: requestData)
        XCTAssertEqual(decodedRequest, request)

        let response = CLIAgentSessionActionResponse(
            status: .handoff,
            targetRuntime: "grok",
            argv: ["grok", "--cwd", "/tmp/app", "--prompt-file", "/tmp/burnbar-resume.md"],
            briefingPath: "/tmp/burnbar-resume.md",
            workingDirectory: "/tmp/app",
            note: "native_handle_invalid_fell_back_to_handoff"
        )
        let responseData = try JSONEncoder().encode(response)
        let decodedResponse = try JSONDecoder().decode(CLIAgentSessionActionResponse.self, from: responseData)
        XCTAssertEqual(decodedResponse, response)
    }

    func testRelayCryptoRoundTripsRequestAndChunkPayloads() throws {
        let privateKey = HermesRelayCrypto.generatePrivateKey()
        let keyData = try HermesRelayCrypto.generateSymmetricKeyData()
        let uid = "user-1"
        let connectionID = "relay-mac"
        let requestID = "relay-request-1"
        let keyAAD = HermesRelayCrypto.keyAAD(uid: uid, connectionID: connectionID, requestID: requestID)
        let wrappedKey = try HermesRelayCrypto.wrapSymmetricKey(
            keyData,
            recipientPublicKeyBase64: privateKey.publicKeyBase64,
            aad: keyAAD
        )
        let unwrappedKey = try HermesRelayCrypto.unwrapSymmetricKey(
            wrappedKey,
            privateKey: privateKey,
            aad: keyAAD
        )
        XCTAssertEqual(unwrappedKey, keyData)

        let requestPayload = HermesRelayEncryptedRequestPayload(
            path: "/v1/chat/completions",
            sessionId: "session-☿",
            body: #"{"stream":true,"messages":[{"role":"user","content":"hi"}]}"#
        )
        let requestPlaintext = try JSONEncoder().encode(requestPayload)
        let requestCiphertext = try HermesRelayCrypto.sealToBase64(
            plaintext: requestPlaintext,
            keyData: keyData,
            aad: HermesRelayCrypto.requestAAD(uid: uid, connectionID: connectionID, requestID: requestID)
        )
        XCTAssertFalse(requestCiphertext.contains("messages"))

        let openedRequest = try HermesRelayCrypto.openBase64(
            ciphertext: requestCiphertext,
            keyData: unwrappedKey,
            aad: HermesRelayCrypto.requestAAD(uid: uid, connectionID: connectionID, requestID: requestID)
        )
        XCTAssertEqual(try JSONDecoder().decode(HermesRelayEncryptedRequestPayload.self, from: openedRequest), requestPayload)

        let chunkAAD = HermesRelayCrypto.chunkAAD(
            uid: uid,
            connectionID: connectionID,
            requestID: requestID,
            sequence: 0,
            kind: HermesRelayChunkKind.sse.rawValue
        )
        let chunkCiphertext = try HermesRelayCrypto.sealToBase64(
            plaintext: Data("data: hello ☿".utf8),
            keyData: keyData,
            aad: chunkAAD
        )
        let openedChunk = try HermesRelayCrypto.openBase64(
            ciphertext: chunkCiphertext,
            keyData: keyData,
            aad: chunkAAD
        )
        XCTAssertEqual(String(data: openedChunk, encoding: .utf8), "data: hello ☿")
    }

    // MARK: - Resume / handoff presentation contract

    func testResumeTargetCatalogMatchesLaunchBrief() {
        let targets = CLIAgentResumeTarget.allCases
        XCTAssertEqual(targets.count, 9)
        // Canonical wire ids must equal the daemon's `normalizeProvider`
        // output so `targetRuntime` round-trips unchanged.
        XCTAssertEqual(
            targets.map(\.wireID),
            ["claude_code", "codex", "droid", "forge", "antigravity", "grok", "cursor_agent", "opencode", "gemini"]
        )
        XCTAssertEqual(
            targets.map(\.displayName),
            ["Claude Code", "Codex", "Droid", "Forge", "Antigravity", "Grok", "Cursor Agent", "OpenCode", "Gemini CLI"]
        )
    }

    func testNativeResumeCapabilityMirrorsDaemonTable() {
        // Mirrors `BurnBarResumeService.providerSupport`: only Claude Code
        // and Codex resume natively; everything else is handoff-only.
        let native = CLIAgentResumeTarget.allCases.filter(\.supportsNativeResume).map(\.wireID)
        XCTAssertEqual(Set(native), ["claude_code", "codex"])
        for target in CLIAgentResumeTarget.allCases {
            XCTAssertEqual(target.capability, target.supportsNativeResume ? .native : .handoff)
        }
        XCTAssertTrue(cliAgentProviderSupportsNativeResume(canonicalWireID: "claude_code"))
        XCTAssertTrue(cliAgentProviderSupportsNativeResume(canonicalWireID: "codex"))
        XCTAssertFalse(cliAgentProviderSupportsNativeResume(canonicalWireID: "grok"))
        XCTAssertFalse(cliAgentProviderSupportsNativeResume(canonicalWireID: "opencode"))
        XCTAssertFalse(cliAgentProviderSupportsNativeResume(canonicalWireID: "gemini"))
    }

    func testRuntimeCanonicalProviderIDsAreDaemonCanonical() {
        let expected: [CLIAgentRuntime: String] = [
            .codex: "codex",
            .claude: "claude_code",
            .openClaw: "openclaw",
            .droid: "droid",
            .forge: "forge",
            .antigravity: "antigravity",
            .grok: "grok",
            .cursorAgent: "cursor_agent"
        ]
        for runtime in CLIAgentRuntime.allCases {
            XCTAssertEqual(runtime.canonicalProviderID, expected[runtime])
        }
        XCTAssertTrue(CLIAgentRuntime.claude.supportsNativeResume)
        XCTAssertTrue(CLIAgentRuntime.codex.supportsNativeResume)
        XCTAssertFalse(CLIAgentRuntime.openClaw.supportsNativeResume)
        XCTAssertFalse(CLIAgentRuntime.grok.supportsNativeResume)
        // openClaw has no first-class resume target (handoff only).
        XCTAssertNil(CLIAgentRuntime.openClaw.resumeTarget)
        XCTAssertEqual(CLIAgentRuntime.cursorAgent.resumeTarget, .cursorAgent)
    }

    func testSessionActionStatusPresentationCopy() {
        XCTAssertEqual(CLIAgentSessionActionStatus.nativeResume.presentation.title, "Native resume")
        XCTAssertEqual(CLIAgentSessionActionStatus.handoff.presentation.title, "Handoff package started")
        XCTAssertEqual(CLIAgentSessionActionStatus.packageOnly.presentation.title, "Package ready")
        XCTAssertEqual(CLIAgentSessionActionStatus.spawned.presentation.title, "Opened on Mac")
        XCTAssertEqual(CLIAgentSessionActionStatus.error.presentation.shortLabel, "Error")
        for status in CLIAgentSessionActionStatus.allCases {
            XCTAssertEqual(status.presentation.isSuccess, status != .error)
            XCTAssertEqual(status.isSuccess, status != .error)
        }
    }

    func testResumeOutcomeHeadlineDetailAndRecovery() {
        let native = CLIAgentResumeOutcome(
            response: CLIAgentSessionActionResponse(
                status: .nativeResume,
                targetRuntime: "claude_code",
                argv: ["claude", "--resume", "abc"],
                pid: 4242
            ),
            requestedTargetDisplayName: "Claude Code"
        )
        XCTAssertTrue(native.isSuccess)
        XCTAssertEqual(native.headline, "Native resume · Claude Code")
        XCTAssertEqual(native.detail, "PID 4242")
        XCTAssertNil(native.recovery)

        // No explicit target → derive the display name from the wire id.
        let handoff = CLIAgentResumeOutcome(
            response: CLIAgentSessionActionResponse(
                status: .handoff,
                targetRuntime: "grok",
                argv: ["grok", "--prompt-file", "/tmp/x.md"],
                briefingPath: "/tmp/burnbar-resume.md"
            )
        )
        XCTAssertEqual(handoff.headline, "Handoff package started · Grok")
        XCTAssertEqual(handoff.detail, "burnbar-resume.md")

        let failure = CLIAgentResumeOutcome(
            response: CLIAgentSessionActionResponse(status: .error, errorCode: "session_not_found")
        )
        XCTAssertFalse(failure.isSuccess)
        XCTAssertEqual(failure.headline, "Couldn’t restart")
        XCTAssertEqual(failure.recovery, "Error: session_not_found")

        let bareError = CLIAgentResumeOutcome(
            response: CLIAgentSessionActionResponse(status: .error)
        )
        XCTAssertEqual(bareError.recovery, "Update or restart OpenBurnBar on your Mac")
    }

    func testDaemonResponseMapsToActionStatus() {
        func status(kind: String, argv: [String]? = nil, targetArgv: [String]? = nil,
                    action: CLIAgentSessionActionKind = .resume) -> CLIAgentSessionActionStatus {
            CLIAgentSessionActionResponse(
                daemonResponse: BurnBarRunResumeResponse(kind: kind, argv: argv, targetArgv: targetArgv),
                requestedAction: action
            ).status
        }
        XCTAssertEqual(status(kind: "native"), .nativeResume)
        XCTAssertEqual(status(kind: "spawned", argv: ["claude", "--resume", "x"]), .nativeResume)
        XCTAssertEqual(status(kind: "spawned", targetArgv: ["grok", "--prompt-file", "x"]), .handoff)
        XCTAssertEqual(status(kind: "spawned"), .spawned)
        XCTAssertEqual(status(kind: "ported", action: .packageOnly), .packageOnly)
        XCTAssertEqual(status(kind: "ported", action: .resume), .handoff)
        XCTAssertEqual(status(kind: "ported", action: .handoff), .handoff)
        XCTAssertEqual(status(kind: "error"), .error)
        XCTAssertEqual(status(kind: "totally_unknown"), .handoff)

        // argv preference: argv first, then targetArgv, else [].
        let ported = CLIAgentSessionActionResponse(
            daemonResponse: BurnBarRunResumeResponse(
                kind: "ported",
                targetArgv: ["grok", "--prompt-file", "/tmp/x.md"],
                briefingPath: "/tmp/x.md",
                workingDirectory: "/tmp/app",
                note: "native_handle_invalid_fell_back_to_handoff"
            ),
            requestedAction: .resume
        )
        XCTAssertEqual(ported.argv, ["grok", "--prompt-file", "/tmp/x.md"])
        XCTAssertEqual(ported.briefingPath, "/tmp/x.md")
        XCTAssertEqual(ported.workingDirectory, "/tmp/app")
    }


    func testResumeLookupIDStripsArchivePrefix() {
        let now = Date(timeIntervalSince1970: 1_714_200_000)
        let live = CLIAgentSessionRecord(
            id: "codex:abc", agent: .codex, sourceKind: .liveChat,
            title: "t", preview: "", createdAt: now, updatedAt: now
        )
        XCTAssertEqual(live.resumeLookupID, "codex:abc")

        let archived = CLIAgentSessionRecord(
            id: "archive:claude:sess-1", agent: .claude, sourceKind: .archivedLog,
            title: "t", preview: "", createdAt: now, updatedAt: now
        )
        XCTAssertEqual(archived.resumeLookupID, "sess-1")

        // Prefix that doesn't match the row's own agent token is left intact.
        let mismatched = CLIAgentSessionRecord(
            id: "archive:codex:sess-2", agent: .claude, sourceKind: .archivedLog,
            title: "t", preview: "", createdAt: now, updatedAt: now
        )
        XCTAssertEqual(mismatched.resumeLookupID, "archive:codex:sess-2")
    }
}
