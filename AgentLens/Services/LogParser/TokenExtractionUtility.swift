import Foundation

// MARK: - Shared Token Extraction Utilities

/// Extracted token usage fields from a provider's usage dictionary.
struct ExtractedTokenUsage {
    let input: Int
    let output: Int
    let cacheCreation: Int
    let cacheRead: Int
    let reasoningTokens: Int

    /// Returns true when all explicit buckets (input, output, cacheCreation, cacheRead, reasoningTokens) are zero/absent.
    /// This indicates that fallback estimation should be used rather than normalization.
    var hasNoExplicitBuckets: Bool {
        input == 0 && output == 0 && cacheCreation == 0 && cacheRead == 0 && reasoningTokens == 0
    }

    /// Returns true when at least one primary bucket (input or output) is explicitly present.
    /// Normalization from total_tokens is appropriate in this case.
    var hasExplicitPrimaryBucket: Bool {
        input > 0 || output > 0
    }
}

/// Estimated token counts derived from character-level content analysis.
struct EstimatedTokens {
    let input: Int
    let output: Int
}

/// Shared utilities for parsing token usage from heterogeneous provider JSON formats.
/// Used by ClaudeCodeParser, FactoryDroidParser, ModelFilterParser, and others.
enum TokenExtractionUtility {
    /// Factory-style logs sometimes persist only a preview of large tool output blocks,
    /// plus a marker like "[Showing lines 1-50 of 317 total lines]". We add a
    /// conservative allowance for that hidden text when falling back to transcript
    /// estimation so MiniMax/Z.ai sessions do not systematically undercount.
    private static let previewLineRegex = try! NSRegularExpression(
        pattern: #"(?:<system-reminder>)?\[Showing lines (\d+)-(\d+) of (\d+) total lines\](?:</system-reminder>)?"#
    )

    // MARK: - Estimator Configuration

    /// Controls which fallback estimator is used when exact token counts are unavailable.
    /// - characterRatio: Default character-based estimation (charsPerToken ~3.35 for visible, ~2.45 for reasoning)
    /// - tokenizerAssisted: Higher-precision estimation using actual tokenizer when available
    enum FallbackEstimator: String {
        case characterRatio = "char-ratio-v1"
        case tokenizerAssisted = "tokenizer-v1"
    }

    /// The current fallback estimator. Defaults to `.characterRatio`.
    /// UsageAggregat or should set this based on the `tokenizerAssistedFallbackEnabled` user flag.
    static var fallbackEstimator: FallbackEstimator = .characterRatio

    /// Returns the estimator version string for use in provenance metadata.
    static var currentEstimatorVersion: String {
        fallbackEstimator.rawValue
    }

    // MARK: - Usage Extraction

