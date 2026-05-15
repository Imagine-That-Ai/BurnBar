import XCTest
import Foundation
import FirebaseAuth
import FirebaseCore
import OpenBurnBarCore
@testable import OpenBurnBarMobile

@MainActor
final class HermesServiceTests: XCTestCase {

    func testInitialState() {
        let service = HermesService()
        XCTAssertTrue(service.messages.isEmpty)
        XCTAssertFalse(service.isStreaming)
        XCTAssertNil(service.lastError)
        XCTAssertFalse(service.isReachable)
    }

    func testSendMessageAppendsUserMessage() {
        let service = HermesService()
        service.sendMessage("Hello Hermes")
        XCTAssertEqual(service.messages.count, 1)
        XCTAssertEqual(service.messages.first?.role, .user)
        XCTAssertEqual(service.messages.first?.text, "Hello Hermes")
        XCTAssertTrue(service.isStreaming)
    }

    func testSendEmptyMessageIsNoOp() {
        let service = HermesService()
        service.sendMessage("   ")
        XCTAssertTrue(service.messages.isEmpty)
    }

    func testClearChatRemovesMessages() {
        let service = HermesService()
        service.sendMessage("Test")
        service.clearChat()
        XCTAssertTrue(service.messages.isEmpty)
        XCTAssertNil(service.lastError)
    }

    func testHermesChatMessageFields() {
        let msg = HermesChatMessage(role: .user, text: "Hi", modelName: "GLM-5")
        XCTAssertEqual(msg.role, .user)
        XCTAssertEqual(msg.text, "Hi")
        XCTAssertEqual(msg.modelName, "GLM-5")
        XCTAssertFalse(msg.isStreaming)
        XCTAssertFalse(msg.isError)
    }

    func testHermesChatMessageErrorFlag() {
        let msg = HermesChatMessage(role: .assistant, text: "Oops", isError: true)
        XCTAssertTrue(msg.isError)
        XCTAssertFalse(msg.isStreaming)
    }

    func testHermesChatMessageMarksWallClockTokensPerSecondAsEstimated() {
        // Provider-reported token count but only wall-clock duration. We
        // honestly mark this as estimated because the duration is not
        // provider-measured; relays/proxies regularly inflate it.
        let responseStartedAt = Date(timeIntervalSince1970: 100)
        let firstChunkAt = Date(timeIntervalSince1970: 101)
        let completedAt = Date(timeIntervalSince1970: 105)
        let msg = HermesChatMessage(
            role: .assistant,
            text: "Done",
            responseStartedAt: responseStartedAt,
            firstResponseChunkAt: firstChunkAt,
            responseCompletedAt: completedAt,
            outputTokenCount: 20,
            totalTokenCount: 32,
            tokenCountSource: .providerUsage
        )

        XCTAssertEqual(msg.tokensPerSecond ?? 0, 5, accuracy: 0.001)
        XCTAssertEqual(msg.generationDurationSeconds ?? 0, 4, accuracy: 0.001)
        XCTAssertEqual(msg.totalResponseDurationSeconds ?? 0, 5, accuracy: 0.001)
        XCTAssertEqual(msg.generationDurationSource, .wallClock)
        XCTAssertEqual(msg.tokensPerSecondDisplayText, "~5.00 tok/s")
        XCTAssertTrue(msg.isTokensPerSecondEstimated)
    }

    func testHermesChatMessageFinalizesEstimatedTokensPerSecondWhenUsageIsMissing() {
        let responseStartedAt = Date(timeIntervalSince1970: 100)
        let firstChunkAt = Date(timeIntervalSince1970: 101)
        var msg = HermesChatMessage(
            role: .assistant,
            text: "Hello world from Hermes",
            responseStartedAt: responseStartedAt,
            firstResponseChunkAt: firstChunkAt
        )

        msg.finalizeResponseMetrics(at: Date(timeIntervalSince1970: 103))

        XCTAssertEqual(msg.outputTokenCount, HermesChatMessage.estimatedOutputTokens(for: "Hello world from Hermes"))
        XCTAssertEqual(msg.tokenCountSource, .estimatedText)
        XCTAssertTrue(msg.isTokensPerSecondEstimated)
        XCTAssertTrue(msg.tokensPerSecondDisplayText?.hasPrefix("~") ?? false)
    }

    func testHermesChatMessageSuppressesTokensPerSecondForErrors() {
        var msg = HermesChatMessage(
            role: .assistant,
            text: "Connection failed",
            isError: true,
            responseStartedAt: Date(timeIntervalSince1970: 100),
            firstResponseChunkAt: Date(timeIntervalSince1970: 101)
        )

        msg.finalizeResponseMetrics(at: Date(timeIntervalSince1970: 102))

        XCTAssertNil(msg.outputTokenCount)
        XCTAssertNil(msg.tokensPerSecond)
        XCTAssertNil(msg.tokensPerSecondDisplayText)
    }

    func testHermesServiceErrorDescriptions() {
        XCTAssertNotNil(HermesServiceError.invalidResponse.errorDescription)
        XCTAssertNotNil(HermesServiceError.httpStatus(code: 500).errorDescription)
        XCTAssertNotNil(HermesServiceError.decodingFailed.errorDescription)
    }

    func testHermesChatMessagePrefersProviderEvalDurationForTokensPerSecond() {
        let responseStartedAt = Date(timeIntervalSince1970: 100)
        let firstChunkAt = Date(timeIntervalSince1970: 100.01)
        let completedAt = Date(timeIntervalSince1970: 100.05) // wall-clock 40ms — would lie
        let msg = HermesChatMessage(
            role: .assistant,
            text: "Local model run",
            responseStartedAt: responseStartedAt,
            firstResponseChunkAt: firstChunkAt,
            responseCompletedAt: completedAt,
            outputTokenCount: 30,
            totalTokenCount: 80,
            tokenCountSource: .providerUsage,
            providerGenerationDurationSeconds: 2.5,
            providerTotalDurationSeconds: 3.0
        )

        // Provider eval duration: 30 / 2.5 = 12 tok/s, *not* 30 / 0.04 = 750 tok/s.
        XCTAssertEqual(msg.tokensPerSecond ?? 0, 12, accuracy: 0.001)
        XCTAssertEqual(msg.generationDurationSource, .providerEvalDuration)
        XCTAssertFalse(msg.isTokensPerSecondEstimated)
        XCTAssertEqual(msg.tokensPerSecondDisplayText, "12.0 tok/s")
    }

    func testHermesChatMessageSuppressesTokensPerSecondWhenWallClockIsBuffered() {
        let responseStartedAt = Date(timeIntervalSince1970: 100)
        let firstChunkAt = Date(timeIntervalSince1970: 100.01)
        let completedAt = Date(timeIntervalSince1970: 100.05) // wall-clock 40ms
        let msg = HermesChatMessage(
            role: .assistant,
            text: "Buffered burst",
            responseStartedAt: responseStartedAt,
            firstResponseChunkAt: firstChunkAt,
            responseCompletedAt: completedAt,
            outputTokenCount: 30,
            totalTokenCount: 30,
            tokenCountSource: .providerUsage
        )

        XCTAssertNil(msg.tokensPerSecond)
        XCTAssertNil(msg.tokensPerSecondDisplayText)
        XCTAssertEqual(msg.generationDurationSource, .bufferedWallClock)
    }

