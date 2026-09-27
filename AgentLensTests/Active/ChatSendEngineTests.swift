import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

/// `ChatSendEngine` / `ChatUsageTracker` extraction tests.
///
/// The engine test class is deliberately NOT `@MainActor`: the engine API must
/// be usable (and run its reduction) off the main thread. The controller-level
/// callback contract stays pinned by `ChatStreamingMessageMutationTests`.
final class ChatSendEngineTests: XCTestCase {

    private enum StreamTestError: Error {
        case interrupted
    }

    private func collect(
        _ stream: AsyncThrowingStream<CLIChatStreamEvent, Error>,
        commitInterval: Duration = .seconds(3600)
    ) async throws -> (commits: [(String, [ChatTranscriptPiece])], structural: [CLIChatStreamEvent], terminal: ChatStreamConsumptionResult?) {
        var commits: [(String, [ChatTranscriptPiece])] = []
        var structural: [CLIChatStreamEvent] = []
        var terminal: ChatStreamConsumptionResult?
        let events = ChatSendEngine.shared.consume(stream, commitInterval: commitInterval)
        for try await event in events {
            switch event {
            case .transcriptCommitted(let content, let pieces):
                commits.append((content, pieces))
            case .structural(let upstream):
                structural.append(upstream)
            case .finished(let result):
                terminal = result
            case .routingFailed, .retrievalCompleted, .oracleSettledLocally, .streamDispatch, .sendStopped:
                XCTFail("consume() must never emit orchestration events")
            }
        }
        return (commits, structural, terminal)
    }

    func testConsume_batchesText_andKeepsNewestUsageSnapshot() async throws {
        let stream = AsyncThrowingStream<CLIChatStreamEvent, Error> { continuation in
            continuation.yield(.text("Hello"))
            continuation.yield(.text(" world"))
            continuation.yield(.reasoning("private"))
            continuation.yield(.refusal("no"))
            continuation.yield(.toolUse(name: "Read", detail: "file.swift"))
            continuation.yield(.toolResult(name: "Read", detail: "ok"))
            continuation.yield(.usage(CLIUsageSnapshot(
                inputTokens: 1,
                outputTokens: 2,
                cacheCreationTokens: 0,
                cacheReadTokens: 0,
                reasoningTokens: 0
            )))
            continuation.yield(.usage(CLIUsageSnapshot(
                inputTokens: 10,
                outputTokens: 20,
                cacheCreationTokens: 0,
                cacheReadTokens: 0,
                reasoningTokens: 0
            )))
            continuation.finish()
        }

        let collected = try await collect(stream)
        let result = try XCTUnwrap(collected.terminal, "engine must yield a terminal .finished event")

        XCTAssertEqual(result.joinedText, "Hello world")
        XCTAssertEqual(result.pieces.map(\.kind), [.text, .reasoning, .refusal, .toolUse, .toolResult])
        XCTAssertEqual(result.pieces[0].value, "Hello world")
        XCTAssertEqual(result.pieces[1].value, "private")
        XCTAssertEqual(result.usageSnapshot?.totalTokens, 30)
        XCTAssertEqual(collected.structural.count, 2)
        XCTAssertEqual(collected.commits.last?.0, "Hello world")
        XCTAssertLessThanOrEqual(collected.commits.count, 4, "usage events must not trigger transcript commits")
    }

