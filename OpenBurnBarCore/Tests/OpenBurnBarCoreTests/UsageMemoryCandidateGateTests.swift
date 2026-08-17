import XCTest
@testable import OpenBurnBarKernel

final class UsageMemoryCandidateGateTests: XCTestCase {
    private func input(
        _ text: String,
        sourceKind: MemorySourceKind = .safariAsk,
        role: String = "user",
        sensitivePage: Bool = false,
        repetitionCount: Int = 0
    ) -> UsageMemoryCandidateGate.Input {
        UsageMemoryCandidateGate.Input(
            sourceKind: sourceKind,
            text: text,
            sourceRef: "safari-ask:obs-1",
            threadLogicalID: "safari-ask:obs-1",
            role: role,
            sensitivePage: sensitivePage,
            repetitionCount: repetitionCount
        )
    }

    private func assertDrop(
        _ verdict: UsageMemoryCandidateGate.Verdict,
        _ reason: UsageMemoryCandidateGate.DropReason,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(verdict, .drop(reason), file: file, line: line)
    }

    // MARK: - Hard drops

    func test_nonUsageKindsAreRejected() {
        assertDrop(
            UsageMemoryCandidateGate.evaluate(input("How do I use GRDB migrations?", sourceKind: .chat)),
            .notUsageKind
        )
        assertDrop(
            UsageMemoryCandidateGate.evaluate(input("How do I use GRDB migrations?", sourceKind: .code)),
            .notUsageKind
        )
    }

    func test_toolAndAssistantRolesAreNoise() {
        assertDrop(
            UsageMemoryCandidateGate.evaluate(input("How do I deploy?", role: "assistant")),
            .toolNoise
        )
        assertDrop(
            UsageMemoryCandidateGate.evaluate(input("How do I deploy?", role: "tool")),
            .toolNoise
        )
    }

    func test_sensitivePageIsDroppedBeforeContentIsExamined() {
        assertDrop(
            UsageMemoryCandidateGate.evaluate(input("How do I reset my password?", sensitivePage: true)),
            .sensitivePage
        )
    }

    func test_byteBoundsAreEnforced() {
        assertDrop(UsageMemoryCandidateGate.evaluate(input("hi?")), .tooShort)
        let long = String(repeating: "how do I do this thing? ", count: 200)
        assertDrop(UsageMemoryCandidateGate.evaluate(input(long)), .tooLong)
    }

    func test_secretBearingTextIsRejectedByG7() {
        let secret = "my key is sk-ant-1234567890abcdef1234567890 — how do I hide it?"
        assertDrop(UsageMemoryCandidateGate.evaluate(input(secret)), .secretPII)
    }

    func test_junkShapesAreDropped() {
        assertDrop(
            UsageMemoryCandidateGate.evaluate(input("https://example.com/some/deep/path?q=1")),
            .junk
        )
        assertDrop(
            UsageMemoryCandidateGate.evaluate(input(">>> ---- #### !!!! ~~~~ ????")),
            .junk
        )
    }

    // MARK: - Salience

    func test_plainStatementWithoutDurableSignalIsDropped() {
        assertDrop(
            UsageMemoryCandidateGate.evaluate(input("the quick brown fox jumped over the lazy dog")),
            .noDurableSignal
        )
    }

    func test_questionShapeIsAccepted() {
        guard case .accept(let salience) = UsageMemoryCandidateGate.evaluate(
            input("How do I pin a GRDB migration to a version?")
        ) else {
            XCTFail("Expected accept")
            return
        }
        XCTAssertGreaterThanOrEqual(salience, UsageMemoryCurationPolicy.defaults.thresholds.accept)
    }

    func test_correctionOutscoresPlainQuestion() {
        guard case .accept(let question) = UsageMemoryCandidateGate.evaluate(
            input("How do I pin a GRDB migration?")
        ),
            case .accept(let correction) = UsageMemoryCandidateGate.evaluate(
                input("No, I meant the SQLCipher database, not the cache.")
            )
        else {
            XCTFail("Expected accepts")
            return
        }
        XCTAssertGreaterThan(correction, question)
    }

