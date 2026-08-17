import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import XCTest

/// Decoding, validation, and accounting helpers of the analyst: surviving
/// memory candidates, fingerprint dedupe against detector findings, actions
/// derived from citations, per-call cost accounting, the JSON repair prompt,
/// and the error surface.
final class AIInboxAnalystParsingTests: XCTestCase {
    // MARK: - Decode failures

    func test_decodeThrowsInvalidJSONForGarbageOutput() {
        XCTAssertThrowsError(try BurnBarAIInboxAnalyst.decode("the model rambled instead of answering")) { error in
            guard let analystError = error as? BurnBarAIInboxAnalystError,
                  case .invalidJSON = analystError else {
                return XCTFail("Expected invalidJSON, got \(error)")
            }
        }
    }

    func test_decodeToleratesAnEmptyObjectAndValidateReturnsNothing() throws {
        let payload = try BurnBarAIInboxAnalyst.decode("{}")
        let result = BurnBarAIInboxAnalyst.validate(
            payload: payload,
            pack: AIInboxFixtures.packWithConversation(),
            detectorFindings: [],
            provenance: "test:model",
            now: Date()
        )
        XCTAssertEqual(result.briefMarkdown, "")
        XCTAssertTrue(result.findings.isEmpty)
        XCTAssertEqual(result.rejectedFindings, 0)
        XCTAssertEqual(result.rejectedMemories, 0)
    }

    // MARK: - Memory candidates that survive

    func test_groundedMemoryCandidateIsAttachedToTheFirstFinding() throws {
        let pack = AIInboxFixtures.packWithConversation()
        let payload = try BurnBarAIInboxAnalyst.decode("""
            {
              "brief_md": "Work continued on the auth middleware.",
              "findings": [
                {
                  "kind": "brief",
                  "title": "Auth refactor spans several sessions",
                  "summary_md": "The refactor restarted twice.",
                  "priority": 3,
                  "confidence": 0.7,
                  "evidence_ids": ["conv:conv-1:12"]
                }
              ],
              "memory_candidates": [
                {
                  "text": "This project pins its auth middleware behavior with contract tests.",
                  "kind": "convention",
                  "confidence": 3.5,
                  "citation_conversation_ids": ["conv-1", "conv-imaginary"]
                }
              ]
            }
            """)

        let result = BurnBarAIInboxAnalyst.validate(
            payload: payload,
            pack: pack,
            detectorFindings: [],
            provenance: "test:model",
            now: Date()
        )

        XCTAssertEqual(result.rejectedMemories, 0)
        XCTAssertEqual(result.findings.count, 1)
        let finding = try XCTUnwrap(result.findings.first)
        XCTAssertEqual(finding.memoryCandidates.count, 1)

        let memory = try XCTUnwrap(finding.memoryCandidates.first)
        XCTAssertTrue(memory.id.hasPrefix("mem_"), "Memory ids are stable hashes, not random")
        XCTAssertEqual(memory.text, "This project pins its auth middleware behavior with contract tests.")
        XCTAssertEqual(memory.kind, "convention")
        XCTAssertEqual(memory.confidence, 1.0, accuracy: 0.001, "Out-of-range confidence is clamped")
        XCTAssertEqual(
            memory.citationConversationIDs,
            ["conv-1"],
            "Only citations that resolve against the pack survive"
        )
    }

    func test_memoryCandidatesOutsideTheLengthBandAreRejected() throws {
        let pack = AIInboxFixtures.packWithConversation()
        let longText = String(repeating: "a", count: 601)
        let payload = try BurnBarAIInboxAnalyst.decode("""
            {
              "brief_md": "",
              "findings": [],
              "memory_candidates": [
                {"text": "too short", "kind": "context", "confidence": 0.9, "citation_conversation_ids": ["conv-1"]},
                {"text": "\(longText)", "kind": "context", "confidence": 0.9, "citation_conversation_ids": ["conv-1"]}
              ]
            }
            """)
        let result = BurnBarAIInboxAnalyst.validate(
            payload: payload,
            pack: pack,
            detectorFindings: [],
            provenance: "test:model",
            now: Date()
        )
        XCTAssertEqual(result.rejectedMemories, 2, "Fragments and essays are both not facts")
    }

    // MARK: - Fingerprint dedupe