    func testConsume_flushesPartialText_beforeRethrowing() async {
        let stream = AsyncThrowingStream<CLIChatStreamEvent, Error> { continuation in
            continuation.yield(.text("partial"))
            continuation.yield(.reasoning("thinking"))
            continuation.finish(throwing: StreamTestError.interrupted)
        }
        var commits: [(String, [ChatTranscriptPiece])] = []

        do {
            let events = ChatSendEngine.shared.consume(stream, commitInterval: .seconds(3600))
            for try await event in events {
                if case .transcriptCommitted(let content, let pieces) = event {
                    commits.append((content, pieces))
                }
            }
            XCTFail("expected the stream error")
        } catch StreamTestError.interrupted {
            XCTAssertEqual(commits.last?.0, "partial")
            XCTAssertEqual(commits.last?.1.map(\.value), ["partial", "thinking"])
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// A chunk throttled inside the commit interval must still reach the
    /// transcript on the trailing edge, even though the reduction runs off the
    /// main actor.
    func testConsume_flushesThrottledChunk_whileTheStreamIsPaused() async throws {
        let pause = Duration.milliseconds(500)
        let interval = Duration.milliseconds(50)
        let stream = AsyncThrowingStream<CLIChatStreamEvent, Error> { continuation in
            continuation.yield(.text("A"))
            continuation.yield(.text("B"))
            Task {
                try? await Task.sleep(for: pause)
                continuation.finish()
            }
        }
        let started = ContinuousClock.now
        var commits: [String] = []
        var offsets: [Duration] = []
        var terminal: ChatStreamConsumptionResult?

        let events = ChatSendEngine.shared.consume(stream, commitInterval: interval)
        for try await event in events {
            switch event {
            case .transcriptCommitted(let content, _):
                commits.append(content)
                offsets.append(ContinuousClock.now - started)
            case .finished(let result):
                terminal = result
            case .structural:
                break
            case .routingFailed, .retrievalCompleted, .oracleSettledLocally, .streamDispatch, .sendStopped:
                XCTFail("consume() must never emit orchestration events")
            }
        }

        XCTAssertEqual(try XCTUnwrap(terminal).joinedText, "AB")
        XCTAssertEqual(
            commits,
            ["A", "AB", "AB"],
            "expected the first delta, a trailing flush, then the terminal flush"
        )
        let trailingOffset = try XCTUnwrap(offsets.dropFirst().first, "no trailing flush was committed")
        XCTAssertLessThan(
            trailingOffset,
            pause / 2,
            "the staged chunk must land within the commit interval, not at stream termination"
        )
    }

    func testConsume_terminalFlushCancelsThePendingTrailingCommit() async throws {
        let stream = AsyncThrowingStream<CLIChatStreamEvent, Error> { continuation in
            continuation.yield(.text("A"))
            continuation.yield(.text("B")) // throttled → arms a trailing flush
            continuation.finish()          // …which termination must cancel
        }
        var commits: [String] = []

        let events = ChatSendEngine.shared.consume(stream, commitInterval: .milliseconds(50))
        for try await event in events {
            if case .transcriptCommitted(let content, _) = event {
                commits.append(content)
            }
        }

        XCTAssertEqual(commits, ["A", "AB"])
        try await Task.sleep(for: .milliseconds(200)) // 4x the interval
        XCTAssertEqual(commits, ["A", "AB"], "a trailing flush fired after the stream settled")
    }

    /// The engine must be drivable from a fully detached background task —
    /// no main-actor hop required to consume a stream.
    func testConsume_runsFromDetachedBackgroundTask() async throws {
        let terminal = try await Task.detached {
            XCTAssertFalse(Thread.isMainThread, "precondition: detached task must run off the main thread")
            let stream = AsyncThrowingStream<CLIChatStreamEvent, Error> { continuation in
                continuation.yield(.text("off-"))
                continuation.yield(.text("main"))
                continuation.yield(.sessionID("fx-session-1"))
                continuation.finish()
            }
            var commits: [String] = []
            var sessionIDs: [String] = []
            var terminal: ChatStreamConsumptionResult?
            let engine = ChatSendEngine()
            for try await event in engine.consume(stream) {
                switch event {
                case .transcriptCommitted(let content, _):
                    commits.append(content)
                case .structural(.sessionID(let id)):
                    sessionIDs.append(id)
                case .structural:
                    break
                case .finished(let result):
                    terminal = result
                case .routingFailed, .retrievalCompleted, .oracleSettledLocally, .streamDispatch, .sendStopped:
                    XCTFail("consume() must never emit orchestration events")
                }
            }
            return (commits, sessionIDs, terminal)
        }.value

        XCTAssertEqual(terminal.0.last, "off-main")
        XCTAssertEqual(terminal.1, ["fx-session-1"])
        XCTAssertEqual(try XCTUnwrap(terminal.2).joinedText, "off-main")
    }

    func testConsume_emptyStream_finishesWithEmptyResult() async throws {
        let stream = AsyncThrowingStream<CLIChatStreamEvent, Error> { continuation in
            continuation.finish()
        }

        let collected = try await collect(stream)
        let result = try XCTUnwrap(collected.terminal)
        XCTAssertEqual(result.joinedText, "")
        XCTAssertTrue(result.pieces.isEmpty)
        XCTAssertNil(result.usageSnapshot)
        XCTAssertEqual(collected.commits.count, 1, "terminal flush still commits once")
    }

    // MARK: - Moved pure helpers

    func testRetrievalQueryText_shortAffirmationCombinesPriorTurn() {
        let messages = [
            ChatMessageRecord(role: .user, content: "find my api key thread"),
            ChatMessageRecord(role: .assistant, content: "looking…")
        ]
        XCTAssertEqual(
            ChatSendEngine.retrievalQueryText(for: "yes please", messages: messages),
            "find my api key thread yes please"
        )
        XCTAssertEqual(
            ChatSendEngine.retrievalQueryText(for: "a brand new question", messages: messages),
            "a brand new question"
        )
        XCTAssertTrue(ChatSendEngine.isShortAffirmation("go ahead"))
        XCTAssertFalse(ChatSendEngine.isShortAffirmation("please write a long essay about.badgers"))
    }

    func testBurnBarWorkspacePromptSection_pinsWorkspaceRoot() {
        let section = ChatSendEngine.burnBarWorkspacePromptSection(path: "/tmp/ws")
        XCTAssertTrue(section.contains("## OpenBurnBar workspace (required)"))
        XCTAssertTrue(section.contains("/tmp/ws"))
    }

    // MARK: - Controller forwards preserve the public API shape

    @MainActor
    func testControllerForwards_matchEngineHelpers() {
        let messages = [
            ChatMessageRecord(role: .user, content: "find my api key thread"),
            ChatMessageRecord(role: .assistant, content: "looking…")
        ]
        XCTAssertEqual(
            ChatSessionController.retrievalQueryText(for: "yes please", messages: messages),
            ChatSendEngine.retrievalQueryText(for: "yes please", messages: messages)
        )
        XCTAssertEqual(
            ChatSessionController.burnBarWorkspacePromptSection(path: "/tmp/ws"),
            ChatSendEngine.burnBarWorkspacePromptSection(path: "/tmp/ws")
        )
        var viaController: [ChatTranscriptPiece] = []
        var viaPiece: [ChatTranscriptPiece] = []
        ChatSessionController.appendStreamingText("hi", to: &viaController)
        ChatTranscriptPiece.appendStreamingText("hi", to: &viaPiece)
        XCTAssertEqual(viaController.map(\.kind), viaPiece.map(\.kind))
        XCTAssertEqual(viaController.map(\.value), viaPiece.map(\.value))
    }
}

/// `ChatUsageTracker` ledger tests. `@MainActor` because the injected
/// dependencies capture the `@MainActor` `DataStore` facade.
@MainActor
final class ChatUsageTrackerTests: XCTestCase {
    private func makeTracker(dataStore: DataStore) -> ChatUsageTracker {
        ChatUsageTracker(dependencies: .init(
            insertUsage: { usage in try await dataStore.insert(usage) },
            reloadUsages: { await dataStore.reloadUsagesIfChanged() }
        ))
    }

    func testSaveUsageIfNeeded_pricesAndPersistsAllTokenBuckets() async throws {
        let dataStore = try makeDiscoveryInMemoryStore()
        let tracker = makeTracker(dataStore: dataStore)

        await tracker.saveUsageIfNeeded(
            CLIUsageSnapshot(
                inputTokens: 1_000_000,
                outputTokens: 1_000_000,
                cacheCreationTokens: 1_000_000,
                cacheReadTokens: 1_000_000,
                reasoningTokens: 1_000_000
            ),
            backend: .hermes,
            requestModel: "gpt-4o",
            modelNames: ChatUsageTracker.ModelNames(),
            threadID: "pricing-thread",
            responseMessageID: "response-1",
            startedAt: Date(timeIntervalSince1970: 1_752_499_200),
            endedAt: Date(timeIntervalSince1970: 1_752_499_201)
        )

        let persisted = try await dataStore.fetchAllUsage()
        XCTAssertEqual(persisted.count, 1)
        let usage = try XCTUnwrap(persisted.first)
        XCTAssertEqual(usage.provider, .hermes)
        XCTAssertEqual(usage.sessionId, "pricing-thread/response-1")
        XCTAssertEqual(usage.model, "gpt-4o")
        XCTAssertEqual(usage.inputTokens, 1_000_000)
        XCTAssertEqual(usage.outputTokens, 1_000_000)
        XCTAssertEqual(usage.cacheCreationTokens, 1_000_000)
        XCTAssertEqual(usage.cacheReadTokens, 1_000_000)
        XCTAssertEqual(usage.reasoningTokens, 1_000_000)
        XCTAssertEqual(usage.costUSD, 16.25, accuracy: 0.000_001)
        XCTAssertEqual(usage.usageSource, .inAppChat)
        XCTAssertEqual(usage.provenanceMethod, .inAppChat)
    }

    func testSaveUsageIfNeeded_codexUsesStoredModelSelection() async throws {
        let dataStore = try makeDiscoveryInMemoryStore()
        let tracker = makeTracker(dataStore: dataStore)

        await tracker.saveUsageIfNeeded(
            CLIUsageSnapshot(inputTokens: 10, outputTokens: 5, cacheCreationTokens: 0, cacheReadTokens: 0, reasoningTokens: 0),
            backend: .codex,
            requestModel: "normalized-codex-model",
            modelNames: ChatUsageTracker.ModelNames(codex: "gpt-5.2-codex"),
            threadID: "t",
            responseMessageID: "r",
            startedAt: Date(),
            endedAt: Date()
        )

        let persisted = try await dataStore.fetchAllUsage()
        let usage = try XCTUnwrap(persisted.first)
        XCTAssertEqual(usage.provider, .codex)
        XCTAssertEqual(usage.model, "gpt-5.2-codex")
        XCTAssertEqual(usage.projectName, "OpenBurnBar Codex Chat")
    }

    func testSaveUsageIfNeeded_grokHonoursRequestModel() async throws {
        let dataStore = try makeDiscoveryInMemoryStore()
        let tracker = makeTracker(dataStore: dataStore)

        await tracker.saveUsageIfNeeded(
            CLIUsageSnapshot(inputTokens: 10, outputTokens: 5, cacheCreationTokens: 0, cacheReadTokens: 0, reasoningTokens: 0),
            backend: .grok,
            requestModel: "grok-4",
            modelNames: ChatUsageTracker.ModelNames(),
            threadID: "t",
            responseMessageID: "r",
            startedAt: Date(),
            endedAt: Date()
        )

        let persisted = try await dataStore.fetchAllUsage()
        let usage = try XCTUnwrap(persisted.first)
        XCTAssertEqual(usage.provider, .xAI)
        XCTAssertEqual(usage.model, "grok-4")
    }

    func testSaveUsageIfNeeded_nilSnapshotPersistsNothing() async throws {
        let dataStore = try makeDiscoveryInMemoryStore()
        let tracker = makeTracker(dataStore: dataStore)

        await tracker.saveUsageIfNeeded(
            nil,
            backend: .hermes,
            requestModel: "gpt-4o",
            modelNames: ChatUsageTracker.ModelNames(),
            threadID: "t",
            responseMessageID: "r",
            startedAt: Date(),
            endedAt: Date()
        )

        let persisted = try await dataStore.fetchAllUsage()
        XCTAssertTrue(persisted.isEmpty)
    }

    func testControllerSaveUsageIfNeeded_delegatesToTracker() async throws {
        let dataStore = try makeDiscoveryInMemoryStore()
        let controller = ChatSessionController(
            dataStore: dataStore,
            searchService: ControlledChatSessionSearchProvider(responses: [:]),
            initialThreadID: "pricing-thread",
            persistsViewState: false
        )

        await controller.saveUsageIfNeeded(
            CLIUsageSnapshot(
                inputTokens: 1_000_000,
                outputTokens: 1_000_000,
                cacheCreationTokens: 1_000_000,
                cacheReadTokens: 1_000_000,
                reasoningTokens: 1_000_000
            ),
            backend: .hermes,
            requestModel: "gpt-4o",
            responseMessageID: "response-1",
            startedAt: Date(timeIntervalSince1970: 1_752_499_200),
            endedAt: Date(timeIntervalSince1970: 1_752_499_201)
        )

        let persisted = try await dataStore.fetchAllUsage()
        let usage = try XCTUnwrap(persisted.first)
        XCTAssertEqual(usage.provider, .hermes)
        XCTAssertEqual(usage.sessionId, "pricing-thread/response-1")
        XCTAssertEqual(usage.model, "gpt-4o")
        XCTAssertEqual(usage.costUSD, 16.25, accuracy: 0.000_001)
    }
}

/// `execute(request:pipeline:)` orchestration tests.
///
/// Pipeline phases are stubbed with scripted `@MainActor` closures over the
/// same seam the controller uses, so phase order, early exits, event
/// sequence, and flush-before-rethrow pin down without booting a CLI,
/// gateway, or database.
@MainActor
final class ChatSendExecuteTests: XCTestCase {
    private enum ExecuteTestError: Error {
        case interrupted
    }

    /// Sendable call recorder for asserting phase order across the engine hop.
    private actor PhaseLog {
        private(set) var calls: [String] = []
        func record(_ name: String) { calls.append(name) }
    }

    private static func stubRetrieval(
        trimmed: String = "hello",
        localOracleMessage: String? = nil
    ) -> ChatSendRetrieval {
        ChatSendRetrieval(
            trimmed: trimmed,
            promptHistory: [ChatMessageRecord(role: .user, content: trimmed)],
            assistantId: "assistant-1",
            streamStartedAt: Date(timeIntervalSince1970: 1_700_000_000),
            searchService: nil,
            retrievalResults: [],
            queryRun: OpenBurnBarQueryRunResult(
                plan: BurnBarSearchPlan.plan(userText: trimmed),
                retrievalResults: [],
                aggregateOccurrenceCount: nil,
                aggregateWindowDescription: nil
            ),
            oracleContextSection: "",
            jumpTargets: [],
            hadNoEvidence: true,
            localOracleMessage: localOracleMessage
        )
    }

    private static func textStream(
        _ chunks: String...,
        error: Error? = nil
    ) -> AsyncThrowingStream<CLIChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            for chunk in chunks {
                continuation.yield(.text(chunk))
            }
            if let error {
                continuation.finish(throwing: error)
            } else {
                continuation.finish()
            }
        }
    }

