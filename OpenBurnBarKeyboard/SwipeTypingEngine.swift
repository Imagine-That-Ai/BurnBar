import UIKit

// MARK: - Swipe Typing Engine
/// Maps a finger's swipe path across the keyboard to candidate words.
///
/// How it works:
/// 1. As the finger moves, `trackPoint(_:in:)` maps each position to the
///    nearest key using the known QWERTY layout geometry.
/// 2. When the swipe ends, `resolve()` returns up to 3 candidate words
///    whose letters are a subsequence of the visited key sequence.
/// 3. Uses `UITextChecker` to validate candidates against the system dictionary.
@MainActor
final class SwipeTypingEngine {

    // MARK: - Keyboard Layout

    private static let row0 = Array("qwertyuiop")
    private static let row1 = Array("asdfghjkl")
    private static let row2 = Array("zxcvbnm")

    /// Visited key characters in order (may contain duplicates from hovering).
    private var visitedKeys: [Character] = []
    /// De-duplicated path (consecutive duplicates removed).
    private var keyPath: [Character] {
        var result: [Character] = []
        for key in visitedKeys where result.last != key {
            result.append(key)
        }
        return result
    }

    private let textChecker = UITextChecker()
    private let language = "en_US"

    // MARK: - Tracking

    /// Reset state for a new swipe gesture.
    func beginSwipe() {
        visitedKeys.removeAll()
    }

    /// Track a point during the swipe. Call on every drag update.
    ///
    /// - Parameters:
    ///   - point: The finger position in the keyboard grid's coordinate space.
    ///   - gridSize: The total size of the keyboard grid.
    func trackPoint(_ point: CGPoint, in gridSize: CGSize) {
        guard let key = keyAt(point: point, gridSize: gridSize) else { return }
        visitedKeys.append(key)
    }

    /// Resolve the swipe path into candidate words.
    /// Returns up to 3 matching words, ranked by length (longest first).
    func resolve() -> [String] {
        let path = keyPath
        guard path.count >= 2 else { return [] }

        let pathString = String(path)
        var candidates: [(word: String, score: Int)] = []

        // Strategy 1: Try completions from the first letter
        let firstLetter = String(path[0])
        let completions = textChecker.completions(
            forPartialWordRange: NSRange(location: 0, length: 1),
            in: firstLetter,
            language: language
        ) ?? []

        for word in completions {
            let lower = word.lowercased()
            guard lower.count >= 2, lower.count <= path.count else { continue }
            if isSubsequence(word: lower, of: path) {
                candidates.append((lower, lower.count))
            }
        }

        // Strategy 2: Also try building words from the exact path
        // Take first + last letter and check dictionary
        if path.count >= 3 {
            let firstChar = path[0]
            let lastChar = path[path.count - 1]
            let prefix = String(firstChar)

            let moreCompletions = textChecker.completions(
                forPartialWordRange: NSRange(location: 0, length: prefix.utf16.count),
                in: prefix,
                language: language
            ) ?? []

            for word in moreCompletions {
                let lower = word.lowercased()
                guard lower.count >= 2,
                      lower.count <= path.count + 2,
                      lower.last == lastChar,
                      isSubsequence(word: lower, of: path) else { continue }

                if !candidates.contains(where: { $0.word == lower }) {
                    // Bonus score for matching last letter
                    candidates.append((lower, lower.count + 3))
                }
            }
        }

        // Strategy 3: Check common short words directly
        let shortWords = commonWordsStartingWith(path[0])
        for word in shortWords {
            guard isSubsequence(word: word, of: path) else { continue }
            if !candidates.contains(where: { $0.word == word }) {
                candidates.append((word, word.count))
            }
        }

        // Sort by score (highest first) and return top 3
        candidates.sort { $0.score > $1.score }
        return Array(candidates.prefix(3).map(\.word))
    }

    // MARK: - Geometry

