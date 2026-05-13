import Foundation

// MARK: - Settings Search Engine

/// Ranks `SettingsItem`s against a free-form query using weighted token hits
/// across `title` (weight 3), `keywords` (weight 2), `subtitle` (weight 2),
/// and `helpText` (weight 1).
///
/// Match semantics:
/// - Query is lowercased and diacritic-folded; the same is applied to each
///   row field once at construction time (per-call here since manifests are
///   small).
/// - Whitespace-separated query tokens use AND semantics — every token must
///   hit *some* field for the row to qualify.
/// - Score is the sum of weighted hits across fields. Tied scores break by
///   `title` ascending.
/// - Returns at most `maxResults` (default 25).
///
/// Performance: linear scan over the manifest. With ~140 items × ~3 tokens
/// the scan is sub-millisecond on any current Mac.
enum SettingsSearchEngine {

    /// Weight applied to a hit in the matching field.
    enum Weight {
        static let title = 3
        static let keyword = 2
        static let subtitle = 2
        static let helpText = 1
    }

    static let defaultResultLimit = 25

    /// Returns ranked matches for `query` across `items`.
    /// An empty / whitespace-only query yields an empty array.
    static func search(
        _ query: String,
        in items: [SettingsItem],
        limit: Int = defaultResultLimit
    ) -> [SettingsItem] {
        let tokens = tokenize(query)
        guard !tokens.isEmpty else { return [] }

        // Score every row that satisfies AND-semantics on tokens.
        let scored: [(item: SettingsItem, score: Int)] = items.compactMap { item in
            guard let score = score(item: item, tokens: tokens) else { return nil }
            return (item, score)
        }

        let ranked = scored.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return foldedTitle(lhs.item) < foldedTitle(rhs.item)
        }

        return Array(ranked.prefix(limit).map(\.item))
    }

    // MARK: - Internals

    /// Scoring honors AND semantics. Returns `nil` if any token fails to hit
    /// any indexed field on the row.
    static func score(item: SettingsItem, tokens: [String]) -> Int? {
        let title = foldedTitle(item)
        let keywords = item.keywords.map(Self.fold)
        let subtitle = item.subtitle.map(Self.fold) ?? ""
        let helpText = item.helpText.map(Self.fold) ?? ""

        var total = 0
        for token in tokens {
            var tokenScore = 0
            if title.contains(token) { tokenScore += Weight.title }
            if keywords.contains(where: { $0.contains(token) }) {
                tokenScore += Weight.keyword
            }
            if !subtitle.isEmpty, subtitle.contains(token) {
                tokenScore += Weight.subtitle
            }
            if !helpText.isEmpty, helpText.contains(token) {
                tokenScore += Weight.helpText
            }

            if tokenScore == 0 { return nil }
            total += tokenScore
        }
        return total
    }

    /// Lowercase + diacritic-fold a string for substring matching.
    static func fold(_ input: String) -> String {
        input.folding(options: [.diacriticInsensitive, .caseInsensitive],
                      locale: .current)
    }

    /// Tokenize a query string into whitespace-separated, folded tokens.
    static func tokenize(_ query: String) -> [String] {
        fold(query)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private static func foldedTitle(_ item: SettingsItem) -> String {
        fold(item.title)
    }
}