    private func collect(
        _ pipeline: ChatSendPipeline,
        trimmed: String = "hello"
    ) async throws -> [ChatSendEvent] {
        var events: [ChatSendEvent] = []
        for try await event in ChatSendEngine.shared.execute(
            request: ChatSendRequest(trimmed: trimmed, commitInterval: .seconds(3600)),
            pipeline: pipeline
        ) {
            events.append(event)
        }
        return events
    }

    private static func tag(_ event: ChatSendEvent) -> String {
        switch event {
        case .transcriptCommitted: return "commit"
        case .structural: return "structural"
        case .finished: return "finished"
        case .routingFailed: return "routingFailed"
        case .retrievalCompleted: return "retrievalCompleted"
        case .oracleSettledLocally: return "oracleSettledLocally"
        case .streamDispatch: return "streamDispatch"
        case .sendStopped: return "sendStopped"
        }
    }

    func testExecute_happyPath_runsPhasesInOrder_andStreamsTranscript() async throws {
        let log = PhaseLog()
        let retrieval = Self.stubRetrieval()
        let pipeline = ChatSendPipeline(
            checkRouting: {
                await log.record("routing")
                return .proceed
            },
            runRetrieval: { request in
                await log.record("retrieval")
                XCTAssertEqual(request.trimmed, "hello")
                return retrieval
            },
            openStream: { outcome in
                await log.record("open")
                XCTAssertEqual(outcome.assistantId, "assistant-1")
                return ChatSendOpenedStream(
                    stream: Self.textStream("Hello", " world"),
                    requestModel: "stub-model",
                    didRouteThroughFusion: true
                )
            }
        )

        let events = try await collect(pipeline)

        let calls = await log.calls
        XCTAssertEqual(calls, ["routing", "retrieval", "open"])
        XCTAssertEqual(events.map(Self.tag), [
            "retrievalCompleted", "streamDispatch", "commit", "commit", "finished"
        ])
        guard events.count > 1, case .streamDispatch(let assistantId, _, let requestModel, let fusionRouted) = events[1] else {
            XCTFail("expected .streamDispatch second, got \(events.map(Self.tag))")
            return
        }
        XCTAssertEqual(assistantId, "assistant-1")
        XCTAssertEqual(requestModel, "stub-model")
        XCTAssertTrue(fusionRouted)
        guard case .finished(let result) = events.last else {
            XCTFail("expected terminal .finished")
            return
        }
        XCTAssertEqual(result.joinedText, "Hello world")
    }