    /// A model finding that lands on the exact fingerprint of an existing
    /// detector finding is a restatement, even when its kind slips past the
    /// kind-level dedupe (which exempts `brief`).
    func test_findingDuplicatingADetectorFingerprintIsRejected() throws {
        let pack = AIInboxFixtures.packWithConversation()
        let title = "Auth refactor spans several sessions"
        let detectorFinding = BurnBarAIInboxFinding(
            kind: .brief,
            title: title,
            summaryMarkdown: "…",
            priority: .p3,
            confidence: 0.9,
            evidenceIDs: [],
            fingerprint: BurnBarAIInboxFinding.fingerprint(
                kind: .brief,
                scope: "global",
                subject: BurnBarAIInboxAnalyst.normalizedSubject(title)
            ),
            source: .detector
        )
        let payload = try BurnBarAIInboxAnalyst.decode("""
            {
              "brief_md": "",
              "findings": [
                {
                  "kind": "brief",
                  "title": "\(title)",
                  "summary_md": "Restated.",
                  "priority": 3,
                  "confidence": 0.7,
                  "evidence_ids": ["conv:conv-1:12"]
                }
              ],
              "memory_candidates": []
            }
            """)

        let result = BurnBarAIInboxAnalyst.validate(
            payload: payload,
            pack: pack,
            detectorFindings: [detectorFinding],
            provenance: "test:model",
            now: Date()
        )
        XCTAssertTrue(result.findings.isEmpty)
        XCTAssertEqual(result.rejectedFindings, 1)
    }

    func test_normalizedSubjectStripsDigitsCaseAndLongTails() {
        XCTAssertEqual(
            BurnBarAIInboxAnalyst.normalizedSubject("3 Stale PRs Waiting"),
            "stale prs waiting",
            "Counts must not mint a new identity"
        )
        XCTAssertEqual(
            BurnBarAIInboxAnalyst.normalizedSubject("one two three four five six seven eight nine ten"),
            "one two three four five six seven eight"
        )
    }

    // MARK: - Actions derived from citations

    func test_prCitationsProduceOpenURLActions() throws {
        let now = Date()
        let pack = AIInboxFixtures.pack(
            repositories: [AIInboxFixtures.repository(
                slug: "Ajnunezg/BurnBar",
                runs: [],
                openPullRequests: [
                    AIInboxFixtures.pullRequest(number: 12, state: "OPEN", updatedAt: now)
                ]
            )],
            now: now
        )
        let payload = try BurnBarAIInboxAnalyst.decode("""
            {
              "brief_md": "",
              "findings": [
                {
                  "kind": "brief",
                  "title": "PR 12 has been circling for a while",
                  "summary_md": "Same branch, three force pushes.",
                  "priority": 3,
                  "confidence": 0.6,
                  "evidence_ids": ["pr:Ajnunezg/BurnBar#12"]
                }
              ],
              "memory_candidates": []
            }
            """)

        let result = BurnBarAIInboxAnalyst.validate(
            payload: payload,
            pack: pack,
            detectorFindings: [],
            provenance: "test:model",
            now: now
        )
        let finding = try XCTUnwrap(result.findings.first)
        let action = try XCTUnwrap(finding.actions.first)
        XCTAssertEqual(action.kind, .openURL)
        XCTAssertEqual(action.title, "Open PR #12")
        XCTAssertEqual(action.value, "https://github.com/Ajnunezg/BurnBar/pull/12")
        XCTAssertTrue(action.isPrimary, "The first derived action is the primary one")
    }

    func test_actionDerivationSkipsMalformedReferences() {
        // Exercised directly: the helper must tolerate ids that carry the right
        // prefix but not the right shape, without inventing a URL.
        //
        // `metric:whatever` used to belong on this list because NOTHING except
        // `conv:` and `pr:` produced an action. It is a well-formed citation
        // now (it routes to the spend surface — see AIInboxActionFactoryTests),
        // so the subject-less form is what proves the shape check still runs.
        let now = Date()
        let pack = AIInboxFixtures.emptyPack(now: now)
        let actions = BurnBarAIInboxAnalyst.actions(
            for: ["pr:no-number-here", "conv:", "metric:", "usage:", "mystery:whatever"],
            pack: pack
        )
        XCTAssertTrue(actions.isEmpty, "Malformed references must yield no buttons: \(actions)")
    }

    func test_conversationCitationsProduceResumeActions() {
        let pack = AIInboxFixtures.packWithConversation()
        let actions = BurnBarAIInboxAnalyst.actions(for: ["conv:conv-1:12"], pack: pack)
        // Resuming and reading are different intentions, and a session citation
        // now offers both rather than assuming which one you wanted.
        XCTAssertEqual(actions.map(\.kind), [.resumeConversation, .openSessionLog])
        XCTAssertEqual(Set(actions.map(\.value)), ["conv-1"])
        XCTAssertEqual(actions.filter(\.isPrimary).count, 1)
        XCTAssertTrue(actions[0].isPrimary)
    }

    // MARK: - Per-call accounting

