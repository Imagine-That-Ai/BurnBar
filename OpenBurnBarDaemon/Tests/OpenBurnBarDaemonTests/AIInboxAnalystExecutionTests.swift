import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import XCTest

/// A routable provider setup for the analyst: a real config store and router
/// resolving a catalog model, with the wire call faked by
/// `FakeInboxProviderExecutor` (shared with the pipeline suite).
private enum AnalystExecutionSupport {
    struct Harness {
        let configStore: BurnBarConfigStore
        let router: BurnBarProviderRouter
    }

    /// Enables the Z.ai provider with a credential so `glm-5-turbo` routes,
    /// mirroring the known-good setup in `BurnBarProviderRouterTests`.
    static func makeHarness(name: String) async throws -> Harness {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-inbox-analyst-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let configStore = BurnBarConfigStore(
            fileURL: rootURL.appendingPathComponent("provider-config.json", isDirectory: false),
            catalog: BurnBarCatalogLoader.bundledCatalog,
            secretStore: BurnBarInMemorySecretStore(),
            logger: BurnBarDaemonLogger(category: "ai-inbox-analyst-tests")
        )
        try await configStore.setSecret("zai-key", for: "zai")
        _ = try await configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "zai",
                isEnabled: true,
                baseURL: "https://api.z.ai/api/coding/paas/v4",
                preferredModelIDs: ["glm-5-turbo"]
            )
        )

        return Harness(
            configStore: configStore,
            router: BurnBarProviderRouter(
                configStore: configStore,
                logger: BurnBarDaemonLogger(category: "ai-inbox-analyst-tests")
            )
        )
    }

    static func config(egressMode: BurnBarInboxEgressMode) -> BurnBarInboxConfig {
        BurnBarInboxConfig(
            enabled: true,
            egressMode: egressMode,
            analystProviderID: "zai",
            analystModel: "glm-5-turbo"
        )
    }

    /// A well-formed analyst response: one grounded finding, one fabricated
    /// finding (so the filtering path runs), and one grounded memory candidate.
    static let validResponse = """
        {
          "brief_md": "The auth middleware refactor kept moving.",
          "findings": [
            {
              "kind": "brief",
              "title": "Auth refactor restarted across sessions",
              "summary_md": "Two sessions attacked the same file from scratch.",
              "priority": 3,
              "confidence": 0.7,
              "evidence_ids": ["conv:conv-1:12"],
              "needs_verification": true
            },
            {
              "kind": "brief",
              "title": "A totally invented problem",
              "summary_md": "This cites nothing real.",
              "priority": 2,
              "confidence": 0.9,
              "evidence_ids": ["conv:ghost:1"]
            }
          ],
          "memory_candidates": [
            {
              "text": "The auth middleware is covered by contract tests before refactors.",
              "kind": "convention",
              "confidence": 0.8,
              "citation_conversation_ids": ["conv-1"]
            }
          ]
        }
        """
}

/// End-to-end behavior of `BurnBarAIInboxAnalyst.analyze`: routing, the egress
/// gate, the strict-JSON parse with one repair attempt, degradation to
/// detector-only output, and per-call accounting.
final class AIInboxAnalystExecutionTests: XCTestCase {
    func test_analyzeParsesValidatesAndAccountsForTheCall() async throws {
        let harness = try await AnalystExecutionSupport.makeHarness(name: "happy")
        let executor = FakeInboxProviderExecutor(responses: [AnalystExecutionSupport.validResponse])
        let analyst = BurnBarAIInboxAnalyst(
            executor: executor,
            router: harness.router,
            logger: BurnBarDaemonLogger(category: "test")
        )
        let now = Date()

        let result = try await analyst.analyze(
            pack: AIInboxFixtures.packWithConversation(),
            detectorFindings: [],
            config: AnalystExecutionSupport.config(egressMode: .cloud),
            now: now
        )

        XCTAssertEqual(result.briefMarkdown, "The auth middleware refactor kept moving.")
        XCTAssertEqual(result.findings.count, 1, "The fabricated finding must be filtered out")
        XCTAssertEqual(result.rejectedFindingCount, 1)
        XCTAssertEqual(result.rejectedMemoryCandidateCount, 0)

        let finding = try XCTUnwrap(result.findings.first)
        XCTAssertEqual(finding.kind, .brief)
        XCTAssertEqual(finding.source, .analyst)
        XCTAssertEqual(finding.evidenceIDs, ["conv:conv-1:12"])
        XCTAssertEqual(finding.memoryCandidates.count, 1, "The grounded memory rides on the surviving finding")

        // Exactly one wire call, priced and attributed to the resolved route.
        XCTAssertEqual(result.calls.count, 1)
        let call = try XCTUnwrap(result.calls.first)
        XCTAssertEqual(call.role, "analyst")
        XCTAssertEqual(call.providerID, "zai")
        XCTAssertEqual(call.modelID, "glm-5-turbo")
        XCTAssertEqual(call.inputTokens, 12_000)
        XCTAssertEqual(call.outputTokens, 800)
        XCTAssertEqual(call.provenance, "zai:glm-5-turbo")

        // The request that went over the wire carried the fixed system prompt
        // and demanded JSON-only output.
        let lastRequest = await executor.lastPrompt()
        let request = try XCTUnwrap(lastRequest)
        XCTAssertEqual(request.systemPrompt, BurnBarAIInboxPromptBuilder.analystSystemPrompt)
        XCTAssertTrue(request.jsonOnly)
        XCTAssertTrue(request.userPrompt.contains("# Valid evidence ids"))
    }