    func testHermesChatMessageWallClockTPSGetsTildePrefix() {
        let msg = HermesChatMessage(
            role: .assistant,
            text: "Trustworthy stream",
            responseStartedAt: Date(timeIntervalSince1970: 100),
            firstResponseChunkAt: Date(timeIntervalSince1970: 101),
            responseCompletedAt: Date(timeIntervalSince1970: 105),
            outputTokenCount: 40,
            tokenCountSource: .providerUsage
        )

        // Token count is exact, but the duration is wall-clock. We publish
        // the rate with a `~` so the user sees the source isn't fully
        // trustworthy.
        XCTAssertEqual(msg.tokensPerSecond ?? 0, 10, accuracy: 0.001)
        XCTAssertEqual(msg.generationDurationSource, .wallClock)
        XCTAssertEqual(msg.tokensPerSecondDisplayText, "~10.0 tok/s")
        XCTAssertTrue(msg.isTokensPerSecondEstimated)
    }

    func testHermesChatMessageDetectsServerRoutedDifferentModel() {
        var asked = HermesChatMessage(role: .assistant, text: "Hi", requestedModelID: "gemma4:31b")
        XCTAssertFalse(asked.serverConfirmedModel)
        XCTAssertFalse(asked.serverRoutedToDifferentModel)

        asked.applyResponseModelID("minimax-m2.7")
        XCTAssertTrue(asked.serverConfirmedModel)
        XCTAssertTrue(asked.serverRoutedToDifferentModel)
        XCTAssertEqual(asked.responseModelID, "minimax-m2.7")
        XCTAssertEqual(asked.modelName, "minimax-m2.7")
    }

    func testHermesChatMessageRoutedFlagIgnoresCaseAndWhitespace() {
        var asked = HermesChatMessage(role: .assistant, text: "Hi", requestedModelID: "Gemma4:31B")
        asked.applyResponseModelID("  gemma4:31b  ")
        XCTAssertFalse(asked.serverRoutedToDifferentModel)
        XCTAssertEqual(asked.responseModelID, "gemma4:31b")
    }

    func testRelayConnectionDoesNotRequireReachableURL() {
        let service = HermesService(relayTransport: FakeHermesRelayTransport())
        let relay = HermesConnectionRecord(
            id: "relay-mac",
            displayName: "Mac Hermes Relay",
            mode: .relayLink,
            status: .online,
            relayPublicKey: HermesRelayCrypto.generatePrivateKey().publicKeyBase64,
            relayKeyVersion: HermesRelayCrypto.keyVersion,
            relayEncryption: HermesRelayCrypto.algorithm,
            capabilities: ["chat_completions", "remote_relay"]
        )

        XCTAssertTrue(service.selectConnection(relay, refresh: false))
        XCTAssertEqual(service.selectedConnection.id, "relay-mac")
        XCTAssertNil(service.lastError)
    }

    func testRelayConnectionWithoutEncryptionMetadataIsRejected() {
        let service = HermesService(relayTransport: FakeHermesRelayTransport())
        let relay = HermesConnectionRecord(
            id: "legacy-relay-mac",
            displayName: "Legacy Mac Hermes Relay",
            mode: .relayLink,
            status: .online,
            capabilities: ["chat_completions", "remote_relay"]
        )

        XCTAssertFalse(service.selectConnection(relay, refresh: false))
        XCTAssertEqual(service.selectedConnection.id, HermesConnectionRecord.localDefault.id)
        XCTAssertTrue(service.lastError?.contains("Update OpenBurnBar on your Mac") ?? false)
    }

    func testSuggestedRelayConnectionPicksNewestOnlineEncryptedRelay() {
        let older = HermesConnectionRecord(
            id: "relay-old",
            displayName: "Old Mac Relay",
            mode: .relayLink,
            status: .online,
            relayPublicKey: HermesRelayCrypto.generatePrivateKey().publicKeyBase64,
            relayKeyVersion: HermesRelayCrypto.keyVersion,
            relayEncryption: HermesRelayCrypto.algorithm,
            capabilities: ["chat_completions", "remote_relay"],
            lastSeenAt: Date(timeIntervalSince1970: 100)
        )
        let newer = HermesConnectionRecord(
            id: "relay-new",
            displayName: "Current Mac Relay",
            mode: .relayLink,
            status: .online,
            relayPublicKey: HermesRelayCrypto.generatePrivateKey().publicKeyBase64,
            relayKeyVersion: HermesRelayCrypto.keyVersion,
            relayEncryption: HermesRelayCrypto.algorithm,
            capabilities: ["chat_completions", "remote_relay"],
            lastSeenAt: Date(timeIntervalSince1970: 200)
        )
        let legacy = HermesConnectionRecord(
            id: "relay-legacy",
            displayName: "Legacy Relay",
            mode: .relayLink,
            status: .online
        )
        let service = HermesService(relayTransport: FakeHermesRelayTransport())
        service.connections = [.localDefault, legacy, older, newer]

        XCTAssertEqual(service.suggestedRelayConnection?.id, "relay-new")
    }

    func testConnectToSuggestedRelayIsExplicitUserGrant() {
        let service = HermesService(relayTransport: FakeHermesRelayTransport())
        service.connections = [.localDefault, relayConnection()]

        XCTAssertTrue(service.hasPendingRelaySuggestion)
        XCTAssertTrue(service.connectToSuggestedRelay(refresh: false))
        XCTAssertEqual(service.selectedConnection.id, "relay-mac")
        XCTAssertFalse(service.hasPendingRelaySuggestion)
    }

    func testPendingRelaySuggestionRequiresDifferentSelectedHost() {
        let service = HermesService(relayTransport: FakeHermesRelayTransport())
        let relay = relayConnection()
        service.connections = [.localDefault, relay]

        XCTAssertTrue(service.hasPendingRelaySuggestion)

        XCTAssertTrue(service.selectConnection(relay, refresh: false))
        XCTAssertFalse(service.hasPendingRelaySuggestion)
    }

    func testSendAutoSelectsAvailableRelayWhenLocalHostIsOffline() async {
        let relayTransport = FakeHermesRelayTransport()
        relayTransport.streamingEvents = [
            #"data: {"choices":[{"delta":{"content":"relay ok"}}]}"#
        ]
        let service = HermesService(relayTransport: relayTransport)
        let relay = relayConnection()
        service.connections = [.localDefault, relay]
        service.selectedConnection = .localDefault
        service.isReachable = false

        service.sendMessage("What model are you using?")
        await waitForStreamToFinish(service)

        XCTAssertEqual(service.selectedConnection.id, relay.id)
        XCTAssertEqual(relayTransport.streamingPayloads.first?.connectionID, relay.id)
        XCTAssertEqual(service.messages.last?.text, "relay ok")
        XCTAssertFalse(service.hasPendingRelaySuggestion)
    }

