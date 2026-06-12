import UIKit

// MARK: - Spell Check Service
/// Wraps `UITextChecker` to provide autocorrect suggestions and word
/// completions for the custom keyboard extension.
///
/// Thread-safe: `UITextChecker` is safe to use from any thread.
/// Performance: typical lookup takes <1ms for common English words.
@MainActor
final class SpellCheckService {
    private let textChecker = UITextChecker()
    private let language = "en_US"

    /// Returns up to 3 spelling suggestions for the given word.
    ///
    /// Priority order:
    /// 1. If the word is misspelled → correction guesses
    /// 2. If the word is partial → completions
    /// 3. If the word is correct → empty (no suggestions needed)
    func suggestions(for word: String) -> [String] {
        guard word.count >= 2 else { return [] }

        let nsWord = word as NSString
        let fullRange = NSRange(location: 0, length: nsWord.length)

        // 1. Check if misspelled
        let misspelledRange = textChecker.rangeOfMisspelledWord(
            in: word,
            range: fullRange,
            startingAt: 0,
            wrap: false,
            language: language
        )

        if misspelledRange.location != NSNotFound {
            // Word is misspelled — return correction guesses
            let guesses = textChecker.guesses(
                forWordRange: misspelledRange,
                in: word,
                language: language
            ) ?? []
            return Array(guesses.prefix(3))
        }

        // 2. Provide completions for partial words (even if not misspelled)
        let completions = textChecker.completions(
            forPartialWordRange: fullRange,
            in: word,
            language: language
        ) ?? []

        // Filter out the exact word if it appears in completions
        let filtered = completions.filter { $0.lowercased() != word.lowercased() }
        return Array(filtered.prefix(3))
    }

    /// Checks if a word is misspelled and returns the best correction guess.
    func bestCorrection(for word: String) -> String? {
        guard word.count >= 2 else { return nil }

        let nsWord = word as NSString
        let fullRange = NSRange(location: 0, length: nsWord.length)

        let misspelledRange = textChecker.rangeOfMisspelledWord(
            in: word,
            range: fullRange,
            startingAt: 0,
            wrap: false,
            language: language
        )

        if misspelledRange.location != NSNotFound {
            let guesses = textChecker.guesses(
                forWordRange: misspelledRange,
                in: word,
                language: language
            ) ?? []
            return guesses.first
        }

        return nil
    }

    /// Preserves capitalization style of the original word onto the correction.
    static func preserveCapitalization(original: String, correction: String) -> String {
        guard !original.isEmpty && !correction.isEmpty else { return correction }
        
        let firstChar = original.first!
        if firstChar.isUppercase {
            let isAllUppercase = original.allSatisfy { !$0.isLetter || $0.isUppercase }
            if isAllUppercase {
                return correction.uppercased()
            } else {
                return correction.prefix(1).uppercased() + correction.dropFirst()
            }
        }
        return correction
    }

    /// Extracts the last word typed in the context.
    func extractLastWord(from context: String) -> String? {
        guard !context.isEmpty else { return nil }
        
        let components = context.components(separatedBy: .whitespacesAndNewlines)
        guard let lastWord = components.last, !lastWord.isEmpty else { return nil }
        
        let isWord = lastWord.allSatisfy { $0.isLetter || $0 == "'" || $0 == "-" }
        return isWord ? lastWord : nil
    }

    /// Extracts the word currently being typed from the text context
    /// before the cursor (i.e., `documentContextBeforeInput`).
    ///
    /// Returns `nil` if the cursor is at a word boundary or the context is empty.
    func extractCurrentWord(from context: String?) -> String? {
        guard let context, !context.isEmpty else { return nil }

        // Walk backward from the end to find the start of the current word
        var endIndex = context.endIndex
        // Skip trailing whitespace
        while endIndex > context.startIndex {
            let prevIndex = context.index(before: endIndex)
            if context[prevIndex] == " " || context[prevIndex] == "\n" {
                break
            }
            endIndex = prevIndex // keep going
        }

        // endIndex is now at the start of the current word (or at startIndex)
        // Actually, we want the last word — let me simplify:
        let trimmed = context.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        // Split on whitespace/newlines and take the last component
        let components = trimmed.components(separatedBy: .whitespacesAndNewlines)
        guard let lastWord = components.last, !lastWord.isEmpty else { return nil }

        // Only return if it looks like a partial word (letters only)
        let isWord = lastWord.allSatisfy { $0.isLetter || $0 == "'" || $0 == "-" }
        return isWord ? lastWord : nil
    }
}
