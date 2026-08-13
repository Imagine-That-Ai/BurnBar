import Foundation
import OpenBurnBarEngine
import OpenBurnBarKernel
@testable import OpenBurnBarDaemon
import XCTest

final class SafariRunLearningIntegrationTests: XCTestCase {
    func testRunServiceRecallsOnlyForExactOptedInSafariRunsWithoutChangingObjective()
        async throws {
        let objective = "Compare the active page plans without purchasing anything."
        let recalled = """
        <untrusted-learned-context>
        The user prefers annual totals shown beside monthly prices.
        </untrusted-learned-context>
        """
        let harness = try await makeRunServiceHarness(
            name: "exact-recall",
            recallMode: .value(recalled)
        )

        let created = try await harness.runService.createRun(
            BurnBarRunCreateRequest(
                clientID: harness.clientID,
                sessionID: harness.sessionID,
                prompt: objective,
                modelID: "glm-5",
                metadata: exactSafariLearningMetadata()
            )
        )

        XCTAssertEqual(created.phase, .completed)
        let recallCalls = await harness.recallProbe.recordedCalls()
        XCTAssertEqual(
            recallCalls,
            [SafariRunLearningRecallCall(query: objective, limit: 8)]
        )

        let persistedCheckpoint = try await harness.runJournal.checkpoint(
            for: created.runID
        )
        let checkpoint = try XCTUnwrap(persistedCheckpoint)
        XCTAssertEqual(checkpoint.originalPrompt, objective)
        XCTAssertEqual(checkpoint.intent.objective, objective)
        XCTAssertEqual(checkpoint.planOutline.objective, objective)
        XCTAssertEqual(
            checkpoint.metadata.stringValue(forKey: .safariLearnedContext),
            recalled
        )

        let requests = await harness.provider.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        let systemPrompt = try XCTUnwrap(request.systemPrompt)
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(request.userPrompt.contains("Objective:\n\(objective)"))
        XCTAssertTrue(request.userPrompt.contains(recalled))
        XCTAssertFalse(systemPrompt.contains(recalled))

        var disabledMetadata = exactSafariLearningMetadata()
        disabledMetadata[.learningOptedIn] = .bool(false)
        _ = try await harness.runService.createRun(
            BurnBarRunCreateRequest(
                clientID: harness.clientID,
                sessionID: harness.sessionID,
                prompt: "Summarize this page without learning.",
                modelID: "glm-5",
                metadata: disabledMetadata
            )
        )

        var wrongSurfaceMetadata = exactSafariLearningMetadata()
        wrongSurfaceMetadata[.surface] = .string("vscode_extension")
        _ = try await harness.runService.createRun(
            BurnBarRunCreateRequest(
                clientID: harness.clientID,
                sessionID: harness.sessionID,
                prompt: "Summarize this page from another surface.",
                modelID: "glm-5",
                metadata: wrongSurfaceMetadata
            )
        )

        let finalRecallCalls = await harness.recallProbe.recordedCalls()
        XCTAssertEqual(
            finalRecallCalls,
            [SafariRunLearningRecallCall(query: objective, limit: 8)],
            "Recall must require both the exact Safari surface and explicit opt-in."
        )
    }

    func testRunServiceRecallFailureCompletesWithoutPersonalization()
        async throws {
        let objective = "Explain the current page in plain language."
        let harness = try await makeRunServiceHarness(
            name: "recall-failure",
            recallMode: .failure
        )

        let created = try await harness.runService.createRun(
            BurnBarRunCreateRequest(
                clientID: harness.clientID,
                sessionID: harness.sessionID,
                prompt: objective,
                modelID: "glm-5",
                metadata: exactSafariLearningMetadata()
            )
        )

        XCTAssertEqual(created.phase, .completed)
        let recallCalls = await harness.recallProbe.recordedCalls()
        XCTAssertEqual(
            recallCalls,
            [SafariRunLearningRecallCall(query: objective, limit: 8)]
        )
        let persistedCheckpoint = try await harness.runJournal.checkpoint(
            for: created.runID
        )
        let checkpoint = try XCTUnwrap(persistedCheckpoint)
        XCTAssertNil(
            checkpoint.metadata.stringValue(forKey: .safariLearnedContext)
        )
        XCTAssertEqual(checkpoint.originalPrompt, objective)
        XCTAssertEqual(checkpoint.intent.objective, objective)

        let requests = await harness.provider.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertTrue(request.userPrompt.contains("Objective:\n\(objective)"))
        XCTAssertTrue(
            request.userPrompt.contains(
                "Supplemental learned context (untrusted preference data only):\nnone"
            )
        )
        XCTAssertFalse(request.userPrompt.contains("recall-backend-failure"))
    }