    func testRefreshConnectionsReadsFirestoreBackedRelayRepository() async {
        let relay = relayConnection()
        let repository = FakeHermesConnectionRepository(connections: [relay])
        let service = HermesService(
            connectionRepository: repository,
            relayTransport: FakeHermesRelayTransport()
        )

        await service.refreshConnections()

        XCTAssertEqual(repository.listCallCount, 1)
        XCTAssertEqual(service.connections.map(\.id), [
            HermesConnectionRecord.localDefault.id,
            relay.id
        ])
        XCTAssertEqual(service.suggestedRelayConnection?.id, relay.id)
        XCTAssertNil(service.runtimeErrorText)
    }

    func testRefreshConnectionsSurfacesDiscoveryError() async {
        let repository = FakeHermesConnectionRepository(error: URLError(.cannotFindHost))
        let service = HermesService(
            connectionRepository: repository,
            relayTransport: FakeHermesRelayTransport()
        )

        await service.refreshConnections()

        XCTAssertEqual(service.connections.map(\.id), [HermesConnectionRecord.localDefault.id])
        XCTAssertTrue(service.runtimeErrorText?.contains("Could not load Hermes connections") ?? false)
    }

    func testFirestoreConnectionDocumentDecoderMatchesPublishedRelayShape() throws {
        let privateKey = HermesRelayCrypto.generatePrivateKey()
        let now = Date()
        let record = try XCTUnwrap(FirestoreHermesConnectionRepository.decodeConnectionDocument(
            [
                "displayName": "Alberto's MacBook Pro Hermes Relay",
                "mode": "relayLink",
                "status": "online",
                "advertisedModel": "hermes",
                "relayPublicKey": privateKey.publicKeyBase64,
                "relayKeyVersion": HermesRelayCrypto.keyVersion,
                "relayEncryption": HermesRelayCrypto.algorithm,
                "realtimeRelayURL": "wss://hermes-relay.example.com",
                "realtimeRelayStatus": "online",
                "realtimeRelayLastSeenAt": "2026-05-07T12:34:56.789Z",
                "realtimeRelayProtocolVersion": HermesRealtimeRelayProtocol.version,
                "capabilities": ["chat_completions", "remote_relay", HermesRealtimeRelayProtocol.capability],
                "createdAt": now,
                "updatedAt": "2026-05-07T12:34:56Z",
                "lastSeenAt": now,
                "schemaVersion": 2
            ],
            documentID: "relay-mac"
        ))

        XCTAssertEqual(record.id, "relay-mac")
        XCTAssertEqual(record.mode, .relayLink)
        XCTAssertEqual(record.status, .online)
        XCTAssertEqual(record.relayPublicKey, privateKey.publicKeyBase64)
        XCTAssertEqual(record.relayEncryption, HermesRelayCrypto.algorithm)
        XCTAssertEqual(record.realtimeRelayURL, "wss://hermes-relay.example.com")
        XCTAssertEqual(record.realtimeRelayStatus, "online")
        XCTAssertEqual(record.realtimeRelayProtocolVersion, HermesRealtimeRelayProtocol.version)
        XCTAssertNotNil(record.realtimeRelayLastSeenAt)
    }

    func testFirestoreConnectionDocumentDecoderSkipsRevokedRelay() throws {
        let record = try FirestoreHermesConnectionRepository.decodeConnectionDocument(
            [
                "displayName": "Revoked Relay",
                "mode": "relayLink",
                "status": "revoked",
                "capabilities": [],
                "createdAt": Date(),
                "updatedAt": Date(),
                "schemaVersion": 1
            ],
            documentID: "relay-revoked"
        )

        XCTAssertNil(record)
    }

    func testRelayStreamingParsesTextAndToolCalls() async {
        let relay = FakeHermesRelayTransport()
        relay.streamingEvents = [
            #"data: {"choices":[{"delta":{"content":"Hello"}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"id":"tool-1","function":{"name":"read_file"}}]}}]}"#,
            "data: [DONE]"
        ]
        let service = HermesService(relayTransport: relay)
        XCTAssertTrue(service.selectConnection(relayConnection(), refresh: false))

        service.sendMessage("Use the relay")
        await waitForStreamToFinish(service)

        XCTAssertEqual(relay.streamingPayloads.first?.connectionID, "relay-mac")
        XCTAssertEqual(service.messages.last?.role, .assistant)
        XCTAssertEqual(service.messages.last?.text, "Hello")
        XCTAssertEqual(service.messages.last?.toolCalls.first?.name, "read_file")
        XCTAssertEqual(service.messages.last?.toolCalls.first?.status, "done")
        XCTAssertFalse(service.isStreaming)
    }

