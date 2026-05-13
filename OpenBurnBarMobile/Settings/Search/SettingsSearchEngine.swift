import Foundation

// MARK: - Settings Search Engine (iOS)

/// Mirrors the macOS engine — weighted, AND-semantic, diacritic-folded
/// substring matching across `title` / `keywords` / `subtitle` / `helpText`.
///
/// The implementation is intentionally duplicated rather than shared, per
/// the cross-platform plan: keep platforms independent so neither has to
/// move in lockstep with the other for incidental changes.
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
    static func search(
        _ query: String,
        in items: [SettingsItem],
        limit: Int = defaultResultLimit
    ) -> [SettingsItem] {
        let tokens = tokenize(query)
        guard !tokens.isEmpty else { return [] }

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

    static func fold(_ input: String) -> String {
        input.folding(options: [.diacriticInsensitive, .caseInsensitive],
                      locale: .current)
    }

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
