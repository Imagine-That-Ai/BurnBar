import Foundation

// MARK: - Transcript byte truncation

/// UTF-8-safe truncation shared by the conversation accumulators.
///
/// Both the Claude/Factory accumulator (`ClaudeConversationAccumulator`) and
/// the Codex rollout scanner cap retained transcript text at a byte budget
/// while still counting every message for metrics. Truncation must never
/// split a multi-byte scalar, so both call these helpers instead of keeping
/// private copies.
enum TranscriptByteTruncation {
    /// Truncates a string to at most `maxBytes` UTF-8 bytes without splitting
    /// a multi-byte scalar. Returns a substring of the first complete scalars
    /// whose UTF8 encoding fits within the budget.
    static func truncateToUTF8Bytes(_ string: String, maxBytes: Int) -> String {
        let endIndex = unicodeScalarIndexAfterUTF8Prefix(string, maxBytes: maxBytes)
        return String(string.unicodeScalars[..<endIndex])
    }

    static func unicodeScalarIndexAfterUTF8Prefix(
        _ string: String,
        maxBytes: Int
    ) -> String.UnicodeScalarView.Index {
        guard maxBytes > 0 else { return string.unicodeScalars.startIndex }
        if string.utf8.count <= maxBytes { return string.unicodeScalars.endIndex }

        var usedBytes = 0
        var scalarIndex = string.unicodeScalars.startIndex
        while scalarIndex < string.unicodeScalars.endIndex {
            let scalar = string.unicodeScalars[scalarIndex]
            let scalarBytes = String(scalar).utf8.count
            guard usedBytes + scalarBytes <= maxBytes else { break }
            usedBytes += scalarBytes
            scalarIndex = string.unicodeScalars.index(after: scalarIndex)
        }
        return scalarIndex
    }
}