    func testRelayStreamingAccumulatesToolCallArgumentsAcrossDeltas() async throws {
        // OpenAI-compatible streaming emits a tool call across multiple
        // chunks: the first carries the function name, and successive chunks
        // carry partial `arguments` fragments that must be concatenated to
        // form the full JSON. We then surface a short `detail` preview.
        let relay = FakeHermesRelayTransport()
        relay.streamingEvents = [
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_42","function":{"name":"read_file","arguments":"{\"path\":\""}}]}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"AgentLens/Services/HermesService.swift\"}"}}]}}]}"#,
            #"data: {"choices":[{"delta":{"content":"Done."}}]}"#,
            "data: [DONE]"
        ]
        let service = HermesService(relayTransport: relay)
        XCTAssertTrue(service.selectConnection(relayConnection(), refresh: false))

        service.sendMessage("Read a file")
        await waitForStreamToFinish(service)

        let last = try XCTUnwrap(service.messages.last)
        XCTAssertEqual(last.role, .assistant)
        XCTAssertEqual(last.text, "Done.")
        let tool = try XCTUnwrap(last.toolCalls.first)
        XCTAssertEqual(tool.id, "call_42")
        XCTAssertEqual(tool.name, "read_file")
        XCTAssertEqual(tool.status, "done")
        XCTAssertEqual(tool.arguments, "{\"path\":\"AgentLens/Services/HermesService.swift\"}")
        XCTAssertEqual(tool.detail, "AgentLens/Services/HermesService.swift")
    }

    func testHermesSummarizeToolArgumentsPullsKnownKeys() {
        XCTAssertEqual(
            HermesService.summarizeToolArguments(#"{"path":"/etc/hosts"}"#),
            "/etc/hosts"
        )
        XCTAssertEqual(
            HermesService.summarizeToolArguments(#"{"command":"ls -al"}"#),
            "ls -al"
        )
        XCTAssertEqual(
            HermesService.summarizeToolArguments(#"{"query":"timezone"}"#),
            "timezone"
        )
        // Partial JSON fragment (mid-stream) — regex fallback should still
        // pull the path so the pill shows something useful before the JSON
        // closes.
        XCTAssertEqual(
            HermesService.summarizeToolArguments(#"{"path":"docs/README.md""#),
            "docs/README.md"
        )
        XCTAssertNil(HermesService.summarizeToolArguments(""))
    }

    func testRelayStreamingParsesFinalMessageContentAfterModelSwitch() async throws {
        let suiteName = "HermesServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let relay = FakeHermesRelayTransport()
        relay.streamingEvents = [
            #"data: {"model":"MiniMax-M2.7","choices":[{"message":{"role":"assistant","content":"Switched model answered normally."},"finish_reason":"stop"}],"usage":{"prompt_tokens":12,"completion_tokens":4,"total_tokens":16}}"#,
            "data: [DONE]"
        ]
        let service = HermesService(relayTransport: relay, defaults: defaults)
        XCTAssertTrue(service.selectConnection(relayConnection(), refresh: false))

        let glm = HermesRuntimeModelOption(
            providerID: "zai",
            providerName: "Z.AI",
            modelID: "glm-5v-turbo",
            displayName: "GLM-5V Turbo"
        )
        let minimax = HermesRuntimeModelOption(
            providerID: "minimax",
            providerName: "MiniMax",
            modelID: "MiniMax-M2.7",
            displayName: "MiniMax M2.7"
        )
        service.modelOptions = [glm, minimax]
        service.selectModel(glm)
        service.messages.append(HermesChatMessage(role: .user, text: "Earlier question"))
        service.messages.append(HermesChatMessage(role: .assistant, text: "Earlier answer", requestedModelID: "glm-5v-turbo", responseModelID: "glm-5v-turbo"))

        service.selectModel(minimax)
        service.sendMessage("Continue with the new model")
        await waitForStreamToFinish(service)

        let assistant = try XCTUnwrap(service.messages.last)
        XCTAssertEqual(assistant.text, "Switched model answered normally.")
        XCTAssertFalse(assistant.isError)
        XCTAssertEqual(assistant.requestedModelID, "MiniMax-M2.7")
        XCTAssertEqual(assistant.responseModelID, "MiniMax-M2.7")
        XCTAssertEqual(assistant.outputTokenCount, 4)

        let body = try XCTUnwrap(relay.streamingPayloads.first?.body)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "MiniMax-M2.7")
    }

    func testRelayStreamingParsesFinalMessageContentParts() async {
        let relay = FakeHermesRelayTransport()
        relay.streamingEvents = [
            #"data: {"choices":[{"message":{"role":"assistant","content":[{"type":"text","text":"Part one "},{"type":"output_text","text":"part two"}]},"finish_reason":"stop"}]}"#,
            "data: [DONE]"
        ]
        let service = HermesService(relayTransport: relay)
        XCTAssertTrue(service.selectConnection(relayConnection(), refresh: false))

        service.sendMessage("Use final content parts")
        await waitForStreamToFinish(service)

        XCTAssertEqual(service.messages.last?.text, "Part one part two")
        XCTAssertFalse(service.messages.last?.isError ?? true)
    }

    // MARK: - Empty-response rescue

    func testEmptyResponseFallbackPrefersRefusal() {
        let result = HermesChatMessage.emptyResponseFallback(
            refusal: "I can't help with that.",
            reasoning: "<thinking>",
            finishReason: "content_filter"
        )
        XCTAssertEqual(result.text, "I can't help with that.")
        XCTAssertFalse(result.isError)
    }

    func testEmptyResponseFallbackHoistsReasoningWhenNoVisibleContent() {
        let result = HermesChatMessage.emptyResponseFallback(
            refusal: "",
            reasoning: "Reasoning channel response.",
            finishReason: "stop"
        )
        XCTAssertTrue(result.text.hasSuffix("Reasoning channel response."))
        // The marker is the user-visible signal that they're reading the
        // reasoning channel rather than a polished answer; without it
        // raw "I should think about…" preambles look like the model's
        // intended reply.
        XCTAssertTrue(result.text.contains("only emitted reasoning"), "Reasoning hoist must include a marker so users know it's not a final answer. Got: \(result.text)")
        XCTAssertFalse(result.isError)
    }

    func testEmptyResponseFallbackKeysOffFinishReasonForLengthCap() {
        let result = HermesChatMessage.emptyResponseFallback(
            refusal: "",
            reasoning: "",
            finishReason: "length"
        )
        XCTAssertTrue(result.text.contains("output budget"))
        XCTAssertTrue(result.isError)
    }

    func testEmptyResponseFallbackKeysOffFinishReasonForContentFilter() {
        let result = HermesChatMessage.emptyResponseFallback(
            refusal: "",
            reasoning: "",
            finishReason: "content_filter"
        )
        XCTAssertTrue(result.text.contains("content safety"))
        XCTAssertTrue(result.isError)
    }

    func testEmptyResponseFallbackDefaultsToGenericMessage() {
        let result = HermesChatMessage.emptyResponseFallback(
            refusal: "",
            reasoning: "",
            finishReason: nil
        )
        XCTAssertTrue(result.text.contains("finished without returning text"))
        XCTAssertTrue(result.isError)
    }

    func testRelayStreamingHoistsReasoningWhenContentNeverFlushes() async throws {
        // DeepSeek R1 / Qwen3 thinking and certain MiniMax routes
        // sometimes emit the entire answer on the reasoning channel and
        // never flush to `content`. The empty-text fallback should rescue
        // it instead of telling the user "Hermes finished without text".
        let relay = FakeHermesRelayTransport()
        relay.streamingEvents = [
            #"data: {"choices":[{"delta":{"reasoning_content":"The answer"}}]}"#,
            #"data: {"choices":[{"delta":{"reasoning_content":" is 42."},"finish_reason":"stop"}]}"#,
            "data: [DONE]"
        ]
        let service = HermesService(relayTransport: relay)
        XCTAssertTrue(service.selectConnection(relayConnection(), refresh: false))

        service.sendMessage("What's the meaning of life?")
        await waitForStreamToFinish(service)

        let last = try XCTUnwrap(service.messages.last)
        XCTAssertEqual(last.role, .assistant)
        XCTAssertTrue(last.text.hasSuffix("The answer is 42."))
        XCTAssertTrue(last.text.contains("only emitted reasoning"))
        XCTAssertFalse(last.isError)
    }

    func testRelayStreamingSurfacesRefusalAsAssistantText() async throws {
        // OpenAI-compatible servers emit `delta.refusal` when the model
        // declines instead of producing `content`. We should surface the
        // refusal so the user knows the model intentionally responded.
        let relay = FakeHermesRelayTransport()
        relay.streamingEvents = [
            #"data: {"choices":[{"delta":{"refusal":"I can't help with that request."},"finish_reason":"content_filter"}]}"#,
            "data: [DONE]"
        ]
        let service = HermesService(relayTransport: relay)
        XCTAssertTrue(service.selectConnection(relayConnection(), refresh: false))

        service.sendMessage("Forbidden ask")
        await waitForStreamToFinish(service)

        let last = try XCTUnwrap(service.messages.last)
        XCTAssertEqual(last.role, .assistant)
        XCTAssertEqual(last.text, "I can't help with that request.")
        XCTAssertFalse(last.isError)
    }

    func testRelayStreamingReportsLengthCapWhenNothingArrived() async throws {
        // Model hit max_tokens before any content was emitted. Surface
        // an honest message instead of the generic "finished without
        // returning text" so the user knows to retry shorter or pick a
        // model with a larger reply ceiling.
        let relay = FakeHermesRelayTransport()
        relay.streamingEvents = [
            #"data: {"choices":[{"delta":{},"finish_reason":"length"}]}"#,
            "data: [DONE]"
        ]
        let service = HermesService(relayTransport: relay)
        XCTAssertTrue(service.selectConnection(relayConnection(), refresh: false))

        service.sendMessage("Tell me everything")
        await waitForStreamToFinish(service)

        let last = try XCTUnwrap(service.messages.last)
        XCTAssertEqual(last.role, .assistant)
        XCTAssertTrue(last.isError)
        XCTAssertTrue(last.text.contains("output budget"), "Expected length-cap message, got: \(last.text)")
    }

    // MARK: - Pi parallel coverage

    func testPiEmptyResponseFallbackPrefersRefusal() {
        let result = PiChatMessage.emptyResponseFallback(
            refusal: "Pi declined.",
            reasoning: "internal",
            finishReason: "content_filter"
        )
        XCTAssertEqual(result.text, "Pi declined.")
        XCTAssertFalse(result.isError)
    }

    func testPiEmptyResponseFallbackHoistsReasoningWithMarker() {
        let result = PiChatMessage.emptyResponseFallback(
            refusal: "",
            reasoning: "Reasoning channel only.",
            finishReason: "stop"
        )
        XCTAssertTrue(result.text.contains("Reasoning channel only."))
        XCTAssertTrue(result.text.contains("only emitted reasoning"))
        XCTAssertFalse(result.isError)
    }

    func testPiEmptyResponseFallbackKeysOffFinishReason() {
        let length = PiChatMessage.emptyResponseFallback(refusal: "", reasoning: "", finishReason: "length")
        XCTAssertTrue(length.text.contains("output budget"))
        XCTAssertTrue(length.isError)

        let filter = PiChatMessage.emptyResponseFallback(refusal: "", reasoning: "", finishReason: "content_filter")
        XCTAssertTrue(filter.text.contains("content safety"))
        XCTAssertTrue(filter.isError)

        let generic = PiChatMessage.emptyResponseFallback(refusal: "", reasoning: "", finishReason: nil)
        XCTAssertTrue(generic.text.contains("Pi finished without"))
        XCTAssertTrue(generic.isError)
    }

    func testRelayStreamingExposesResponseModelName() async {
        let relay = FakeHermesRelayTransport()
        relay.streamingEvents = [
            #"data: {"model":"glm-5","choices":[{"delta":{"content":"model aware"}}]}"#,
            "data: [DONE]"
        ]
        let service = HermesService(relayTransport: relay)
        XCTAssertTrue(service.selectConnection(relayConnection(), refresh: false))

        service.sendMessage("Which model?")
        await waitForStreamToFinish(service)

        XCTAssertEqual(service.messages.last?.text, "model aware")
        XCTAssertEqual(service.messages.last?.modelName, "glm-5")
    }

    func testRelayStreamingTracksRequestedAndResponseModelsHonestly() async {
        let suiteName = "HermesServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let relay = FakeHermesRelayTransport()
        relay.streamingEvents = [
            // Server explicitly tells us it routed the request to a different model.
            #"data: {"model":"minimax-m2.7","choices":[{"delta":{"content":"different model used"}}]}"#,
            "data: [DONE]"
        ]
        let service = HermesService(relayTransport: relay, defaults: defaults)
        XCTAssertTrue(service.selectConnection(relayConnection(), refresh: false))
        let gemma = HermesRuntimeModelOption(
            providerID: "ollama-local",
            providerName: "Ollama Local",
            modelID: "gemma4:31b",
            displayName: "Gemma 4 (31B)"
        )
        service.modelOptions = [gemma]
        service.selectModel(gemma)

        service.sendMessage("Try gemma")
        await waitForStreamToFinish(service)

        let assistant = service.messages.last
        XCTAssertEqual(assistant?.requestedModelID, "gemma4:31b")
        XCTAssertEqual(assistant?.responseModelID, "minimax-m2.7")
        XCTAssertTrue(assistant?.serverRoutedToDifferentModel ?? false)
    }

    func testRelayStreamingPreservesRequestedModelWhenServerIsSilent() async {
        let suiteName = "HermesServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let relay = FakeHermesRelayTransport()
        relay.streamingEvents = [
            #"data: {"choices":[{"delta":{"content":"silent server"}}]}"#,
            "data: [DONE]"
        ]
        let service = HermesService(relayTransport: relay, defaults: defaults)
        XCTAssertTrue(service.selectConnection(relayConnection(), refresh: false))
        let gemma = HermesRuntimeModelOption(
            providerID: "ollama-local",
            providerName: "Ollama Local",
            modelID: "gemma4:31b",
            displayName: "Gemma 4 (31B)"
        )
        service.modelOptions = [gemma]
        service.selectModel(gemma)

        service.sendMessage("Try gemma")
        await waitForStreamToFinish(service)

        let assistant = service.messages.last
        XCTAssertEqual(assistant?.requestedModelID, "gemma4:31b")
        XCTAssertNil(assistant?.responseModelID)
        XCTAssertFalse(assistant?.serverConfirmedModel ?? true)
        XCTAssertFalse(assistant?.serverRoutedToDifferentModel ?? true)
    }

    func testRelayStreamingUsesOllamaEvalDurationsForHonestTPS() async {
        // Ollama emits eval_count + eval_duration (nanoseconds) at the top
        // level of the final chunk, *not* under "usage". Without these the
        // app would publish wall-clock TPS — which on a buffered relay is
        // essentially "all tokens arrived at once" → 700+ tok/s on a 31B model.
        let relay = FakeHermesRelayTransport()
        relay.streamingEvents = [
            #"data: {"choices":[{"delta":{"content":"Hello"}}]}"#,
            #"data: {"choices":[{"delta":{"content":" world"}}]}"#,
            #"data: {"model":"gemma4:31b","choices":[{"delta":{},"finish_reason":"stop"}],"eval_count":42,"eval_duration":3500000000,"prompt_eval_count":18,"total_duration":4200000000}"#,
            "data: [DONE]"
        ]
        let service = HermesService(relayTransport: relay)
        XCTAssertTrue(service.selectConnection(relayConnection(), refresh: false))

        service.sendMessage("Generate something local")
        await waitForStreamToFinish(service)

        let assistant = service.messages.last
        XCTAssertEqual(assistant?.outputTokenCount, 42)
        XCTAssertEqual(assistant?.totalTokenCount, 60) // 42 + 18 derived
        XCTAssertEqual(assistant?.tokenCountSource, .providerUsage)
        XCTAssertEqual(assistant?.providerGenerationDurationSeconds ?? 0, 3.5, accuracy: 0.0001)
        XCTAssertEqual(assistant?.providerTotalDurationSeconds ?? 0, 4.2, accuracy: 0.0001)
        XCTAssertEqual(assistant?.generationDurationSource, .providerEvalDuration)

        // 42 / 3.5 = 12.0 tok/s — physically plausible for a 31B local model.
        XCTAssertEqual(assistant?.tokensPerSecond ?? 0, 12, accuracy: 0.001)
        XCTAssertEqual(assistant?.tokensPerSecondDisplayText, "12.0 tok/s")
    }

    func testRelayStreamingDropsImpossibleWallClockTPSForBufferedStreams() async {
        // No provider eval duration. All chunks arrive in the same SSE burst,
        // so wall-clock duration would be near zero → publishing it would
        // produce dishonest 600-700 tok/s figures for a local model.
        let relay = FakeHermesRelayTransport()
        relay.streamingEvents = [
            #"data: {"choices":[{"delta":{"content":"Hello world from a buffered stream"}}]}"#,
            #"data: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"completion_tokens":42,"prompt_tokens":18,"total_tokens":60}}"#,
            "data: [DONE]"
        ]
        let service = HermesService(relayTransport: relay)
        XCTAssertTrue(service.selectConnection(relayConnection(), refresh: false))

        service.sendMessage("buffer me")
        await waitForStreamToFinish(service)

        let assistant = service.messages.last
        XCTAssertEqual(assistant?.outputTokenCount, 42)
        XCTAssertEqual(assistant?.generationDurationSource, .bufferedWallClock)
        XCTAssertNil(assistant?.tokensPerSecond, "Must refuse to publish a misleading rate.")
        XCTAssertNil(assistant?.tokensPerSecondDisplayText)
    }

    func testRelayStreamingAccumulatesCurrentConversationTokenBurn() async {
        let relay = FakeHermesRelayTransport()
        relay.streamingEvents = [
            #"data: {"choices":[{"delta":{"content":"Hello"}}]}"#,
            #"data: {"choices":[{"delta":{}}],"usage":{"prompt_tokens":10,"completion_tokens":4,"total_tokens":14}}"#,
            "data: [DONE]"
        ]
        let service = HermesService(relayTransport: relay)
        XCTAssertTrue(service.selectConnection(relayConnection(), refresh: false))

        service.sendMessage("Use the relay")
        await waitForStreamToFinish(service)

        XCTAssertEqual(service.currentConversationTokenBurn, 14)
        XCTAssertEqual(service.messages.last?.outputTokenCount, 4)
        XCTAssertEqual(service.messages.last?.totalTokenCount, 14)
        XCTAssertEqual(service.messages.last?.tokenCountSource, .providerUsage)
        service.clearChat()
        XCTAssertEqual(service.currentConversationTokenBurn, 0)
    }

    func testRelayStreamingDoesNotDoubleCountRepeatedUsageEvents() async {
        let relay = FakeHermesRelayTransport()
        relay.streamingEvents = [
            #"data: {"choices":[{"delta":{"content":"Hello"}}]}"#,
            #"data: {"choices":[{"delta":{}}],"usage":{"prompt_tokens":10,"completion_tokens":4,"total_tokens":14}}"#,
            #"data: {"choices":[{"delta":{}}],"usage":{"prompt_tokens":10,"completion_tokens":4,"total_tokens":14}}"#,
            "data: [DONE]"
        ]
        let service = HermesService(relayTransport: relay)
        XCTAssertTrue(service.selectConnection(relayConnection(), refresh: false))

        service.sendMessage("Use the relay")
        await waitForStreamToFinish(service)

        XCTAssertEqual(service.currentConversationTokenBurn, 14)
        XCTAssertEqual(service.messages.last?.totalTokenCount, 14)
    }

    func testFavoriteModelsPersistAndSelectedModelUsesServiceAPI() {
        let suiteName = "HermesServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let option = HermesRuntimeModelOption(
            providerID: "zai",
            providerName: "Z.AI",
            modelID: "glm-5",
            displayName: "GLM-5"
        )
        let service = HermesService(relayTransport: FakeHermesRelayTransport(), defaults: defaults)
        service.modelOptions = [option]

        service.toggleFavoriteModel(option)
        service.selectModel(option)

        let restored = HermesService(relayTransport: FakeHermesRelayTransport(), defaults: defaults)
        restored.modelOptions = [option]
        XCTAssertEqual(restored.favoriteModelIDs, ["glm-5"])
        XCTAssertEqual(restored.favoriteModelOptions.map(\.modelID), ["glm-5"])
        XCTAssertEqual(restored.selectedModelID, "glm-5")
    }

    func testDirectLANModelRefreshMergesDaemonGatewayInventory() async {
        let session = Self.mockSession { request in
            switch (request.url?.port, request.url?.path) {
            case (8642, "/v1/models"):
                return Self.response(
                    status: 200,
                    url: request.url!,
                    body: #"{"data":[{"id":"hermes-agent","owned_by":"hermes"}]}"#
                )
            case (8317, "/v1/models"):
                return Self.response(
                    status: 200,
                    url: request.url!,
                    body: #"{"data":[{"id":"hermes-agent","owned_by":"hermes"},{"id":"glm-5","owned_by":"zai","display_name":"GLM-5"},{"id":"MiniMax-M2.7","owned_by":"minimax"},{"id":"kimi-k2.6","owned_by":"moonshot"},{"id":"gemma4:e4b","owned_by":"ollama-local","provider_id":"ollama-local","provider_name":"Ollama Local","display_name":"gemma4:e4b (8.0B Q4_K_M)"},{"id":"local-qwen","owned_by":"lmstudio-local","provider_id":"lmstudio-local","provider_name":"LM Studio Local"}]}"#
                )
            default:
                return Self.response(status: 200, url: request.url!, body: "{}")
            }
        }
        let service = HermesService(urlSession: session, secretStore: FakeHermesSecretStore())
        XCTAssertTrue(service.selectConnection(directConnection(), refresh: false))

        await service.refreshRuntime()

        XCTAssertEqual(service.modelOptions.map(\.modelID), ["hermes-agent", "glm-5", "MiniMax-M2.7", "kimi-k2.6", "gemma4:e4b", "local-qwen"])
        XCTAssertEqual(service.modelOptions.map(\.providerID), ["hermes", "zai", "minimax", "kimi-coding", "ollama-local", "lmstudio-local"])
        XCTAssertEqual(service.modelOptions.first(where: { $0.modelID == "glm-5" })?.displayName, "GLM-5")
        XCTAssertEqual(service.modelOptions.first(where: { $0.modelID == "kimi-k2.6" })?.providerName, "Kimi / Kimi Coding Plan")
        XCTAssertEqual(service.modelOptions.first(where: { $0.modelID == "gemma4:e4b" })?.providerName, "Ollama Local")
        XCTAssertEqual(service.modelOptions.first(where: { $0.modelID == "local-qwen" })?.providerName, "LM Studio Local")
    }

    func testRelayStreamingParsesAggregatedCRLFSSEPayload() async {
        let relay = FakeHermesRelayTransport()
        relay.streamingEvents = [
            "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"},\"finish_reason\":null}]}\r\n\r\ndata: {\"choices\":[{\"delta\":{\"content\":\"Hello\"},\"finish_reason\":null}]}\r\n\r\ndata: {\"choices\":[{\"delta\":{\"content\":\" relay\"},\"finish_reason\":null}]}\r\n\r\ndata: [DONE]\r\n\r\n"
        ]
        let service = HermesService(relayTransport: relay)
        XCTAssertTrue(service.selectConnection(relayConnection(), refresh: false))

        service.sendMessage("Use the relay")
        await waitForStreamToFinish(service)

        XCTAssertEqual(service.messages.last?.text, "Hello relay")
        XCTAssertFalse(service.messages.last?.isError ?? true)
    }

    func testRelayStreamingParsesCollapsedDataLinePayload() async {
        let relay = FakeHermesRelayTransport()
        relay.streamingEvents = [
            "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"},\"finish_reason\":null}]}\n" +
            "data: {\"choices\":[{\"delta\":{\"content\":\"Hey\"},\"finish_reason\":null}]}\n" +
            "data: {\"choices\":[{\"delta\":{\"content\":\" there\"},\"finish_reason\":null}]}\n" +
            "data: [DONE]"
        ]
        let service = HermesService(relayTransport: relay)
        XCTAssertTrue(service.selectConnection(relayConnection(), refresh: false))

        service.sendMessage("Use the relay")
        await waitForStreamToFinish(service)

        XCTAssertEqual(service.messages.last?.text, "Hey there")
        XCTAssertFalse(service.messages.last?.isError ?? true)
    }

    func testRelayStreamingSurfacesJSONErrorEvent() async {
        let relay = FakeHermesRelayTransport()
        relay.streamingEvents = [
            #"data: {"error":{"message":"Hermes profile is locked"}}"#
        ]
        let service = HermesService(relayTransport: relay)
        XCTAssertTrue(service.selectConnection(relayConnection(), refresh: false))

        service.sendMessage("Fail")
        await waitForStreamToFinish(service)

        XCTAssertEqual(service.lastError, "Hermes profile is locked")
        XCTAssertEqual(service.messages.last?.text, "Hermes profile is locked")
        XCTAssertTrue(service.messages.last?.isError ?? false)
    }

    func testRelayStreamingFailureReplacesBlankAssistantBubble() async {
        let relay = FakeHermesRelayTransport()
        relay.streamingError = HermesServiceError.relayUnavailable("Mac relay stopped.")
        let service = HermesService(relayTransport: relay)
        XCTAssertTrue(service.selectConnection(relayConnection(), refresh: false))

        service.sendMessage("Fail")
        await waitForStreamToFinish(service)

        XCTAssertEqual(service.messages.filter { $0.role == .assistant }.count, 1)
        XCTAssertEqual(service.messages.last?.text, "Mac relay stopped.")
        XCTAssertTrue(service.messages.last?.isError ?? false)
    }

    func testRelayPayloadFiltersBlankAndErrorAssistantHistory() async throws {
        let relay = FakeHermesRelayTransport()
        relay.streamingEvents = [
            #"data: {"choices":[{"delta":{"content":"ok"}}]}"#
        ]
        let service = HermesService(relayTransport: relay)
        XCTAssertTrue(service.selectConnection(relayConnection(), refresh: false))
        service.messages.append(HermesChatMessage(role: .assistant, text: "", isStreaming: true))
        service.messages.append(HermesChatMessage(role: .assistant, text: "Previous failure", isError: true))
        service.messages.append(HermesChatMessage(role: .user, text: "Previous useful turn"))

        service.sendMessage("Current turn")
        await waitForStreamToFinish(service)

        let body = try XCTUnwrap(relay.streamingPayloads.first?.body)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(object["messages"] as? [[String: String]])
        let streamOptions = try XCTUnwrap(object["stream_options"] as? [String: Any])
        let conversationalMessages = messages.filter { $0["role"] != "system" }
        XCTAssertEqual(conversationalMessages.map { $0["content"] }, ["Previous useful turn", "Current turn"])
        XCTAssertFalse(messages.contains { $0["content"]?.isEmpty == true })
        XCTAssertFalse(messages.contains { $0["content"] == "Previous failure" })
        XCTAssertEqual(streamOptions["include_usage"] as? Bool, true)
    }

    func testRelayReachabilityUsesRelayTransport() async {
        let relay = FakeHermesRelayTransport()
        let service = HermesService(relayTransport: relay)
        XCTAssertTrue(service.selectConnection(relayConnection(), refresh: false))

        await service.checkReachability()

        XCTAssertTrue(service.isReachable)
        XCTAssertEqual(relay.unaryPayloads.first?.operation, .models)
        XCTAssertEqual(relay.unaryPayloads.first?.connectionID, "relay-mac")
        XCTAssertEqual(relay.unaryPayloads.first?.relayEncryption, HermesRelayCrypto.algorithm)
        XCTAssertNotNil(relay.unaryPayloads.first?.relayPublicKey)
    }

    func testRelayResumeSessionLoadsTranscript() async {
        let relay = FakeHermesRelayTransport()
        relay.unaryResponses[.sessionDetail] = Data(
            #"{"messages":[{"id":"u1","role":"user","content":"Remote question","model_id":"ignored-user-model"},{"id":"a1","role":"assistant","content":"Remote answer","model_id":"minimax-m2.7"}]}"#.utf8
        )
        let service = HermesService(relayTransport: relay)
        XCTAssertTrue(service.selectConnection(relayConnection(), refresh: false))

        await service.resumeSession(HermesSessionSummary(id: "session-1"))

        XCTAssertEqual(relay.unaryPayloads.first?.operation, .sessionDetail)
        XCTAssertEqual(relay.unaryPayloads.first?.sessionID, "session-1")
        XCTAssertEqual(service.messages.map(\.text), ["Remote question", "Remote answer"])
        XCTAssertNil(service.messages.first?.modelName)
        XCTAssertEqual(service.messages.last?.modelName, "minimax-m2.7")
    }

    func testRelaySessionListParsesModelNameAliases() async {
        let relay = FakeHermesRelayTransport()
        relay.unaryResponses[.sessions] = Data(
            #"{"sessions":[{"id":"s1","title":"Model run","model_name":"claude-4.5-sonnet","message_count":3},{"id":"s2","title":"Model run 2","modelId":"glm-5","messageCount":2}]}"#.utf8
        )
        let service = HermesService(relayTransport: relay)
        XCTAssertTrue(service.selectConnection(relayConnection(), refresh: false))

        await service.refreshRuntime()

        XCTAssertEqual(service.sessions.map(\.model), ["claude-4.5-sonnet", "glm-5"])
    }

    func testLivePhysicalDeviceRemoteRelayE2E() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["OPENBURNBAR_LIVE_HERMES_RELAY_E2E"] == "1" else {
            throw XCTSkip("Set OPENBURNBAR_LIVE_HERMES_RELAY_E2E=1 with a live relay host to run this physical-device test.")
        }
        let connectionID = try XCTUnwrap(environment["OPENBURNBAR_LIVE_RELAY_CONNECTION_ID"])
        let relayPublicKey = try XCTUnwrap(environment["OPENBURNBAR_LIVE_RELAY_PUBLIC_KEY"])

        try configureFirebaseForLiveE2EIfNeeded()
        let user = try await ensureLiveE2EUser()
        print("OPENBURNBAR_LIVE_E2E_UID=\(user.uid)")

        let relay = HermesConnectionRecord(
            id: connectionID,
            displayName: "Live Mac Hermes Relay",
            mode: .relayLink,
            status: .online,
            advertisedModel: "hermes",
            relayPublicKey: relayPublicKey,
            relayKeyVersion: HermesRelayCrypto.keyVersion,
            relayEncryption: HermesRelayCrypto.algorithm,
            capabilities: ["chat_completions", "remote_relay"]
        )
        let service = HermesService()
        XCTAssertTrue(service.selectConnection(relay, refresh: false))

        await service.checkReachability()
        XCTAssertTrue(service.isReachable, service.runtimeErrorText ?? service.lastError ?? "Relay models check failed.")

        service.sendMessage("Reply with exactly this phrase and no punctuation: burnbar relay ok")
        await waitForStreamToFinish(service, timeout: 180)

        let assistant = try XCTUnwrap(service.messages.last(where: { $0.role == .assistant }))
        XCTAssertFalse(assistant.isError, assistant.text)
        XCTAssertFalse(assistant.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        print("OPENBURNBAR_LIVE_E2E_ASSISTANT_PREFIX=\(assistant.text.prefix(120))")
    }

    func testDirectHTTP401ShowsAPIKeyErrorAndSendsAuthorizationHeader() async {
        let secretStore = FakeHermesSecretStore()
        secretStore.values["lan"] = "secret-token"
        let capture = RequestCapture()
        let session = Self.mockSession { request in
            capture.authorization = request.value(forHTTPHeaderField: "Authorization")
            return Self.response(status: 401, url: request.url!, body: #"{"error":"unauthorized"}"#)
        }
        let service = HermesService(urlSession: session, secretStore: secretStore)
        XCTAssertTrue(service.selectConnection(directConnection(), refresh: false))

        service.sendMessage("Hello")
        await waitForStreamToFinish(service)

        XCTAssertEqual(capture.authorization, "Bearer secret-token")
        XCTAssertTrue(service.lastError?.contains("API key") ?? false)
        XCTAssertTrue(service.messages.last?.isError ?? false)
    }

    func testResumeSessionLoadsTranscriptWithMockNetwork() async {
        let session = Self.mockSession { request in
            XCTAssertEqual(request.url?.path, "/api/sessions/session-1")
            return Self.response(
                status: 200,
                url: request.url!,
                body: #"{"messages":[{"id":"u1","role":"user","content":"Question"},{"id":"a1","role":"assistant","content":"Answer"}]}"#
            )
        }
        let service = HermesService(urlSession: session, secretStore: FakeHermesSecretStore())
        XCTAssertTrue(service.selectConnection(directConnection(), refresh: false))

        await service.resumeSession(HermesSessionSummary(id: "session-1"))

        XCTAssertEqual(service.messages.map(\.text), ["Question", "Answer"])
        XCTAssertEqual(service.messages.map(\.role), [.user, .assistant])
    }

    private func relayConnection() -> HermesConnectionRecord {
        HermesConnectionRecord(
            id: "relay-mac",
            displayName: "Mac Hermes Relay",
            mode: .relayLink,
            status: .online,
            relayPublicKey: HermesRelayCrypto.generatePrivateKey().publicKeyBase64,
            relayKeyVersion: HermesRelayCrypto.keyVersion,
            relayEncryption: HermesRelayCrypto.algorithm,
            capabilities: ["chat_completions", "remote_relay"]
        )
    }

    private func directConnection() -> HermesConnectionRecord {
        HermesConnectionRecord(
            id: "lan",
            displayName: "LAN Hermes",
            mode: .directURL,
            status: .online,
            endpointURL: "http://127.0.0.1:8642"
        )
    }

    private func waitForStreamToFinish(_ service: HermesService, timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while service.isStreaming && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func configureFirebaseForLiveE2EIfNeeded() throws {
        guard FirebaseApp.app() == nil else { return }
        guard let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
              let options = FirebaseOptions(contentsOfFile: path) else {
            XCTFail("GoogleService-Info.plist is missing from the live test host.")
            return
        }
        FirebaseApp.configure(options: options)
    }

    private func ensureLiveE2EUser() async throws -> User {
        if let current = Auth.auth().currentUser {
            return current
        }
        return try await Auth.auth().signInAnonymously().user
    }

    nonisolated private static func mockSession(
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        MockHermesURLProtocol.requestHandler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockHermesURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    nonisolated private static func response(status: Int, url: URL, body: String) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!,
            Data(body.utf8)
        )
    }
}