    func test_malformedFirstResponseTriggersOneRepairAttempt() async throws {
        let harness = try await AnalystExecutionSupport.makeHarness(name: "repair")
        let executor = FakeInboxProviderExecutor(responses: [
            "Sure! Here's my analysis in plain prose, no JSON.",
            AnalystExecutionSupport.validResponse
        ])
        let analyst = BurnBarAIInboxAnalyst(
            executor: executor,
            router: harness.router,
            logger: BurnBarDaemonLogger(category: "test")
        )

        let result = try await analyst.analyze(
            pack: AIInboxFixtures.packWithConversation(),
            detectorFindings: [],
            config: AnalystExecutionSupport.config(egressMode: .cloud),
            now: Date()
        )

        XCTAssertEqual(result.calls.count, 2, "Both attempts must be accounted for in the ledger")
        XCTAssertEqual(result.findings.count, 1, "The repaired response is used")

        let promptCount = await executor.promptCount()
        XCTAssertEqual(promptCount, 2)
        let lastRequest = await executor.lastPrompt()
        let secondRequest = try XCTUnwrap(lastRequest)
        XCTAssertTrue(
            secondRequest.userPrompt.contains("was not valid JSON"),
            "The retry must tell the model what went wrong"
        )
    }

    func test_persistentlyMalformedOutputDegradesToDetectorOnlyResult() async throws {
        let harness = try await AnalystExecutionSupport.makeHarness(name: "degrade")
        let executor = FakeInboxProviderExecutor(responses: ["no json here", "still no json"])
        let analyst = BurnBarAIInboxAnalyst(
            executor: executor,
            router: harness.router,
            logger: BurnBarDaemonLogger(category: "test")
        )

        let result = try await analyst.analyze(
            pack: AIInboxFixtures.packWithConversation(),
            detectorFindings: [],
            config: AnalystExecutionSupport.config(egressMode: .cloud),
            now: Date()
        )

        XCTAssertEqual(result.briefMarkdown, "", "Degrade, don't fail: the tick still publishes detectors")
        XCTAssertTrue(result.findings.isEmpty)
        XCTAssertEqual(result.rejectedFindingCount, 0)
        XCTAssertEqual(result.rejectedMemoryCandidateCount, 0)
        XCTAssertEqual(result.calls.count, 2, "Even wasted attempts cost money and must be recorded")
    }

    /// The privacy promise: `.local` must refuse a cloud route after routing
    /// resolves and before any byte is sent.
    func test_localEgressModeRefusesACloudRouteBeforeSendingAnything() async throws {
        let harness = try await AnalystExecutionSupport.makeHarness(name: "egress")
        let executor = FakeInboxProviderExecutor(responses: [AnalystExecutionSupport.validResponse])
        let analyst = BurnBarAIInboxAnalyst(
            executor: executor,
            router: harness.router,
            logger: BurnBarDaemonLogger(category: "test")
        )

        do {
            _ = try await analyst.analyze(
                pack: AIInboxFixtures.packWithConversation(),
                detectorFindings: [],
                config: AnalystExecutionSupport.config(egressMode: .local),
                now: Date()
            )
            XCTFail("A cloud route must be refused in local-only mode")
        } catch let error as BurnBarAIInboxAnalystError {
            guard case .egressRefused(let reason) = error else {
                return XCTFail("Expected egressRefused, got \(error)")
            }
            XCTAssertTrue(reason.contains("api.z.ai"), "The refusal names the offending host: \(reason)")
        }

        let calls = await executor.promptCount()
        XCTAssertEqual(calls, 0, "Not a single byte may reach the executor after a refusal")
    }
}
