import OpenBurnBarCore
import Foundation

// remediation(gateway decomposition): relocated verbatim from
// OpenBurnBarHTTPGatewayServer.swift (was `private` inside the actor) to shrink
// that 3,000+-line file. These two types are fully self-contained — they depend
// only on `BurnBarProviderProxyUsage` (OpenBurnBarCore) and each other — so the
// move is mechanically safe. Access changed from `private` to module-internal
// (no modifier) so the gateway actor in the same module can still reference
// them. No behavior change.

/// Selects how the streaming usage accumulator parses SSE events.
enum GatewayStreamUsageFormat {
    case openAI
    case anthropic
}

/// Parses token usage out of an SSE stream as it is relayed, so streamed
/// responses record real usage instead of `nil` (A4). Used entirely within
/// the gateway actor's isolation, so a plain reference type is safe.
final class GatewayStreamingUsageAccumulator {
    private let format: GatewayStreamUsageFormat
    private var inputTokens = 0
    private var outputTokens = 0
    private var cacheCreationTokens = 0
    private var cacheReadTokens = 0
    private var reasoningTokens = 0
    private var sawUsage = false

    init(format: GatewayStreamUsageFormat) {
        self.format = format
    }

    func consume(_ chunk: Data) {
        guard let text = String(data: chunk, encoding: .utf8) else { return }
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]",
                  let data = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            switch format {
            case .openAI:
                consumeOpenAI(object)
            case .anthropic:
                consumeAnthropic(object)
            }
        }
    }

    func finalize() -> BurnBarProviderProxyUsage? {
        guard sawUsage else { return nil }
        return BurnBarProviderProxyUsage(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens,
            reasoningTokens: reasoningTokens,
            confidence: .exact
        )
    }

    private func consumeOpenAI(_ object: [String: Any]) {
        guard let usage = object["usage"] as? [String: Any] else { return }
        let prompt = Self.intValue(usage["prompt_tokens"])
        let completion = Self.intValue(usage["completion_tokens"])
        guard prompt != nil || completion != nil else { return }
        sawUsage = true
        let promptDetails = usage["prompt_tokens_details"] as? [String: Any]
        let cached = Self.intValue(promptDetails?["cached_tokens"]) ?? 0
        let created = Self.intValue(usage["cache_creation_input_tokens"])
            ?? Self.intValue(promptDetails?["cache_creation_tokens"])
            ?? Self.intValue(promptDetails?["cache_creation_input_tokens"])
            ?? 0
        let completionDetails = usage["completion_tokens_details"] as? [String: Any]
        let reasoning = Self.intValue(completionDetails?["reasoning_tokens"]) ?? 0
        // The final usage chunk is authoritative — overwrite rather than sum.
        inputTokens = max((prompt ?? 0) - cached, 0)
        outputTokens = completion ?? 0
        cacheCreationTokens = created
        cacheReadTokens = cached
        reasoningTokens = reasoning
    }

    private func consumeAnthropic(_ object: [String: Any]) {
        let type = object["type"] as? String
        if type == "message_start",
           let message = object["message"] as? [String: Any],
           let usage = message["usage"] as? [String: Any] {
            sawUsage = true
            inputTokens = Self.intValue(usage["input_tokens"]) ?? inputTokens
            cacheCreationTokens = Self.intValue(usage["cache_creation_input_tokens"]) ?? cacheCreationTokens
            cacheReadTokens = Self.intValue(usage["cache_read_input_tokens"]) ?? cacheReadTokens
            outputTokens = Self.intValue(usage["output_tokens"]) ?? outputTokens
        } else if type == "message_delta",
                  let usage = object["usage"] as? [String: Any] {
            sawUsage = true
            // output_tokens in message_delta is cumulative for the message.
            outputTokens = Self.intValue(usage["output_tokens"]) ?? outputTokens
            if let input = Self.intValue(usage["input_tokens"]) {
                inputTokens = input
            }
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        if let string = value as? String { return Int(string) }
        return nil
    }
}