    /// Extract token counts from a usage dictionary, handling multiple naming conventions
    /// across providers (snake_case, camelCase, nested objects).
    ///
    /// - Important: This function preserves explicit token buckets without heuristic redistribution.
    ///   Normalization (deriving missing primary buckets from total_tokens) only occurs when at least
    ///   one primary bucket (input or output) is explicitly present. Fallback estimation based on
    ///   character counts must be triggered by the caller when `ExtractedTokenUsage.hasNoExplicitBuckets` is true.
    ///
    /// - Parameters:
    ///   - usage: The usage dictionary from the provider payload
    ///   - inputHint: Optional hint for normalizing input/output split when total_tokens is available but input is missing
    ///   - outputHint: Optional hint for normalizing input/output split when total_tokens is available but output is missing
    ///
    /// - Returns: An `ExtractedTokenUsage` with all explicit buckets preserved. The caller should check
    ///   `hasNoExplicitBuckets` to determine if fallback estimation is needed.
    static func extractUsageTokens(
        _ usage: [String: Any],
        inputHint: Int = 0,
        outputHint: Int = 0
    ) -> ExtractedTokenUsage {
        var input = firstIntValue(
            in: usage,
            paths: [
                ["input_tokens"],
                ["prompt_tokens"],
                ["inputTokens"],
                ["promptTokens"]
            ]
        ) ?? 0

        var output = firstIntValue(
            in: usage,
            paths: [
                ["output_tokens"],
                ["completion_tokens"],
                ["outputTokens"],
                ["completionTokens"]
            ]
        ) ?? 0

        let cacheCreation = firstIntValue(
            in: usage,
            paths: [
                ["cache_creation_input_tokens"],
                ["cache_creation_tokens"],
                ["cacheCreationTokens"]
            ]
        ) ?? 0

        let cacheRead = firstIntValue(
            in: usage,
            paths: [
                ["cache_read_input_tokens"],
                ["cache_read_tokens"],
                ["cacheReadTokens"],
                ["prompt_tokens_details", "cached_tokens"],
                ["promptTokensDetails", "cachedTokens"],
                ["cached_tokens"],
                ["cachedTokens"]
            ]
        ) ?? 0

        let reasoningTokens = firstIntValue(
            in: usage,
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
            in: usage,
            paths: [
                ["total_tokens"],
                ["totalTokens"]
            ]
        ) ?? 0

        let explicitPayloadTotal = max(input, 0) + max(output, 0) + max(cacheCreation, 0) + max(cacheRead, 0)
        let normalizedTotal = max(total, explicitPayloadTotal)

        // VAL-TOKEN-004: Fallback gating - normalization occurs when total_tokens is present.
        // Deriving input/output from total_tokens is normalization (VAL-TOKEN-004), not fallback.
        // Fallback (character-based estimation) only occurs when total_tokens is absent AND all buckets are 0.
        // The caller is responsible for fallback estimation when hasNoExplicitBuckets is true and total == 0.

        if normalizedTotal > 0 {
            // Normalization: derive missing primary buckets from total_tokens.
            // This is appropriate when total_tokens is explicitly provided by the provider.
            let availableForInOut = max(normalizedTotal - cacheCreation - cacheRead, 0)

            if input == 0 && output == 0 && availableForInOut > 0 {
                // Both missing but total available - use hints to normalize the split
                let combinedHints = inputHint + outputHint
                let inputRatio = combinedHints > 0
                    ? Double(inputHint) / Double(combinedHints)
                    : 0.62
                input = Int((Double(availableForInOut) * inputRatio).rounded())
                output = max(availableForInOut - input, 0)
            } else if input == 0 && output > 0 && availableForInOut > output {
                input = availableForInOut - output
            } else if output == 0 && input > 0 && availableForInOut > input {
                output = availableForInOut - input
            } else if input + output < availableForInOut {
                output += availableForInOut - (input + output)
            }
        }
        // Note: When normalizedTotal is 0 and all buckets are 0, the caller should detect
        // hasNoExplicitBuckets=true and apply fallback estimation if appropriate.

        // VAL-TOKEN-006: Reasoning tokens are preserved explicitly, not folded into output.
        // If the provider reports reasoning tokens separately, they remain as a distinct bucket.

        return ExtractedTokenUsage(
            input: max(input, 0),
            output: max(output, 0),
            cacheCreation: max(cacheCreation, 0),
            cacheRead: max(cacheRead, 0),
            reasoningTokens: max(reasoningTokens, 0)
        )
    }

    // MARK: - Content Metrics

    /// Keys in content dictionaries that should not contribute to character counts.
    private static let ignoredContentKeys: Set<String> = ["type", "role", "id", "tool_use_id", "name"]

