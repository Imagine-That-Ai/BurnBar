import XCTest
@testable import OpenBurnBarMobile

final class FriendlyModelNameTests: XCTestCase {
    func testHyphenatedWireIDsBecomeReadable() {
        XCTAssertEqual(FriendlyModelName.format("grok-build-0.1"), "Grok Build 0.1")
        XCTAssertEqual(FriendlyModelName.format("claude-fable-5"), "Claude Fable 5")
        XCTAssertEqual(FriendlyModelName.format("hermes-4-405b"), "Hermes 4 405B")
        XCTAssertEqual(FriendlyModelName.format("llama-3.3-70b-instruct"), "Llama 3.3 70B Instruct")
    }

    func testAcronymsHyphenJoinTheirVersion() {
        XCTAssertEqual(FriendlyModelName.format("gpt-5.5-codex"), "GPT-5.5 Codex")
        XCTAssertEqual(FriendlyModelName.format("glm-4.7"), "GLM-4.7")
        XCTAssertEqual(FriendlyModelName.format("o3-mini"), "o3 Mini")
    }

    func testBrandCasings() {
        XCTAssertEqual(FriendlyModelName.format("minimax-m2.7"), "MiniMax M2.7")
        XCTAssertEqual(FriendlyModelName.format("deepseek-r1"), "DeepSeek R1")
        XCTAssertEqual(FriendlyModelName.format("qwen3-coder-30b-a3b-instruct"), "Qwen3 Coder 30B A3B Instruct")
    }

    func testProviderPathPrefixIsDropped() {
        XCTAssertEqual(FriendlyModelName.format("x-ai/grok-4"), "Grok 4")
        XCTAssertEqual(FriendlyModelName.format("openrouter/minimax-m2.7"), "MiniMax M2.7")
    }

    func testOllamaTagReadsAsWordBreak() {
        XCTAssertEqual(FriendlyModelName.format("llama3:8b"), "Llama3 8B")
    }

    func testTrailingDateStampIsDropped() {
        XCTAssertEqual(FriendlyModelName.format("claude-haiku-4-5-20251001"), "Claude Haiku 4 5")
    }

    func testHumanAuthoredNamesPassThrough() {
        XCTAssertEqual(FriendlyModelName.format("Grok Build 0.1"), "Grok Build 0.1")
        XCTAssertEqual(FriendlyModelName.format("Choose model"), "Choose model")
    }

    func testDegenerateInputsDoNotCrash() {
        XCTAssertEqual(FriendlyModelName.format(""), "")
        XCTAssertEqual(FriendlyModelName.format("-"), "-")
        XCTAssertEqual(FriendlyModelName.format("20251001"), "20251001")
    }
}