    func test_firstPersonDurableStatementIsAccepted() {
        guard case .accept = UsageMemoryCandidateGate.evaluate(
            input("I prefer dark mode in every editor I use.")
        ) else {
            XCTFail("Expected accept")
            return
        }
    }

    func test_repetitionBoostsButIsCapped() {
        let base = UsageMemoryCandidateGate.evaluate(input("How do I run the release script?"))
        let boosted = UsageMemoryCandidateGate.evaluate(
            input("How do I run the release script?", repetitionCount: 2)
        )
        let saturated = UsageMemoryCandidateGate.evaluate(
            input("How do I run the release script?", repetitionCount: 50)
        )
        guard case .accept(let baseScore) = base,
              case .accept(let boostedScore) = boosted,
              case .accept(let saturatedScore) = saturated else {
            XCTFail("Expected accepts")
            return
        }
        XCTAssertGreaterThan(boostedScore, baseScore)
        let cap = UsageMemoryCurationPolicy.defaults.salience.repetitionCap
        XCTAssertEqual(saturatedScore - baseScore, cap, accuracy: 0.0001)
    }

    func test_workflowRoleFromSessionMiningIsAccepted() {
        guard case .accept = UsageMemoryCandidateGate.evaluate(
            input(
                "Repeatedly runs the xcodegen tool (5x this session).",
                sourceKind: .agentSession,
                role: "workflow"
            )
        ) else {
            XCTFail("Expected accept")
            return
        }
    }

    func test_salienceIsCappedAtOne() {
        guard case .accept(let salience) = UsageMemoryCandidateGate.evaluate(
            input(
                "No, I meant I always use my project's release script — how do I pin it?",
                repetitionCount: 10
            )
        ) else {
            XCTFail("Expected accept")
            return
        }
        XCTAssertLessThanOrEqual(salience, 1.0)
    }
}

final class UsageMemorySimHashTests: XCTestCase {
    func test_identicalTextsShareABucket() {
        XCTAssertEqual(
            UsageMemorySimHash.hash("How do I pin a GRDB migration?"),
            UsageMemorySimHash.hash("how do i pin a grdb MIGRATION?")
        )
    }

    func test_nearDuplicatesAreHammingClose_unrelatedTextsAreNot() {
        let a = UsageMemorySimHash.hash("How do I pin a GRDB migration to a specific schema version?")
        let b = UsageMemorySimHash.hash("How do I pin a GRDB migration to a specific database version?")
        let c = UsageMemorySimHash.hash("Murmuration boids need curl-noise wind fields for beauty.")
        XCTAssertLessThan(UsageMemorySimHash.hammingDistance(a, b), 16)
        XCTAssertGreaterThan(UsageMemorySimHash.hammingDistance(a, c), 16)
    }

    func test_emptyAndSymbolOnlyTextsHashToZero() {
        XCTAssertEqual(UsageMemorySimHash.hash(""), 0)
        XCTAssertEqual(UsageMemorySimHash.hash("   \n\t "), 0)
        XCTAssertEqual(UsageMemorySimHash.hash("!!! ???"), 0)
    }

    func test_storageValueRoundTripsThroughInt64() {
        let hash = UsageMemorySimHash.hash("How do I pin a GRDB migration?")
        XCTAssertEqual(UInt64(bitPattern: UsageMemorySimHash.storageValue(hash)), hash)
    }
}

final class UsageMemoryCurationPolicyTests: XCTestCase {
    func test_defaultsRoundTripThroughJSON() throws {
        let encoded = try JSONEncoder().encode(UsageMemoryCurationPolicy.defaults)
        let decoded = try JSONDecoder().decode(UsageMemoryCurationPolicy.self, from: encoded)
        XCTAssertEqual(decoded, UsageMemoryCurationPolicy.defaults)
    }

    func test_sourceTrustMapsEveryKind() {
        let trust = UsageMemoryCurationPolicy.defaults.sourceTrust
        XCTAssertEqual(trust.trust(for: .chat), 1.0)
        XCTAssertEqual(trust.trust(for: .safariAsk), 0.7)
        XCTAssertEqual(trust.trust(for: .agentSession), 0.5)
    }
}