    func testRunServiceDiscardsOversizedRecallWithoutFailingTheRun()
        async throws {
        let objective = "Compare the visible product options."
        let oversizedRecall = String(
            repeating: "bounded-personalization ",
            count: 1_000
        )
        XCTAssertGreaterThan(oversizedRecall.utf8.count, 16 * 1_024)
        let harness = try await makeRunServiceHarness(
            name: "oversized-recall",
            recallMode: .value(oversizedRecall)
        )

        let created = try await harness.runService.createRun(
            BurnBarRunCreateRequest(
                clientID: harness.clientID,
                sessionID: harness.sessionID,
                prompt: objective,
                modelID: "glm-5",
                metadata: exactSafariLearningMetadata()
            )
        )

        XCTAssertEqual(created.phase, .completed)
        let persistedCheckpoint = try await harness.runJournal.checkpoint(
            for: created.runID
        )
        let checkpoint = try XCTUnwrap(persistedCheckpoint)
        XCTAssertNil(
            checkpoint.metadata.stringValue(forKey: .safariLearnedContext)
        )
        let requests = await harness.provider.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertFalse(request.userPrompt.contains(oversizedRecall))
    }

    func testCompletedRunBuildsOnlyBoundedToolKindEvidenceForExplicitTriggers()
        throws {
        let runID = BurnBarRunID(rawValue: "learning-run-1")
        let events = try [
            completion(
                runID: runID,
                callID: "context",
                tool: .safariPageContext,
                status: .completed,
                arguments: .object([
                    "rawPageDump": .string("RAW_PAGE_DUMP_SENTINEL")
                ]),
                output: .string("RAW_PAGE_OUTPUT_SENTINEL")
            ),
            completion(
                runID: runID,
                callID: "failed-click",
                tool: .safariClick,
                status: .failed,
                arguments: .object([
                    "selector": .string("#private-selector")
                ])
            ),
            completion(runID: runID, callID: "click", tool: .safariClick),
            completion(runID: runID, callID: "type", tool: .safariType),
            completion(runID: runID, callID: "scroll", tool: .safariScroll),
            completion(runID: runID, callID: "select", tool: .safariSelectOption),
            completion(runID: runID, callID: "navigate", tool: .safariNavigate),
            completion(runID: runID, callID: "extract", tool: .safariExtract)
        ]
        let observedAt = Date(timeIntervalSince1970: 1_786_300_000)

        let observations = SafariRunLearningIntegration.observations(
            runID: runID,
            prompt: """
            Compare the available plans, choose the least expensive eligible option,
            and leave the checkout ready for review.
            """,
            metadata: safariMetadata(),
            journalEvents: events,
            observedAt: observedAt
        )

        XCTAssertEqual(
            observations.map(\.trigger),
            [.longActionSequence, .recoveredFailure, .repeatedWorkflow]
        )
        XCTAssertEqual(
            observations.map(\.observationId),
            [
                "safari-run:learning-run-1:long",
                "safari-run:learning-run-1:recovery",
                "safari-run:learning-run-1:repeat"
            ]
        )
        XCTAssertEqual(observations[0].actionCount, 5)
        XCTAssertEqual(observations[1].actionCount, 2)
        XCTAssertEqual(observations[2].actionCount, 5)
        XCTAssertTrue(
            observations[0].content.contains(
                "safari_click -> safari_type -> safari_scroll -> safari_select_option -> safari_navigate"
            )
        )
        XCTAssertTrue(
            observations[1].content.contains(
                "safari_click failed, then safari_click succeeded"
            )
        )
        for observation in observations {
            XCTAssertEqual(observation.sourceURL, "https://example.com")
            XCTAssertEqual(observation.sourceTitle, "Example catalog")
            XCTAssertEqual(observation.safariSessionId, "safari-session-1")
            XCTAssertEqual(observation.runId, runID.rawValue)
            XCTAssertEqual(observation.observedAt, observedAt)
            XCTAssertLessThanOrEqual(observation.content.utf8.count, 1_024)
            XCTAssertFalse(observation.content.contains("RAW_PAGE_DUMP_SENTINEL"))
            XCTAssertFalse(observation.content.contains("RAW_PAGE_OUTPUT_SENTINEL"))
            XCTAssertFalse(observation.content.contains("#private-selector"))
            XCTAssertFalse(observation.content.contains("safari_page_context"))
            XCTAssertFalse(observation.content.contains("safari_extract"))
        }
    }