    func testExecute_routingFailed_emitsTerminalEvent_withoutLaterPhases() async throws {
        let log = PhaseLog()
        let pipeline = ChatSendPipeline(
            checkRouting: {
                await log.record("routing")
                return .failed(message: "gateway down")
            },
            runRetrieval: { _ in
                await log.record("retrieval")
                return Self.stubRetrieval()
            },
            openStream: { _ in
                await log.record("open")
                return nil
            }
        )

        let events = try await collect(pipeline)

        let calls = await log.calls
        XCTAssertEqual(calls, ["routing"])
        XCTAssertEqual(events.count, 1)
        guard case .routingFailed(let message) = events.first else {
            XCTFail("expected .routingFailed, got \(events.map(Self.tag))")
            return
        }
        XCTAssertEqual(message, "gateway down")
    }

    func testExecute_routingStopped_finishesSilent() async throws {
        let log = PhaseLog()
        let pipeline = ChatSendPipeline(
            checkRouting: {
                await log.record("routing")
                return .stopped
            },
            runRetrieval: { _ in
                await log.record("retrieval")
                return Self.stubRetrieval()
            },
            openStream: { _ in
                await log.record("open")
                return nil
            }
        )

        let events = try await collect(pipeline)

        let calls = await log.calls
        XCTAssertEqual(calls, ["routing"])
        XCTAssertEqual(events.map(Self.tag), ["sendStopped"])
    }