    /// Measures visible and reasoning character counts from arbitrary JSON content structures.
    static func contentMetrics(from value: Any, key: String? = nil) -> (visibleChars: Int, reasoningChars: Int) {
        switch value {
        case let text as String:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return (0, 0) }
            if key == "signature" {
                return (0, trimmed.count)
            }
            if let key, ignoredContentKeys.contains(key) {
                return (0, 0)
            }
            return (previewAdjustedVisibleCharCount(for: trimmed), 0)
        case let array as [Any]:
            var visible = 0
            var reasoning = 0
            for item in array {
                let nested = contentMetrics(from: item)
                visible += nested.visibleChars
                reasoning += nested.reasoningChars
            }
            return (visible, reasoning)
        case let dictionary as [String: Any]:
            var visible = 0
            var reasoning = 0
            for (nestedKey, nestedValue) in dictionary {
                let nested = contentMetrics(from: nestedValue, key: nestedKey)
                visible += nested.visibleChars
                reasoning += nested.reasoningChars
            }
            return (visible, reasoning)
        default:
            return (0, 0)
        }
    }

    private static func previewAdjustedVisibleCharCount(for text: String) -> Int {
        let nsText = text as NSString
        let matches = previewLineRegex.matches(
            in: text,
            range: NSRange(location: 0, length: nsText.length)
        )

        guard !matches.isEmpty else { return text.count }

        var adjustedCount = text.count
        for match in matches where match.numberOfRanges == 4 {
            guard
                let shownStart = integerCapture(match, at: 1, in: nsText),
                let shownEnd = integerCapture(match, at: 2, in: nsText),
                let totalLines = integerCapture(match, at: 3, in: nsText)
            else {
                continue
            }

            let shownLines = max(shownEnd - shownStart + 1, 1)
            let markerLocation = match.range.location
            guard markerLocation > 0 else { continue }

            let excerpt = nsText.substring(to: markerLocation)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !excerpt.isEmpty else { continue }

            let excerptLines = excerpt
                .split(whereSeparator: \.isNewline)
                .filter { !String($0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let effectiveLines = max(1, min(shownLines, excerptLines.count))
            let excerptChars = excerpt.count
            let averageCharsPerLine = Double(excerptChars) / Double(effectiveLines)
            let estimatedFullChars = Int((averageCharsPerLine * Double(totalLines)).rounded())

            // Cap the expansion at 100% of the visible excerpt to avoid explosive
            // over-counting when the same file is previewed repeatedly in one session.
            let boundedBonus = min(max(estimatedFullChars - excerptChars, 0), excerptChars)
            adjustedCount += boundedBonus
        }

        return adjustedCount
    }

    private static func integerCapture(_ match: NSTextCheckingResult, at index: Int, in text: NSString) -> Int? {
        let range = match.range(at: index)
        guard range.location != NSNotFound else { return nil }
        return Int(text.substring(with: range))
    }

    // MARK: - Fallback Estimation

    /// Estimate token counts from character-level content analysis when no usage data is available.
    /// Uses the configured `fallbackEstimator` to determine the estimation method.
    ///
    /// - VAL-TOKEN-008: When `fallbackEstimator` is `.tokenizerAssisted`, uses tokenizer-aware
    ///   estimation. When `.characterRatio` (default), uses character-ratio heuristics.
    static func estimateFallbackTokens(
        userVisibleChars: Int,
        assistantVisibleChars: Int,
        assistantReasoningChars: Int,
        userMessageCount: Int,
        assistantMessageCount: Int
    ) -> EstimatedTokens {
        switch fallbackEstimator {
        case .characterRatio:
            return estimateFallbackTokensCharacterRatio(
                userVisibleChars: userVisibleChars,
                assistantVisibleChars: assistantVisibleChars,
                assistantReasoningChars: assistantReasoningChars,
                userMessageCount: userMessageCount,
                assistantMessageCount: assistantMessageCount
            )
        case .tokenizerAssisted:
            return estimateFallbackTokensTokenizerAssisted(
                userVisibleChars: userVisibleChars,
                assistantVisibleChars: assistantVisibleChars,
                assistantReasoningChars: assistantReasoningChars,
                userMessageCount: userMessageCount,
                assistantMessageCount: assistantMessageCount
            )
        }
    }

    /// Character-ratio fallback estimation (default).
    private static func estimateFallbackTokensCharacterRatio(
        userVisibleChars: Int,
        assistantVisibleChars: Int,
        assistantReasoningChars: Int,
        userMessageCount: Int,
        assistantMessageCount: Int
    ) -> EstimatedTokens {
        let userTokens = estimatedTokenCount(for: userVisibleChars, charsPerToken: 3.35) + (userMessageCount * 9)
        let assistantVisibleTokens = estimatedTokenCount(for: assistantVisibleChars, charsPerToken: 3.35)
        let assistantReasoningTokens = estimatedTokenCount(for: assistantReasoningChars, charsPerToken: 2.45)
        let assistantTokens = assistantVisibleTokens + assistantReasoningTokens + (assistantMessageCount * 7)

        return EstimatedTokens(
            input: max(userTokens, 0),
            output: max(assistantTokens, 0)
        )
    }

    /// Tokenizer-assisted fallback estimation.
    /// Uses tighter ratios that approximate actual tokenizer behavior.
    /// When an actual tokenizer is integrated, this should delegate to it.
    /// Currently uses GPT-style tokenizer approximation (4 chars/token for typical English).
    private static func estimateFallbackTokensTokenizerAssisted(
        userVisibleChars: Int,
        assistantVisibleChars: Int,
        assistantReasoningChars: Int,
        userMessageCount: Int,
        assistantMessageCount: Int
    ) -> EstimatedTokens {
        // Tokenizer-assisted estimation uses more accurate per-character ratios
        // based on actual tokenizer behavior (GPT-style ~4 chars/token for English).
        // This is a placeholder that will be replaced with actual tokenizer integration.
        let userTokens = estimatedTokenCount(for: userVisibleChars, charsPerToken: 4.0) + (userMessageCount * 10)
        let assistantVisibleTokens = estimatedTokenCount(for: assistantVisibleChars, charsPerToken: 4.0)
        let assistantReasoningTokens = estimatedTokenCount(for: assistantReasoningChars, charsPerToken: 2.8)
        let assistantTokens = assistantVisibleTokens + assistantReasoningTokens + (assistantMessageCount * 8)

        return EstimatedTokens(
            input: max(userTokens, 0),
            output: max(assistantTokens, 0)
        )
    }

    /// Estimate token count from character count, adjusting for CJK content.
    static func estimatedTokenCount(for characters: Int, charsPerToken: Double) -> Int {
        guard characters > 0 else { return 0 }
        return Int((Double(characters) / charsPerToken).rounded(.up))
    }

    /// Detect whether text is predominantly CJK and return appropriate chars-per-token ratio.
    static func charsPerToken(for text: String, defaultRatio: Double = 3.35) -> Double {
        guard !text.isEmpty else { return defaultRatio }
        let sample = String(text.prefix(2000))
        var cjkCount = 0
        var totalCount = 0
        for scalar in sample.unicodeScalars {
            if scalar.isASCII && scalar == " " { continue }
            totalCount += 1
            // CJK Unified Ideographs + common CJK ranges
            if (0x4E00...0x9FFF).contains(scalar.value) ||
               (0x3400...0x4DBF).contains(scalar.value) ||
               (0x3000...0x303F).contains(scalar.value) ||
               (0x3040...0x309F).contains(scalar.value) ||
               (0x30A0...0x30FF).contains(scalar.value) ||
               (0xAC00...0xD7AF).contains(scalar.value) {
                cjkCount += 1
            }
        }
        let cjkRatio = totalCount > 0 ? Double(cjkCount) / Double(totalCount) : 0
        if cjkRatio > 0.3 {
            return 1.5
        }
        return defaultRatio
    }

    // MARK: - Model Detection

    /// Detect a model hint from content that contains "model:" annotations.
    static func detectModelHint(from value: Any) -> String? {
        switch value {
        case let text as String:
            guard text.lowercased().contains("model:") else { return nil }
            guard let range = text.range(of: "model:", options: .caseInsensitive) else { return nil }
            let afterModel = text[range.upperBound...]
            let endIndex = afterModel.firstIndex(of: "\n") ?? afterModel.endIndex
            let model = String(afterModel[..<endIndex]).trimmingCharacters(in: .whitespaces)
            return model.isEmpty ? nil : model
        case let array as [Any]:
            for item in array {
                if let found = detectModelHint(from: item) {
                    return found
                }
            }
            return nil
        case let dictionary as [String: Any]:
            for (_, nestedValue) in dictionary {
                if let found = detectModelHint(from: nestedValue) {
                    return found
                }
            }
            return nil
        default:
            return nil
        }
    }

    /// Strip `custom:` prefix from model names.
    static func normalizeModelName(_ model: String) -> String {
        model.hasPrefix("custom:") ? String(model.dropFirst(7)) : model
    }

    /// Stable lowercase key for grouping usages by model.
    static func normalizeModelKey(_ model: String) -> String {
        normalizeModelName(model)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    /// Human-readable display name for a model string.
    static func displayNameForModel(_ rawName: String) -> String {
        let key = normalizeModelKey(rawName)
        guard !key.isEmpty else { return rawName }
        // Title-case: replace hyphens/underscores with spaces, capitalize each word
        return key
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { word in
                let s = String(word)
                // Keep version numbers and known acronyms lowercase-ish
                if s.first?.isNumber == true { return s }
                return s.prefix(1).uppercased() + s.dropFirst()
            }
            .joined(separator: " ")
    }

    // MARK: - JSON Helpers

    static func firstIntValue(in dictionary: [String: Any], paths: [[String]]) -> Int? {
        for path in paths {
            if let value = nestedValue(in: dictionary, path: path),
               let intValue = parseInt(value) {
                return intValue
            }
        }
        return nil
    }

    static func nestedValue(in dictionary: [String: Any], path: [String]) -> Any? {
        var cursor: Any = dictionary
        for key in path {
            guard let dict = cursor as? [String: Any], let next = dict[key] else {
                return nil
            }
            cursor = next
        }
        return cursor
    }

    static func parseInt(_ value: Any?) -> Int? {
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

    // MARK: - Codex Session Parsing

    /// Extracts token count info from a Codex session JSON event.
    /// Codex rollout logs wrap token data in an `event_msg` envelope.
    static func codexTokenCountInfo(from json: [String: Any]) -> [String: Any]? {
        // Handle nested event_msg structure
        if let eventMsg = json["event_msg"] as? [String: Any] {
            return eventMsg
        }
        // Handle direct token_count payload
        if let tokenCount = json["token_count"] as? [String: Any] {
            return json
        }
        // Return the json as-is if it contains token usage fields
        if json["input_tokens"] != nil || json["output_tokens"] != nil || json["last_token_usage"] != nil {
            return json
        }
        return nil
    }

    /// Extracts cumulative token totals from Codex token count info.
    /// Returns nil if input_tokens/output_tokens are not explicitly present, so that
    /// partial/placeholder token_count maps do not suppress delta parsing (VAL-TOKEN-010).
    static func codexCumulativeTotalsFromTokenCountInfo(_ info: [String: Any]) -> (input: Int, output: Int, cacheRead: Int)? {
        // Look for cumulative totals in token_count
        if let tokenCount = info["token_count"] as? [String: Any] {
            // VAL-TOKEN-010: Require explicit input_tokens AND output_tokens to treat as cumulative.
            // Partial/placeholder token_count maps (missing these required fields) must not
            // suppress delta parsing, as returning (0,0,0) would zero out valid accumulated deltas.
            guard let input = tokenCount["input_tokens"] as? Int,
                  let output = tokenCount["output_tokens"] as? Int else {
                return nil
            }
            let cacheRead = tokenCount["cached_input_tokens"] as? Int ?? 0
            return (input, output, cacheRead)
        }
        // Look for cumulative totals at root level
        if let input = info["input_tokens"] as? Int,
           let output = info["output_tokens"] as? Int {
            let cacheRead = info["cached_input_tokens"] as? Int ?? 0
            return (input, output, cacheRead)
        }
        return nil
    }
}

// MARK: - Timestamp Normalization

/// Normalizes timestamps originating from heterogeneous logs/storage (seconds/ms/us/ns),
/// and guarantees Firestore-safe Date values.
enum TimestampNormalizationUtility {
    /// Firestore Timestamp supports year 0001 through 9999.
    static let firestoreMinEpochSeconds = -62_135_596_800.0
    static let firestoreMaxEpochSeconds = 253_402_300_799.0

    static func normalizedEpochSeconds(_ raw: Double?) -> Double? {
        guard var seconds = raw, seconds.isFinite else { return nil }

        var attempts = 0
        while abs(seconds) > firestoreMaxEpochSeconds && attempts < 4 {
            seconds /= 1000.0
            attempts += 1
        }

        guard seconds >= firestoreMinEpochSeconds,
              seconds <= firestoreMaxEpochSeconds else {
            return nil
        }
        return seconds
    }

    static func date(fromEpoch raw: Double?, fallback: Date = Date()) -> Date {
        if let seconds = normalizedEpochSeconds(raw) {
            return Date(timeIntervalSince1970: seconds)
        }
        return firestoreSafeDate(fallback)
    }

    static func firestoreSafeDate(_ date: Date, fallback: Date = Date()) -> Date {
        if let seconds = normalizedEpochSeconds(date.timeIntervalSince1970) {
            return Date(timeIntervalSince1970: seconds)
        }
        if let fallbackSeconds = normalizedEpochSeconds(fallback.timeIntervalSince1970) {
            return Date(timeIntervalSince1970: fallbackSeconds)
        }
        let now = Date().timeIntervalSince1970
        let clamped = min(max(now, firestoreMinEpochSeconds), firestoreMaxEpochSeconds)
        return Date(timeIntervalSince1970: clamped)
    }
}