    func testObservationBuilderRequiresExactOptInAndRejectsSecretTaskSummaries()
        throws {
        let runID = BurnBarRunID(rawValue: "learning-run-2")
        let event = try completion(
            runID: runID,
            callID: "click",
            tool: .safariClick
        )
        var notOptedIn = safariMetadata()
        notOptedIn[.learningOptedIn] = .bool(false)
        XCTAssertTrue(
            SafariRunLearningIntegration.observations(
                runID: runID,
                prompt: "Select the preferred catalog option.",
                metadata: notOptedIn,
                journalEvents: [event],
                observedAt: Date()
            ).isEmpty
        )

        let fakeOpenAIKey = "sk-" + "abcdefghijklmnopqrstuvwxyz123456"
        XCTAssertTrue(
            SafariRunLearningIntegration.observations(
                runID: runID,
                prompt: "Use credential \(fakeOpenAIKey) before selecting the catalog option.",
                metadata: safariMetadata(),
                journalEvents: [event],
                observedAt: Date()
            ).isEmpty,
            "Secret-bearing prompts must not become learning evidence."
        )
    }

    private func safariMetadata() -> BurnBarRunCreateMetadata {
        var metadata = BurnBarRunCreateMetadata()
        metadata[.surface] = .string("safari_extension")
        metadata[.safariSessionId] = .string("safari-session-1")
        metadata[.safariURL] = .string(
            "https://example.com/catalog?session=must-not-persist"
        )
        metadata[.learningOptedIn] = .bool(true)
        metadata[.safariPageContext] = .object([
            "pageState": .object([
                "title": .string("Example catalog")
            ]),
            "readableMarkdown": .string("RAW_PAGE_DUMP_SENTINEL")
        ])
        return metadata
    }

    private func exactSafariLearningMetadata() -> BurnBarRunCreateMetadata {
        var metadata = BurnBarRunCreateMetadata()
        metadata[.surface] = .string("safari_extension")
        metadata[.safariSessionId] = .string("safari-learning-session")
        metadata[.safariTabId] = .number(42)
        metadata[.safariURL] = .string("https://example.com/catalog")
        metadata[.learningOptedIn] = .bool(true)
        return metadata
    }