    func testExecute_nilRetrieval_stopsBeforeOpeningStream() async throws {
        let log = PhaseLog()
        let pipeline = ChatSendPipeline(
            checkRouting: {
                await log.record("routing")
                return .proceed
            },
            runRetrieval: { _ in
                await log.record("retrieval")
                return nil
            },
            openStream: { _ in
                await log.record("open")
                return nil
            }
        )

        let events = try await collect(pipeline)

        let calls = await log.calls
        XCTAssertEqual(calls, ["routing", "retrieval"])
        XCTAssertEqual(events.map(Self.tag), ["sendStopped"])
    }

    func testExecute_localOracle_settlesWithoutOpeningStream() async throws {
        let log = PhaseLog()
        let retrieval = Self.stubRetrieval(localOracleMessage: "indexed answer")
        let pipeline = ChatSendPipeline(
            checkRouting: {
                await log.record("routing")
                return .proceed
            },
            runRetrieval: { _ in
                await log.record("retrieval")
                return retrieval
            },
            openStream: { _ in
                await log.record("open")
                return nil
            }
        )

        let events = try await collect(pipeline)

        let calls = await log.calls
        XCTAssertEqual(calls, ["routing", "retrieval"])
        XCTAssertEqual(events.map(Self.tag), ["retrievalCompleted", "oracleSettledLocally"])
        guard case .oracleSettledLocally(let assistantId, let content, _) = events.last else {
            XCTFail("expected terminal .oracleSettledLocally")
            return
        }
        XCTAssertEqual(assistantId, "assistant-1")
        XCTAssertEqual(content, "indexed answer")
    }

