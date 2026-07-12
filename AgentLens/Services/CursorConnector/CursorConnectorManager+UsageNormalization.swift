import Foundation

extension CursorConnectorManager {
    struct NormalizedUsageEvent {
        let promptTokens: Int
        let completionTokens: Int
        let cacheCreationTokens: Int
        let cacheReadTokens: Int
        let reasoningTokens: Int
        let totalTokens: Int

        /// Returns true when all explicit buckets are zero/absent.
        /// This indicates that fallback estimation should be used rather than normalization.
        var hasNoExplicitBuckets: Bool {
            promptTokens == 0 && completionTokens == 0 && cacheCreationTokens == 0 && cacheReadTokens == 0 && reasoningTokens == 0
        }

        /// Returns true when at least one primary bucket (prompt or completion) is explicitly present.
        /// Normalization from total_tokens is appropriate in this case.
        var hasExplicitPrimaryBucket: Bool {
            promptTokens > 0 || completionTokens > 0
        }
    }

    static func normalizeUsageEvent(_ json: [String: Any]) -> NormalizedUsageEvent {
        var prompt = firstIntValue(
            in: json,
            paths: [
                ["prompt_tokens"],
                ["input_tokens"],
                ["promptTokens"],
                ["inputTokens"]
            ]
        ) ?? 0

        var completion = firstIntValue(
            in: json,
            paths: [
                ["completion_tokens"],
                ["output_tokens"],
                ["completionTokens"],
                ["outputTokens"]
            ]
        ) ?? 0

        let cacheCreation = firstIntValue(
            in: json,
            paths: [
                ["cache_creation_input_tokens"],
                ["cache_creation_tokens"],
                ["cacheCreationTokens"]
            ]
        ) ?? 0

        let exclusiveCacheRead = firstIntValue(
            in: json,
            paths: [
                ["cache_read_tokens"],
                ["cache_read_input_tokens"],
                ["cacheReadTokens"]
            ]
        ) ?? 0

        let inclusiveCacheRead = firstIntValue(
            in: json,
            paths: [
                ["input_cached_tokens"],
                ["inputCachedTokens"],
                ["prompt_tokens_details", "cached_tokens"],
                ["promptTokensDetails", "cachedTokens"],
                ["input_tokens_details", "cached_tokens"],
                ["inputTokensDetails", "cachedTokens"],
                ["cached_tokens"],
                ["cachedTokens"],
                ["cached_input_tokens"],
                ["cachedInputTokens"]
            ]
        ) ?? 0
        let cacheRead = exclusiveCacheRead > 0 ? exclusiveCacheRead : inclusiveCacheRead
        if inclusiveCacheRead > 0 && exclusiveCacheRead == 0 {
            prompt = max(prompt - inclusiveCacheRead, 0)
        }

        // VAL-TOKEN-006: Extract reasoning tokens from all known paths
        let reasoningTokens = firstIntValue(
            in: json,
            paths: [
                ["thinking_tokens"],
                ["reasoning_tokens"],
                ["thinkingTokens"],
                ["reasoningTokens"],
                ["completion_tokens_details", "reasoning_tokens"],
                ["output_tokens_details", "reasoning_tokens"]
            ]
        ) ?? 0

        let total = firstIntValue(
            in: json,
            paths: [
                ["total_tokens"],
                ["totalTokens"]
            ]
        ) ?? 0

        let inputCharHint = firstIntValue(
            in: json,
            paths: [
                ["input_char_estimate"],
                ["inputCharEstimate"]
            ]
        ) ?? 0

        let outputCharHint = firstIntValue(
            in: json,
            paths: [
                ["output_char_estimate"],
                ["outputCharEstimate"]
            ]
        ) ?? 0

        let explicitTotal = prompt + completion + cacheCreation + cacheRead
        let normalizedTotal = max(total, explicitTotal)

        // VAL-TOKEN-004: Fallback gating - normalization occurs when total_tokens is present.
        // Deriving input/output from total_tokens is normalization (VAL-TOKEN-004), not fallback.
        // Fallback (character-based estimation) only occurs when total_tokens is absent AND all buckets are 0.

        if normalizedTotal > 0 {
            // Normalization: derive missing primary buckets from total_tokens.
            // This is appropriate when total_tokens is explicitly provided by the provider.
            // VAL-TOKEN-006: Reasoning tokens are a separate bucket and must be subtracted
            // from availableForInOut to prevent them from being incorrectly added to completion.
            let availableForInOut = max(normalizedTotal - cacheCreation - cacheRead - reasoningTokens, 0)
            if prompt == 0 && completion == 0 && availableForInOut > 0 {
                // Both missing but total available - use hints to normalize the split
                let combinedHintChars = inputCharHint + outputCharHint
                let inputRatio = combinedHintChars > 0
                    ? Double(inputCharHint) / Double(combinedHintChars)
                    : 0.62
                prompt = Int((Double(availableForInOut) * inputRatio).rounded())
                completion = max(availableForInOut - prompt, 0)
            } else if prompt == 0 && completion > 0 && availableForInOut > completion {
                prompt = availableForInOut - completion
            } else if completion == 0 && prompt > 0 && availableForInOut > prompt {
                completion = availableForInOut - prompt
            } else if prompt + completion < availableForInOut {
                completion += availableForInOut - (prompt + completion)
            }
        } else if prompt == 0 && completion == 0 && cacheCreation == 0 && cacheRead == 0 && reasoningTokens == 0 && inputCharHint + outputCharHint > 0 {
            // Fallback: character-based estimation only when NO token data and NO total_tokens.
            // This is true fallback mode - we have no usage data to work with.
            if inputCharHint > 0 {
                prompt = max(Int((Double(inputCharHint) / 3.35).rounded(.up)), 1)
            }
            if outputCharHint > 0 {
                completion = max(Int((Double(outputCharHint) / 3.35).rounded(.up)), 1)
            }
        }

        // VAL-TOKEN-006: Reasoning tokens are preserved explicitly, not folded into completion.
        // If the provider reports reasoning tokens separately, they remain as a distinct bucket.

        return NormalizedUsageEvent(
            promptTokens: max(prompt, 0),
            completionTokens: max(completion, 0),
            cacheCreationTokens: max(cacheCreation, 0),
            cacheReadTokens: max(cacheRead, 0),
            reasoningTokens: max(reasoningTokens, 0),
            totalTokens: max(normalizedTotal, prompt + completion + cacheCreation + cacheRead)
        )
    }

    private static func firstIntValue(in dictionary: [String: Any], paths: [[String]]) -> Int? {
        for path in paths {
            if let value = nestedValue(in: dictionary, path: path),
               let intValue = parseInt(value) {
                return intValue
            }
        }
        return nil
    }

    private static func nestedValue(in dictionary: [String: Any], path: [String]) -> Any? {
        var cursor: Any = dictionary
        for key in path {
            guard let dict = cursor as? [String: Any], let next = dict[key] else {
                return nil
            }
            cursor = next
        }
        return cursor
    }

    private static func parseInt(_ value: Any?) -> Int? {
        guard let value else { return nil }
        if let intValue = value as? Int {
            return max(intValue, 0)
        }
        if let int64Value = value as? Int64 {
            return max(Int(int64Value), 0)
        }
        if let doubleValue = value as? Double {
            return max(Int(doubleValue.rounded()), 0)
        }
        if let numberValue = value as? NSNumber {
            return max(numberValue.intValue, 0)
        }
        if let stringValue = value as? String {
            let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if let intValue = Int(trimmed) {
                return max(intValue, 0)
            }
            if let doubleValue = Double(trimmed) {
                return max(Int(doubleValue.rounded()), 0)
            }
        }
        return nil
    }

}