    func test_makeCallPricesTokensThroughTheRoute() {
        let route = BurnBarProviderRoute(
            providerID: "deepseek",
            providerDisplayName: "DeepSeek",
            baseURL: "https://api.deepseek.com/v1",
            requestedModel: "deepseek-v4-flash",
            resolvedModelID: "deepseek-v4-flash",
            apiKey: "test-key",
            pricing: BurnBarModelPricing(inputPerMToken: 2, outputPerMToken: 10, cacheReadPerMToken: 0.5)
        )
        let result = BurnBarProviderExecutionResult(
            outputText: "{}",
            inputTokens: 1_000_000,
            outputTokens: 100_000,
            cacheCreationTokens: 0,
            cacheReadTokens: 200_000
        )

        let call = BurnBarAIInboxAnalyst.makeCall(role: "analyst", route: route, result: result)

        XCTAssertEqual(call.providerID, "deepseek")
        XCTAssertEqual(call.modelID, "deepseek-v4-flash")
        XCTAssertEqual(call.role, "analyst")
        XCTAssertEqual(call.inputTokens, 1_000_000)
        XCTAssertEqual(call.outputTokens, 100_000)
        XCTAssertEqual(call.cacheReadTokens, 200_000)
        // 1M input at $2/M + 100k output at $10/M + 200k cache reads at $0.5/M.
        XCTAssertEqual(call.costUSD, 2.0 + 1.0 + 0.1, accuracy: 0.0001)
        XCTAssertEqual(call.provenance, "deepseek:deepseek-v4-flash")
    }

    // MARK: - Repair prompt

    func test_repairPromptNamesTheParseErrorAndRepeatsTheOriginal() {
        let original = "# Context\nEverything the first attempt saw."
        let withError = BurnBarAIInboxAnalyst.repairPrompt(original: original, error: "missing brace")
        XCTAssertTrue(withError.contains("was not valid JSON"))
        XCTAssertTrue(withError.contains("(missing brace)"))
        XCTAssertTrue(withError.contains(original), "The evidence must be repeated, not referenced")

        let withoutError = BurnBarAIInboxAnalyst.repairPrompt(original: original, error: nil)
        XCTAssertTrue(withoutError.contains("was not valid JSON"))
        XCTAssertFalse(withoutError.contains("()"), "No empty parenthetical when the error is unknown")
        XCTAssertTrue(withoutError.contains(original))
    }

    // MARK: - Error surface

    func test_analystErrorsExplainThemselves() {
        XCTAssertEqual(
            BurnBarAIInboxAnalystError.invalidJSON("missing brace").errorDescription,
            "The analyst returned malformed JSON: missing brace"
        )
        XCTAssertEqual(
            BurnBarAIInboxAnalystError.egressRefused("host is not local").errorDescription,
            "Refused to send: host is not local"
        )
    }

    // MARK: - Voice enforcement

    /// The ban list is a contract, not advice: a model finding that speaks in
    /// the banned register never publishes. This is the production caller
    /// `violations(in:)` documents itself as serving.
    func test_findingInTheBannedRegisterIsRejectedNotPublished() throws {
        let pack = AIInboxFixtures.packWithConversation()
        let payload = try BurnBarAIInboxAnalyst.decode("""
            {
              "brief_md": "",
              "findings": [
                {
                  "kind": "brief",
                  "title": "It looks like the auth refactor might be interesting",
                  "summary_md": "You might want to delve into this robust landscape of changes.",
                  "priority": 3,
                  "confidence": 0.7,
                  "evidence_ids": ["conv:conv-1:12"]
                },
                {
                  "kind": "brief",
                  "title": "Auth refactor restarted twice; second attempt landed",
                  "summary_md": "Sessions 12 and 14 restarted the same middleware move. The merged commit is the keeper.",
                  "priority": 3,
                  "confidence": 0.7,
                  "evidence_ids": ["conv:conv-1:12"]
                }
              ]
            }
            """)

        let result = BurnBarAIInboxAnalyst.validate(
            payload: payload,
            pack: pack,
            detectorFindings: [],
            provenance: "test:model",
            now: Date()
        )

        XCTAssertEqual(result.findings.count, 1, "The violating finding must be rejected, the clean one kept")
        XCTAssertEqual(result.rejectedFindings, 1)
        let survivor = try XCTUnwrap(result.findings.first)
        XCTAssertTrue(survivor.title.hasPrefix("Auth refactor restarted twice"))
        XCTAssertTrue(
            BurnBarFounderLens.violations(in: survivor.title + "\n" + survivor.summaryMarkdown).isEmpty,
            "Published output must carry zero banned phrases"
        )
    }
}
