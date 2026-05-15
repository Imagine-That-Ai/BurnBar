import XCTest
@testable import OpenBurnBarCore

// MARK: - Hermes Square Phase D Tests
//
// Covers plan §6.7 (voice intent resolution).

final class HermesSquareVoiceIntentResolverTests: XCTestCase {

    private let nameMap: [String: String] = [
        "claude":   "agent://burnbar/claude",
        "codex":    "agent://burnbar/codex",
        "hermes":   "agent://burnbar/hermes",
        "openclaw": "agent://burnbar/openclaw"
    ]

    func testAmbientBriefingRecognised() {
        let intent = VoiceIntentResolver.resolve(
            transcript: "What's important?",
            installedAgentNames: nameMap
        )
        XCTAssertEqual(intent, .ambientBriefing)
    }

    func testSearchIntentExtractsQuery() {
        let intent = VoiceIntentResolver.resolve(
            transcript: "Search for router rails",
            installedAgentNames: nameMap
        )
        XCTAssertEqual(intent, .search(query: "router rails"))
    }

    func testOpenAgentResolvesByDisplayName() {
        let intent = VoiceIntentResolver.resolve(
            transcript: "Open Claude",
            installedAgentNames: nameMap
        )
        XCTAssertEqual(intent, .openAgent(agentURI: "agent://burnbar/claude"))
    }

    func testDispatchToRuntimeViaDispatchPrefix() {
        let intent = VoiceIntentResolver.resolve(
            transcript: "Dispatch refactor router rails to Codex",
            installedAgentNames: nameMap
        )
        XCTAssertEqual(
            intent,
            .dispatchMission(prompt: "refactor router rails", runtimeHint: "agent://burnbar/codex")
        )
    }

    func testHaveRunPatternRecognised() {
        let intent = VoiceIntentResolver.resolve(
            transcript: "Have Codex run the cost-efficiency pass",
            installedAgentNames: nameMap
        )
        XCTAssertEqual(
            intent,
            .dispatchMission(prompt: "the cost-efficiency pass", runtimeHint: "agent://burnbar/codex")
        )
    }

    func testCurrentThreadFallbackUsesSendMessage() {
        let intent = VoiceIntentResolver.resolve(
            transcript: "what about a smaller window",
            installedAgentNames: nameMap,
            currentThreadAgentURI: "agent://burnbar/hermes"
        )
        XCTAssertEqual(
            intent,
            .sendMessageToCurrentThread(text: "what about a smaller window")
        )
    }

    func testNoThreadFallbackUsesHermes() {
        let intent = VoiceIntentResolver.resolve(
            transcript: "hmm, just thinking out loud",
            installedAgentNames: nameMap
        )
        XCTAssertEqual(intent, .fallbackToHermes(text: "hmm, just thinking out loud"))
    }

    func testEmptyTranscriptFallsThroughToHermes() {
        let intent = VoiceIntentResolver.resolve(
            transcript: "    ",
            installedAgentNames: nameMap
        )
        XCTAssertEqual(intent, .fallbackToHermes(text: ""))
    }

    func testVoiceIntentRoundTripsThroughCodable() throws {
        let intents: [VoiceIntent] = [
            .sendMessageToCurrentThread(text: "hi"),
            .openAgent(agentURI: "agent://burnbar/claude"),
            .dispatchMission(prompt: "do x", runtimeHint: "codex"),
            .search(query: "router"),
            .ambientBriefing,
            .fallbackToHermes(text: "fallback")
        ]
        for intent in intents {
            let data = try JSONEncoder().encode(intent)
            let decoded = try JSONDecoder().decode(VoiceIntent.self, from: data)
            XCTAssertEqual(intent, decoded)
        }
    }
}
