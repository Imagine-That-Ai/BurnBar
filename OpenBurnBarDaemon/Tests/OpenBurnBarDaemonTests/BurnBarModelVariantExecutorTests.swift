import OpenBurnBarCore
@testable import OpenBurnBarDaemon
import Foundation
import XCTest

final class BurnBarModelVariantExecutorTests: XCTestCase {

    private func variant(_ level: BurnBarThinkingLevel, base: String, maxOutput: Int? = nil) -> BurnBarModelVariant {
        BurnBarModelVariant(
            variantID: BurnBarModelVariant.defaultVariantID(baseModelID: base, level: level),
            label: BurnBarModelVariant.defaultLabel(for: level),
            baseModelID: base,
            thinkingLevel: level,
            maxOutputTokens: maxOutput
        )
    }

    func testApplyOpenAIVariantOverwritesCallerReasoningEffortOnChatCompletions() {
        var body: [String: Any] = [
            "model": "gpt-5.3-codex",
            "reasoning_effort": "low",
            "messages": []
        ]
        BurnBarOpenAICompatibleProviderExecutor.applyOpenAIVariant(
            variant(.xhigh, base: "gpt-5.3-codex"),
            to: &body,
            isResponsesShape: false
        )
        XCTAssertEqual(body["reasoning_effort"] as? String, "xhigh")
        let nested = body["reasoning"] as? [String: Any]
        XCTAssertEqual(nested?["effort"] as? String, "xhigh")
    }

    func testApplyOpenAIVariantOnResponsesUsesNestedReasoningOnly() {
        var body: [String: Any] = [
            "model": "gpt-5.3-codex",
            "input": []
        ]
        BurnBarOpenAICompatibleProviderExecutor.applyOpenAIVariant(
            variant(.high, base: "gpt-5.3-codex"),
            to: &body,
            isResponsesShape: true
        )
        XCTAssertNil(body["reasoning_effort"])
        let nested = body["reasoning"] as? [String: Any]
        XCTAssertEqual(nested?["effort"] as? String, "high")
    }

    func testApplyOpenAIVariantAppliesMaxOutputTokensWhenSupplied() {
        var responsesBody: [String: Any] = [
            "model": "gpt-5.3-codex",
            "max_completion_tokens": 1024,
            "max_tokens": 2048
        ]
        BurnBarOpenAICompatibleProviderExecutor.applyOpenAIVariant(
            variant(.medium, base: "gpt-5.3-codex", maxOutput: 12_345),
            to: &responsesBody,
            isResponsesShape: true
        )
        XCTAssertEqual(responsesBody["max_output_tokens"] as? Int, 12_345)
        XCTAssertNil(responsesBody["max_completion_tokens"])
        XCTAssertNil(responsesBody["max_tokens"])

        var chatBody: [String: Any] = [
            "model": "gpt-5.3-codex",
            "messages": []
        ]
        BurnBarOpenAICompatibleProviderExecutor.applyOpenAIVariant(
            variant(.medium, base: "gpt-5.3-codex", maxOutput: 4_096),
            to: &chatBody,
            isResponsesShape: false
        )
        XCTAssertEqual(chatBody["max_completion_tokens"] as? Int, 4_096)
        XCTAssertEqual(chatBody["max_tokens"] as? Int, 4_096)
    }

    func testApplyAnthropicVariantSetsThinkingAndEffort() {
        var body: [String: Any] = [
            "model": "claude-opus-4-7",
            "max_tokens": 4_096,
            "messages": []
        ]
        BurnBarAnthropicProviderExecutor.applyAnthropicVariant(
            variant(.xhigh, base: "claude-opus-4-7"),
            to: &body
        )
        let thinking = body["thinking"] as? [String: Any]
        XCTAssertEqual(thinking?["type"] as? String, "enabled")
        XCTAssertEqual(thinking?["budget_tokens"] as? Int, 16_384)
        XCTAssertEqual(body["effort"] as? String, "xhigh")
        let chosenMax = (body["max_tokens"] as? Int) ?? 0
        XCTAssertGreaterThanOrEqual(chosenMax, 16_384 + 4_096, "max_tokens must clear budget_tokens + 4096 floor")
    }

    func testApplyAnthropicVariantRaisesCallerMaxTokensWhenBelowFloor() {
        var body: [String: Any] = [
            "model": "claude-opus-4-7",
            "max_tokens": 1_000
        ]
        BurnBarAnthropicProviderExecutor.applyAnthropicVariant(
            variant(.max, base: "claude-opus-4-7"),
            to: &body
        )
        XCTAssertEqual(body["max_tokens"] as? Int, 32_768 + 4_096)
    }

    func testApplyAnthropicVariantHonoursVariantMaxOutputTokensWhenAboveFloor() {
        var body: [String: Any] = [
            "model": "claude-opus-4-7",
            "max_tokens": 1_000
        ]
        BurnBarAnthropicProviderExecutor.applyAnthropicVariant(
            variant(.high, base: "claude-opus-4-7", maxOutput: 64_000),
            to: &body
        )
        XCTAssertEqual(body["max_tokens"] as? Int, 64_000)
    }
}