private final class RequestCapture: @unchecked Sendable {
    nonisolated(unsafe) var authorization: String?
}

@MainActor
private final class FakeHermesRelayTransport: HermesRelayTransporting {
    var unaryResponses: [HermesRelayOperation: Data] = [
        .models: Data(#"{"data":[{"id":"hermes-test","owned_by":"hermes"}]}"#.utf8)
    ]
    var streamingEvents: [String] = []
    var streamingError: Error?
    private(set) var unaryPayloads: [HermesRelayPayload] = []
    private(set) var streamingPayloads: [HermesRelayPayload] = []

    func sendUnary(_ payload: HermesRelayPayload, timeout: TimeInterval) async throws -> Data {
        unaryPayloads.append(payload)
        return unaryResponses[payload.operation] ?? Data()
    }

    func sendStreaming(
        _ payload: HermesRelayPayload,
        timeout: TimeInterval,
        onSSEEvent: @escaping @MainActor (String) -> Void
    ) async throws {
        streamingPayloads.append(payload)
        if let streamingError {
            throw streamingError
        }
        for event in streamingEvents {
            onSSEEvent(event)
        }
    }
}

private final class FakeHermesSecretStore: HermesConnectionSecretStoring {
    var values: [String: String] = [:]

    func save(_ value: String, connectionID: String) throws {
        values[connectionID] = value
    }

    func load(connectionID: String) throws -> String? {
        values[connectionID]
    }

    func delete(connectionID: String) throws {
        values.removeValue(forKey: connectionID)
    }
}

@MainActor
private final class FakeHermesConnectionRepository: HermesConnectionListing {
    private let connections: [HermesConnectionRecord]
    private let error: Error?
    private(set) var listCallCount = 0

    init(connections: [HermesConnectionRecord] = [], error: Error? = nil) {
        self.connections = connections
        self.error = error
    }

    func listHermesConnections() async throws -> [HermesConnectionRecord] {
        listCallCount += 1
        if let error {
            throw error
        }
        return connections
    }
}

private final class MockHermesURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