    /// Maps a point in the keyboard grid to the nearest key character.
    private func keyAt(point: CGPoint, gridSize: CGSize) -> Character? {
        let width = gridSize.width
        let rowHeight: CGFloat = 42
        let rowSpacing: CGFloat = 10
        let keySpacing: CGFloat = 6

        // Determine which row
        let row: Int
        let y = point.y
        if y < rowHeight {
            row = 0
        } else if y < rowHeight * 2 + rowSpacing {
            row = 1
        } else if y < rowHeight * 3 + rowSpacing * 2 {
            row = 2
        } else {
            return nil // Row 4 (space/return) — not used for swiping
        }

        let keys: [Character]
        let inset: CGFloat
        let keyCount: Int

        switch row {
        case 0:
            keys = Self.row0
            inset = 0
            keyCount = 10
        case 1:
            keys = Self.row1
            inset = 18
            keyCount = 9
        case 2:
            keys = Self.row2
            inset = 48  // shift(42) + spacing(6)
            keyCount = 7
        default:
            return nil
        }

        let availableWidth = width - inset * 2
        let totalSpacing = CGFloat(keyCount - 1) * keySpacing
        let keyWidth = (availableWidth - totalSpacing) / CGFloat(keyCount)

        let x = point.x - inset
        guard x >= 0, x <= availableWidth else { return nil }

        let keyIndex = Int(x / (keyWidth + keySpacing))
        guard keyIndex >= 0, keyIndex < keys.count else { return nil }
        return keys[keyIndex]
    }

    // MARK: - Word Matching

    /// Checks if `word` is a subsequence of the `path` characters.
    /// Each letter of the word must appear in the path in order.
    private func isSubsequence(word: String, of path: [Character]) -> Bool {
        var pathIdx = 0
        for char in word {
            while pathIdx < path.count {
                if path[pathIdx] == char {
                    pathIdx += 1
                    break
                }
                pathIdx += 1
            }
            if pathIdx > path.count { return false }
        }
        return true
    }

    /// Common English words grouped by first letter for fast lookup.
    private func commonWordsStartingWith(_ char: Character) -> [String] {
        switch char {
        case "a": return ["a", "an", "and", "are", "at", "all", "also", "about", "after", "any", "am", "ask", "able", "again", "away"]
        case "b": return ["be", "but", "by", "been", "back", "big", "best", "before", "because", "both", "being", "between", "better"]
        case "c": return ["can", "come", "could", "call", "case", "close", "cool", "check", "change", "city", "came", "car"]
        case "d": return ["do", "did", "day", "down", "don't", "does", "done", "dear", "dear", "data", "during", "different"]
        case "e": return ["each", "even", "end", "every", "early", "email", "enough", "else", "ever", "either", "enjoy", "easy"]
        case "f": return ["for", "from", "first", "find", "few", "far", "feel", "free", "full", "family", "friend", "fine", "fun"]
        case "g": return ["get", "go", "good", "got", "give", "great", "going", "group", "game", "girl", "guy", "given"]
        case "h": return ["have", "has", "had", "he", "her", "his", "here", "how", "home", "help", "him", "high", "hello", "happy", "hope"]
        case "i": return ["i", "in", "is", "it", "if", "its", "into"]
        case "j": return ["just", "job", "join"]
        case "k": return ["know", "keep", "kind", "key", "kid"]
        case "l": return ["like", "long", "look", "let", "life", "last", "little", "love", "late", "left", "lot", "live", "line"]
        case "m": return ["my", "me", "more", "make", "may", "much", "most", "many", "made", "might", "man", "must", "meet", "message"]
        case "n": return ["no", "not", "now", "new", "need", "never", "next", "nice", "name", "night", "note", "nothing", "number"]
        case "o": return ["of", "on", "or", "one", "out", "our", "only", "other", "over", "ok", "open", "order", "old", "off"]
        case "p": return ["people", "place", "part", "point", "put", "play", "please", "problem", "plan", "phone", "pm"]
        case "q": return ["question", "quite", "quick", "quality"]
        case "r": return ["right", "really", "run", "read", "real"]
        case "s": return ["so", "some", "said", "she", "see", "say", "same", "should", "still", "such", "sure", "send", "set", "since", "sorry", "soon", "sounds"]
        case "t": return ["the", "to", "that", "this", "they", "than", "then", "there", "their", "them", "think", "time", "two", "too", "take", "tell", "thanks", "through", "today", "try"]
        case "u": return ["up", "us", "use", "under", "until", "upon", "update"]
        case "v": return ["very", "view"]
        case "w": return ["we", "was", "with", "will", "what", "when", "where", "who", "which", "would", "want", "work", "way", "well", "were", "why", "while", "week", "world"]
        case "x": return []
        case "y": return ["you", "your", "yes", "yet", "yeah", "year"]
        case "z": return []
        default: return []
        }
    }
}