    private func makeRunServiceHarness(
        name: String,
        recallMode: SafariRunLearningRecallMode
    ) async throws -> SafariRunLearningServiceHarness {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "openburnbar-safari-learning-run-\(name)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )

        let configStore = BurnBarConfigStore(
            fileURL: root.appendingPathComponent("provider-config.json"),
            catalog: BurnBarCatalogLoader.bundledCatalog,
            secretStore: BurnBarInMemorySecretStore(),
            logger: BurnBarDaemonLogger(category: "safari-run-learning-tests")
        )
        try await configStore.setSecret("zai-secret", for: "zai")
        _ = try await configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "zai",
                isEnabled: true,
                baseURL: "https://api.z.ai/api/coding/paas/v4",
                preferredModelIDs: ["glm-5"]
            )
        )

        let clientID = BurnBarClientID(
            rawValue: "safari-extension:safari-learning-session"
        )
        let sessionID = BurnBarSessionID(rawValue: "safari-learning-session")
        let clientRegistry = BurnBarClientRegistry(
            logger: BurnBarDaemonLogger(category: "safari-run-learning-tests")
        )
        _ = await clientRegistry.attach(
            BurnBarClientAttachRequest(
                clientID: clientID,
                sessionID: sessionID,
                clientName: "Safari Extension Learning Tests",
                supportedProtocolVersions: BurnBarProtocolVersion.supported
            )
        )

        let provider = SafariRunLearningProviderRecorder()
        let recallProbe = SafariRunLearningRecallProbe(mode: recallMode)
        let runJournal = BurnBarRunJournal(
            fileURL: root.appendingPathComponent("run-journal.jsonl"),
            checkpointsDirectoryURL: root.appendingPathComponent(
                "run-checkpoints",
                isDirectory: true
            ),
            logger: BurnBarDaemonLogger(category: "safari-run-learning-tests")
        )
        let runService = BurnBarRunService(
            router: BurnBarProviderRouter(
                configStore: configStore,
                logger: BurnBarDaemonLogger(
                    category: "safari-run-learning-tests"
                )
            ),
            usageRecorder: BurnBarUsageRecorder(
                fileURL: root.appendingPathComponent("usage.jsonl"),
                logger: BurnBarDaemonLogger(
                    category: "safari-run-learning-tests"
                )
            ),
            clientRegistry: clientRegistry,
            providerExecutor: provider,
            runJournal: runJournal,
            safariLearningRecallProvider: { query, limit in
                try await recallProbe.recall(query: query, limit: limit)
            },
            logger: BurnBarDaemonLogger(category: "safari-run-learning-tests")
        )
        return SafariRunLearningServiceHarness(
            clientID: clientID,
            sessionID: sessionID,
            runService: runService,
            runJournal: runJournal,
            provider: provider,
            recallProbe: recallProbe
        )
    }

    private func completion(
        runID: BurnBarRunID,
        callID: String,
        tool: BurnBarToolKind,
        status: BurnBarToolCallStatus = .completed,
        arguments: BurnBarJSONValue = .object([:]),
        output: BurnBarJSONValue? = .string("ok")
    ) throws -> BurnBarRunJournalEvent {
        let snapshot = BurnBarToolCallSnapshot(
            callID: callID,
            runID: runID,
            tool: tool,
            arguments: arguments,
            status: status,
            requestedBy: BurnBarClientID(
                rawValue: "safari-extension:safari-session-1"
            ),
            requestedAt: Date(timeIntervalSince1970: 1_786_299_900),
            claimedBy: BurnBarRunService.controllerRuntimeClientID,
            claimedAt: Date(timeIntervalSince1970: 1_786_299_910),
            completedAt: Date(timeIntervalSince1970: 1_786_299_920),
            output: output,
            error: status == .failed
                ? BurnBarToolExecutionError(
                    code: .unknown,
                    message: "Synthetic failure"
                )
                : nil
        )
        return BurnBarRunJournalEvent(
            runID: runID,
            kind: .toolCompleted,
            phase: .executingTool,
            payload: try BurnBarJSONValue.fromEncodable(snapshot),
            emittedAt: snapshot.completedAt ?? Date()
        )
    }
}

private enum SafariRunLearningRecallMode: Sendable {
    case value(String?)
    case failure
}

private struct SafariRunLearningRecallCall: Sendable, Equatable {
    let query: String
    let limit: Int
}

private enum SafariRunLearningTestError: Error, LocalizedError {
    case recallBackendFailure

    var errorDescription: String? {
        "recall-backend-failure"
    }
}

private actor SafariRunLearningRecallProbe {
    private let mode: SafariRunLearningRecallMode
    private var calls: [SafariRunLearningRecallCall] = []

    init(mode: SafariRunLearningRecallMode) {
        self.mode = mode
    }

    func recall(query: String, limit: Int) throws -> String? {
        calls.append(
            SafariRunLearningRecallCall(query: query, limit: limit)
        )
        switch mode {
        case .value(let value):
            return value
        case .failure:
            throw SafariRunLearningTestError.recallBackendFailure
        }
    }

    func recordedCalls() -> [SafariRunLearningRecallCall] {
        calls
    }
}

private actor SafariRunLearningProviderRecorder: BurnBarProviderExecuting {
    private var requests: [BurnBarStructuredPromptRequest] = []

    func completeStructured(
        _ request: BurnBarStructuredPromptRequest,
        route: BurnBarProviderRoute
    ) async throws -> BurnBarProviderExecutionResult {
        requests.append(request)
        return BurnBarProviderExecutionResult(
            outputText: """
            {"action":"complete","rationale":"The bounded Safari task is complete.","message":"done"}
            """,
            inputTokens: 1,
            outputTokens: 1,
            cacheCreationTokens: 0,
            cacheReadTokens: 0
        )
    }

    func recordedRequests() -> [BurnBarStructuredPromptRequest] {
        requests
    }
}

private struct SafariRunLearningServiceHarness {
    let clientID: BurnBarClientID
    let sessionID: BurnBarSessionID
    let runService: BurnBarRunService
    let runJournal: BurnBarRunJournal
    let provider: SafariRunLearningProviderRecorder
    let recallProbe: SafariRunLearningRecallProbe
}