    func testExecute_nilOpenStream_stopsSilently() async throws {
        let log = PhaseLog()
        let retrieval = Self.stubRetrieval()
        let pipeline = ChatSendPipeline(
            checkRouting: {
                await log.record("routing")
                return .proceed
            },
            runRetrieval: { _ in
                await log.record("retrieval")
                return retrieval
            },
            openStream: { _ in
                await log.record("open")
                return nil
            }
        )

        let events = try await collect(pipeline)

        let calls = await log.calls
        XCTAssertEqual(calls, ["routing", "retrieval", "open"])
        XCTAssertEqual(events.map(Self.tag), ["retrievalCompleted", "sendStopped"])
    }

    func testExecute_streamError_flushesPartialText_beforeRethrowing() async throws {
        let retrieval = Self.stubRetrieval()
        let pipeline = ChatSendPipeline(
            checkRouting: { .proceed },
            runRetrieval: { _ in retrieval },
            openStream: { _ in
                ChatSendOpenedStream(
                    stream: Self.textStream("partial", error: ExecuteTestError.interrupted),
                    requestModel: "stub-model",
                    didRouteThroughFusion: false
                )
            }
        )

        var commits: [String] = []
        var sawDispatch = false
        do {
            for try await event in ChatSendEngine.shared.execute(
                request: ChatSendRequest(trimmed: "hello", commitInterval: .seconds(3600)),
                pipeline: pipeline
            ) {
                switch event {
                case .transcriptCommitted(let content, _):
                    commits.append(content)
                case .streamDispatch:
                    sawDispatch = true
                default:
                    break
                }
            }
            XCTFail("expected the stream error")
        } catch ExecuteTestError.interrupted {
            XCTAssertTrue(sawDispatch, "dispatch must precede consumption")
            XCTAssertEqual(commits.last, "partial")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
