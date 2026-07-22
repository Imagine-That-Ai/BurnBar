import Foundation

// MARK: - FTS query shaping (shared app + daemon)

/// Builds SQLite FTS5 `MATCH` strings for `search_chunks_fts` / `conversations_fts`.
public enum BurnBarFTSQueryBuilder {
    /// Legacy behavior: every token must match (strict AND). Good for short keyword queries.
    public static func strictAnd(from userInput: String) -> String {
        let parts = userInput.split { $0.isWhitespace || $0.isNewline }.map(String.init).filter { !$0.isEmpty }
        guard !parts.isEmpty else { return "" }
        return parts.map { token in
            let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }.joined(separator: " AND ")
    }

    /// Natural-language friendly: strips common English stopwords, then ORs remaining salient tokens.
    /// Longer queries use OR to improve recall; very short queries stay AND for precision.
    public static func naturalLanguage(from userInput: String) -> String {
        let trimmed = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let rawParts = trimmed.split { $0.isWhitespace || $0.isNewline }.map(String.init)
        let lowered = rawParts.map { $0.lowercased() }
        let filtered = lowered.filter { token in
            token.count >= 2 && Self.englishStopwords.contains(token) == false
        }

        let parts: [String]
        if filtered.isEmpty {
            parts = rawParts.map { $0.lowercased() }
        } else {
            parts = filtered
        }

        guard !parts.isEmpty else { return "" }

        let useOr = trimmed.count > 48 || parts.count >= 5
        let unique = Array(Set(parts)).sorted()

        if useOr {
            return unique.map { token in
                let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
                return "\"\(escaped)\""
            }.joined(separator: " OR ")
        }

        if unique.count <= 3 {
            return unique.map { token in
                let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
                return "\"\(escaped)\""
            }.joined(separator: " AND ")
        }

        return unique.map { token in
            let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }.joined(separator: " OR ")
    }

    /// Precision-first lookup query: keeps salient tokens, preserves explicit field hints,
    /// and ANDs every retained term to favor exact keyword matching over recall.
    public static func lookupPrecision(from userInput: String) -> String {
        let tokens = lookupPrecisionTokens(from: userInput)
        guard !tokens.isEmpty else { return "" }

        return tokens.map { token in
            let escaped = escapeToken(token.text)
            let formatted: String
            if token.isQuotedPhrase {
                formatted = "\"\(escaped)\""
            } else {
                formatted = "\"\(escaped)\""
            }

            if let field = token.fieldHint {
                return "\(field.ftsColumnName):\(formatted)"
            }
            return formatted
        }.joined(separator: " AND ")
    }

    /// Returns `true` when the query is short and keyword-like enough that semantic
    /// similarity is more likely to introduce noise than help.
    public static func prefersLookupPrecision(from userInput: String) -> Bool {
        !BurnBarLookupQueryHeuristics.allowsSemanticExpansion(for: userInput)
    }

    /// Common English stopwords for NL retrieval (not exhaustive).
    public static let englishStopwords: Set<String> = Set([
        "a", "an", "the", "and", "or", "but", "if", "then", "else", "when", "where", "why", "how",
        "what", "who", "which", "is", "are", "was", "were", "be", "been", "being", "to", "of", "in",
        "on", "for", "with", "about", "into", "from", "at", "by", "as", "it", "its", "this", "that",
        "these", "those", "i", "you", "we", "they", "he", "she", "my", "your", "our", "their", "me",
        "him", "her", "them", "do", "does", "did", "have", "has", "had", "can", "could", "would",
        "should", "will", "just", "not", "no", "yes", "so", "very", "too", "also", "only", "even",
        "there", "here", "some", "any", "all", "each", "every", "both", "few", "more", "most", "other",
        "such", "than", "up", "out", "off", "over", "under", "again", "once", "ever", "please", "tell",
        "give", "show", "find", "search", "look", "get", "got", "make", "made", "using", "use", "used",
        "instance", "ive", "entered", "enterd", "entering", "thread", "conversation", "session"
    ])
}

/// Heuristics for precision-first search surfaces such as indexed-session lookup.
public enum BurnBarLookupQueryHeuristics {
    /// Returns `true` when search-box queries should allow semantic expansion beyond lexical hits.
    /// Single-term, quoted, or field-targeted lookups stay lexical-only for precision.
    public static func allowsSemanticExpansion(for userInput: String) -> Bool {
        let trimmed = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return false }

        let tokens = BurnBarFTSQueryBuilder.extractTokens(from: trimmed)
        guard tokens.isEmpty == false else { return false }

        if tokens.contains(where: { $0.isQuotedPhrase || $0.fieldHint != nil }) {
            return false
        }

        let significantCount = significantTerms(from: tokens).count
        if significantCount <= 1 {
            return false
        }

        // Short code-ish lookups often contain separators like paths, IDs, or field syntax.
        if significantCount <= 4,
           trimmed.range(of: #"[._/#:@\-]"#, options: .regularExpression) != nil {
            return false
        }

        return true
    }

    static func significantTerms(from tokens: [BurnBarFTSQueryBuilder.QueryToken]) -> [String] {
        tokens
            .flatMap { token in
                token.text
                    .lowercased()
                    .split { $0.isWhitespace || $0.isNewline || $0.isPunctuation }
                    .map(String.init)
            }
            .filter { term in
                term.count >= 2 && BurnBarFTSQueryBuilder.englishStopwords.contains(term) == false
            }
    }
}

// MARK: - Field-boosted FTS query building

/// Field names available for multi-field FTS5 queries.
public enum BurnBarFTSField: String, CaseIterable, Sendable {
    case title
    case subtitle
    case bodyPreview
    case projectName
    case provider
    case chunkText

    /// The FTS column name in the virtual table.
    public var ftsColumnName: String { rawValue }
}

/// Configuration for field-boosted FTS query generation.
public struct BurnBarFieldBoostConfig: Sendable, Hashable {
    /// Boost multiplier for title field matches (higher = more weight to title).
    public let titleBoost: Double
    /// Boost multiplier for projectName field matches.
    public let projectNameBoost: Double
    /// Boost multiplier for provider field matches.
    public let providerBoost: Double
    /// Boost multiplier for subtitle field matches.
    public let subtitleBoost: Double
    /// Boost multiplier for bodyPreview field matches.
    public let bodyPreviewBoost: Double
    /// Boost multiplier for chunkText field matches.
    public let chunkTextBoost: Double

    public init(
        titleBoost: Double = 4.0,
        projectNameBoost: Double = 2.0,
        providerBoost: Double = 1.5,
        subtitleBoost: Double = 1.0,
        bodyPreviewBoost: Double = 0.8,
        chunkTextBoost: Double = 1.0
    ) {
        self.titleBoost = titleBoost
        self.projectNameBoost = projectNameBoost
        self.providerBoost = providerBoost
        self.subtitleBoost = subtitleBoost
        self.bodyPreviewBoost = bodyPreviewBoost
        self.chunkTextBoost = chunkTextBoost
    }

    /// Default configuration optimized for general search relevance.
    public static let `default` = BurnBarFieldBoostConfig()

    /// Aggressive title weighting for precision-focused queries.
    public static let titleHeavy = BurnBarFieldBoostConfig(
        titleBoost: 8.0,
        projectNameBoost: 3.0,
        providerBoost: 2.0,
        subtitleBoost: 2.0,
        bodyPreviewBoost: 1.0,
        chunkTextBoost: 0.5
    )

    /// Balanced weights for mixed recall/precision.
    public static let balanced = BurnBarFieldBoostConfig()

    /// Equal weighting across all fields.
    public static let uniform = BurnBarFieldBoostConfig(
        titleBoost: 1.0,
        projectNameBoost: 1.0,
        providerBoost: 1.0,
        subtitleBoost: 1.0,
        bodyPreviewBoost: 1.0,
        chunkTextBoost: 1.0
    )

    /// Returns the boost value for a given field.
    public func boost(for field: BurnBarFTSField) -> Double {
        switch field {
        case .title: return titleBoost
        case .subtitle: return subtitleBoost
        case .bodyPreview: return bodyPreviewBoost
        case .projectName: return projectNameBoost
        case .provider: return providerBoost
        case .chunkText: return chunkTextBoost
        }
    }
}

extension BurnBarFTSQueryBuilder {
    /// Token extracted from user input, optionally with field context.
    public struct QueryToken: Sendable, Hashable {
        public let text: String
        public let isQuotedPhrase: Bool
        public let fieldHint: BurnBarFTSField?

        public init(text: String, isQuotedPhrase: Bool = false, fieldHint: BurnBarFTSField? = nil) {
            self.text = text
            self.isQuotedPhrase = isQuotedPhrase
            self.fieldHint = fieldHint
        }
    }

    /// Extracts query tokens from user input, handling quoted phrases and field prefixes.
    /// Supported formats:
    /// - `"exact phrase"` - treated as an exact phrase match
    /// - `field:value` - hint that the token should match in a specific field
    public static func extractTokens(from userInput: String) -> [QueryToken] {
        var tokens: [QueryToken] = []
        var current = ""
        var inQuotes = false
        var quoteContent = ""

        let chars = Array(userInput)
        var i = 0

        while i < chars.count {
            let ch = chars[i]

            if ch == "\"" {
                if inQuotes {
                    // End of quoted phrase
                    let trimmed = quoteContent.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        tokens.append(QueryToken(text: trimmed, isQuotedPhrase: true))
                    }
                    quoteContent = ""
                    inQuotes = false
                } else {
                    // Start of quoted phrase
                    inQuotes = true
                }
                i += 1
                continue
            }

            if inQuotes {
                quoteContent.append(ch)
                i += 1
                continue
            }

            // Check for field:value syntax
            if ch == ":" && !current.isEmpty && i + 1 < chars.count {
                let fieldCandidate = current.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let field: BurnBarFTSField?
                switch fieldCandidate {
                case "title", "t": field = .title
                case "subtitle", "s": field = .subtitle
                case "body", "preview", "bodyPreview", "bp": field = .bodyPreview
                case "project", "projectName", "proj", "pn": field = .projectName
                case "provider", "prov", "p": field = .provider
                case "chunk", "text", "chunkText", "ct": field = .chunkText
                default: field = nil
                }

                if let field {
                    // Consume the colon and accumulate the value
                    i += 1 // skip ':'
                    var valueAccumulator = ""
                    while i < chars.count && !chars[i].isWhitespace && chars[i] != "\"" {
                        valueAccumulator.append(chars[i])
                        i += 1
                    }
                    let value = valueAccumulator.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty {
                        tokens.append(QueryToken(text: value, isQuotedPhrase: false, fieldHint: field))
                    }
                    current = ""
                    continue
                }
            }

            if ch.isWhitespace || ch.isNewline {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    tokens.append(QueryToken(text: trimmed, isQuotedPhrase: false))
                }
                current = ""
            } else {
                current.append(ch)
            }
            i += 1
        }

        // Handle remaining content
        if inQuotes && !quoteContent.isEmpty {
            let trimmed = quoteContent.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                tokens.append(QueryToken(text: trimmed, isQuotedPhrase: true))
            }
        } else {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                tokens.append(QueryToken(text: trimmed, isQuotedPhrase: false))
            }
        }

        return tokens
    }

    /// Escapes a token for FTS5 query safety.
    public static func escapeToken(_ token: String) -> String {
        token.replacingOccurrences(of: "\"", with: "\"\"")
    }

    /// Formats a single token into FTS5 syntax.
    public static func formatToken(_ token: QueryToken) -> String {
        let escaped = escapeToken(token.text)
        if token.isQuotedPhrase {
            return "\"\(escaped)\""
        }
        return "\"\(escaped)\""
    }

    /// Formats a token with optional field prefix for FTS5 MATCH syntax.
    public static func formatFieldToken(_ token: QueryToken) -> String {
        let formatted = formatToken(token)
        if let field = token.fieldHint {
            return "\(field.ftsColumnName):\(formatted)"
        }
        return formatted
    }

    /// Builds a field-boosted FTS5 query using BM25() ranking with field weights.
    /// Returns a query suitable for `search_chunks_fts` or `search_documents_fts`.
    ///
    /// Uses the pattern: `(fieldA:termA OR fieldB:termB) AND (fieldA:termC OR fieldC:termC) ...`
    /// This allows BM25 to naturally rank higher when terms appear in boosted fields.
    public static func fieldBoosted(
        from userInput: String,
        fields: [BurnBarFTSField] = [.title, .chunkText],
        config: BurnBarFieldBoostConfig = .default
    ) -> String {
        let trimmed = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let tokens = extractTokens(from: trimmed)
        guard !tokens.isEmpty else { return "" }

        // Filter to non-stopwords, or keep all if few tokens
        let meaningfulTokens: [QueryToken]
        if tokens.count <= 3 {
            meaningfulTokens = tokens
        } else {
            let filtered = tokens.filter { token in
                if token.isQuotedPhrase { return true }
                let words = token.text.lowercased().split { $0.isWhitespace || $0.isPunctuation }
                return words.contains { englishStopwords.contains(String($0)) == false }
            }
            meaningfulTokens = filtered.isEmpty ? tokens : filtered
        }

        guard !meaningfulTokens.isEmpty else { return "" }

        // Determine if we should use OR (high recall) or AND (high precision) between groups
        let useOrBetweenGroups = meaningfulTokens.count >= 5 || trimmed.count > 48

        // Build the query with field boosting
        var clauses: [String] = []
        clauses.reserveCapacity(meaningfulTokens.count)

        // For field boosting, we create OR groups within each token's alternatives
        // e.g., `(title:term OR projectName:term OR chunkText:term)`
        // Higher-boost fields are placed first (FTS5 BM25 tends to favor earlier terms)
        let sortedFields = fields.sorted { config.boost(for: $0) > config.boost(for: $1) }

        for token in meaningfulTokens {
            if let fieldHint = token.fieldHint {
                // If a specific field is hinted, use only that field
                let formatted = formatToken(token)
                clauses.append("\(fieldHint.ftsColumnName):\(formatted)")
            } else if token.isQuotedPhrase {
                // Quoted phrases get distributed across all fields for maximum recall
                var fieldClauses: [String] = []
                for field in sortedFields {
                    let formatted = formatToken(token)
                    fieldClauses.append("\(field.ftsColumnName):\(formatted)")
                }
                clauses.append("(\(fieldClauses.joined(separator: " OR ")))")
            } else {
                // Regular tokens: distribute across fields
                var fieldClauses: [String] = []
                for field in sortedFields {
                    let formatted = formatToken(token)
                    fieldClauses.append("\(field.ftsColumnName):\(formatted)")
                }
                clauses.append("(\(fieldClauses.joined(separator: " OR ")))")
            }
        }

        let connector = useOrBetweenGroups ? " OR " : " AND "
        return clauses.joined(separator: connector)
    }

    /// Builds a simple field-prefixed query for backward compatibility.
    /// Use this for queries against the multi-field FTS table when field syntax is desired.
    public static func fieldPrefixed(from userInput: String) -> String {
        let trimmed = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let tokens = extractTokens(from: trimmed)
        guard !tokens.isEmpty else { return "" }

        let parts = tokens.map { formatFieldToken($0) }
        return parts.joined(separator: " ")
    }

    private static func lookupPrecisionTokens(from userInput: String) -> [QueryToken] {
        let trimmed = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let extracted = extractTokens(from: trimmed)
        var tokens: [QueryToken] = []
        var seen: Set<String> = []

        for token in extracted {
            let normalized = token.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { continue }

            let lower = normalized.lowercased()
            let keepsPrecision = token.fieldHint != nil
                || token.isQuotedPhrase
                || Self.englishStopwords.contains(lower) == false

            guard keepsPrecision else { continue }
            let dedupeKey = [
                token.fieldHint?.rawValue ?? "_",
                token.isQuotedPhrase ? "quoted" : "plain",
                lower
            ].joined(separator: "|")
            guard seen.insert(dedupeKey).inserted else { continue }

            tokens.append(QueryToken(text: lower, isQuotedPhrase: token.isQuotedPhrase, fieldHint: token.fieldHint))
        }

        if tokens.isEmpty {
            for part in trimmed.split(whereSeparator: { $0.isWhitespace || $0.isNewline }) {
                let normalized = part
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: .punctuationCharacters)
                    .lowercased()
                guard !normalized.isEmpty else { continue }
                guard seen.insert("_|plain|\(normalized)").inserted else { continue }
                tokens.append(QueryToken(text: normalized))
            }
        }

        return tokens
    }
}

// MARK: - High-level query mode

public enum BurnBarSearchQueryMode: String, Codable, Sendable, Hashable {
    /// Topical / semantic hybrid retrieval (default).
    case retrieve
    /// Count occurrences over stored transcripts (fullText / optional chat messages).
    case aggregate
    /// Precision-first lookup / identifier search.
    case lookup
    /// Retrieval plus aggregate summary in one turn.
    case mixed
}

public enum BurnBarSearchRankingIntent: String, Codable, Sendable, Hashable {
    case none
    case top
    case mostOften
    case mostRecent
}

public enum BurnBarSearchAnalysisIntent: String, Codable, Sendable, Hashable {
    case none
    case providerRanking
}

/// Output of the lightweight NL planner (no ML).
public struct BurnBarSearchPlan: Sendable, Hashable {
    public let mode: BurnBarSearchQueryMode
    /// FTS `MATCH` string for lexical search when mode is `.retrieve` or `.mixed`.
    public let lexicalFTSQuery: String
    /// Text passed to semantic embedding (usually the raw user question).
    public let semanticText: String
    /// Lowercased substrings to count in `conversations.fullText` when mode is `.aggregate` or `.mixed`.
    public let aggregatePatterns: [String]
    /// User-requested result/button count like "top 3" or "show 10".
    public let requestedResultCount: Int?
    /// Ranking semantics inferred from the prompt.
    public let rankingIntent: BurnBarSearchRankingIntent
    /// Structured post-search analysis requested by the user.
    public let analysisIntent: BurnBarSearchAnalysisIntent
    /// Human-readable note for prompts / UI.
    public let note: String?

    public init(
        mode: BurnBarSearchQueryMode,
        lexicalFTSQuery: String,
        semanticText: String,
        aggregatePatterns: [String] = [],
        requestedResultCount: Int? = nil,
        rankingIntent: BurnBarSearchRankingIntent = .none,
        analysisIntent: BurnBarSearchAnalysisIntent = .none,
        note: String? = nil
    ) {
        self.mode = mode
        self.lexicalFTSQuery = lexicalFTSQuery
        self.semanticText = semanticText
        self.aggregatePatterns = aggregatePatterns
        self.requestedResultCount = requestedResultCount
        self.rankingIntent = rankingIntent
        self.analysisIntent = analysisIntent
        self.note = note
    }

    public static func plan(userText: String) -> BurnBarSearchPlan {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return BurnBarSearchPlan(mode: .retrieve, lexicalFTSQuery: "", semanticText: "", note: "empty")
        }

        let lower = trimmed.lowercased()
        let requestedResultCount = Self.requestedResultCount(in: lower)
        let rankingIntent = Self.rankingIntent(in: lower)
        let profanityStatsQuestion =
            ((lower.contains("how many") || lower.contains("how often") || lower.contains("number of times"))
                && (lower.contains("curse") || lower.contains("cuss") || lower.contains("swear") || lower.contains("profan")))
            || lower.range(of: #"\b(times have i|times did i)\s+.*\b(curse|cuss|swear|profan)"#, options: .regularExpression) != nil
            || lower.range(of: #"\b(did i|have i)\s+(ever\s+)?(curse|cuss|swear)"#, options: .regularExpression) != nil
        let providerRankingIntent = Self.providerRankingIntent(in: lower)
        let aggregateIntent =
            profanityStatsQuestion
            || providerRankingIntent
            || lower.range(of: #"\b(how many|how often|count|number of times|times did i|times have i)\b"#, options: .regularExpression) != nil
            || (lower.contains("how many") && (lower.contains("time") || lower.contains("times")))

        if aggregateIntent {
            let patterns = Self.extractAggregatePatterns(from: trimmed)
            let fts = BurnBarFTSQueryBuilder.naturalLanguage(from: trimmed)
            return BurnBarSearchPlan(
                mode: .mixed,
                lexicalFTSQuery: fts,
                semanticText: trimmed,
                aggregatePatterns: patterns,
                requestedResultCount: requestedResultCount,
                rankingIntent: rankingIntent,
                analysisIntent: providerRankingIntent ? .providerRanking : .none,
                note: patterns.isEmpty
                    ? "aggregate_intent_without_specific_terms"
                    : "aggregate_plus_retrieval"
            )
        }

        let prefersLookupPrecision = BurnBarFTSQueryBuilder.prefersLookupPrecision(from: trimmed)
        let fts = prefersLookupPrecision
            ? BurnBarFTSQueryBuilder.lookupPrecision(from: trimmed)
            : BurnBarFTSQueryBuilder.naturalLanguage(from: trimmed)
        let note: String? = prefersLookupPrecision ? "lookup_precision" : nil
        return BurnBarSearchPlan(
            mode: prefersLookupPrecision ? .lookup : .retrieve,
            lexicalFTSQuery: fts,
            semanticText: trimmed,
            aggregatePatterns: [],
            requestedResultCount: requestedResultCount,
            rankingIntent: rankingIntent,
            analysisIntent: .none,
            note: note
        )
    }

    /// Pull quoted phrases; else infer a few tokens for vague profanity / emphasis questions.
    private static func extractAggregatePatterns(from text: String) -> [String] {
        var patterns: [String] = []
        let quoted = Self.quotedPhrases(in: text)
        patterns.append(contentsOf: quoted)

        let lower = text.lowercased()
        let sensitivePatterns = exactSensitivePatterns(in: lower)
        if sensitivePatterns.isEmpty == false {
            patterns.append(contentsOf: sensitivePatterns)
        }

        if quoted.isEmpty {
            let explicitStrongLanguage = explicitStrongLanguageTerms(in: lower)
            patterns.append(contentsOf: explicitStrongLanguage)
        }

        if patterns.isEmpty,
           lower.contains("curse") || lower.contains("cuss") || lower.contains("profan") || lower.contains("swear") {
            for w in Self.defaultStrongLanguageSamples where patterns.contains(w) == false {
                patterns.append(w)
            }
        }

        if patterns.isEmpty {
            if let residualPhrase = aggregateResidualPhrase(in: lower) {
                patterns.append(residualPhrase)
            }
        }

        if patterns.isEmpty {
            let filtered = normalizedAggregateTokens(from: lower)
            if filtered.count == 1 {
                patterns.append(filtered[0])
            } else {
                patterns.append(contentsOf: filtered.suffix(3))
            }
        }

        return Array(Set(patterns.map { $0.lowercased() })).filter { !$0.isEmpty }.sorted()
    }

    private static func quotedPhrases(in text: String) -> [String] {
        var out: [String] = []
        var current = ""
        var inQuote = false
        for ch in text {
            if ch == "\"" {
                if inQuote {
                    let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
                    if t.count >= 2 {
                        out.append(t)
                    }
                    current = ""
                    inQuote = false
                } else {
                    inQuote = true
                }
                continue
            }
            if inQuote {
                current.append(ch)
            }
        }
        return out
    }

    /// Small sample list for vague "cursing" questions (user can refine with quotes).
    private static let defaultStrongLanguageSamples: [String] = [
        "fuck", "shit", "damn", "bitch", "asshole", "crap", "hell"
    ]

    /// Words that describe the question framing or time window rather than the phrase to count.
    private static let aggregateNoiseTokens: Set<String> = Set([
        "count", "counts", "frequency", "many", "often", "number",
        "time", "times", "say", "said", "saying", "mention", "mentioned",
        "use", "used", "using", "write", "wrote", "written", "type", "typed",
        "last", "past", "day", "days", "week", "weeks", "month", "months",
        "year", "years", "today", "yesterday", "tonight", "recently", "recent",
        "during", "within", "over", "ago", "ever", "before", "after"
    ])

    private static func explicitStrongLanguageTerms(in lowercasedText: String) -> [String] {
        let tokens = normalizedAggregateTokens(from: lowercasedText)
        return tokens.filter { defaultStrongLanguageSamples.contains($0) }
    }

    private static func exactSensitivePatterns(in lowercasedText: String) -> [String] {
        var patterns: [String] = []
        if lowercasedText.contains("api key") || lowercasedText.contains("api keys") || lowercasedText.contains("apikey") {
            patterns.append(contentsOf: ["api key", "api_key", "apikey"])
        }
        if lowercasedText.contains("token") || lowercasedText.contains("tokens") {
            patterns.append("token")
        }
        if lowercasedText.contains("secret") || lowercasedText.contains("secrets") {
            patterns.append("secret")
        }
        if lowercasedText.contains("password") || lowercasedText.contains("passwords") {
            patterns.append("password")
        }
        if lowercasedText.contains("thank you") {
            patterns.append("thank you")
        }
        return Array(Set(patterns)).sorted()
    }

    private static func aggregateResidualPhrase(in lowercasedText: String) -> String? {
        let residual = stripAggregateScaffolding(from: lowercasedText)
        let tokens = normalizedAggregateTokens(from: residual)
        guard tokens.isEmpty == false else { return nil }
        if tokens.count == 1 {
            return tokens[0]
        }
        if tokens.count <= 4 {
            return tokens.joined(separator: " ")
        }
        return nil
    }

    private static func stripAggregateScaffolding(from lowercasedText: String) -> String {
        var stripped = lowercasedText
        let patterns = [
            #"\b(how many|how often|count|number of times)\b"#,
            #"\b(times have i|times did i|have i|did i|i have|i've|ive)\b"#,
            #"\b(i|me|my|we|our|us)\b"#,
            #"\b(say|said|saying|mention|mentioned|use|used|using|write|wrote|written|type|typed)\b"#
        ]

        for pattern in patterns {
            stripped = stripped.replacingOccurrences(
                of: pattern,
                with: " ",
                options: .regularExpression
            )
        }
        return stripped
    }

    private static func normalizedAggregateTokens(from lowercasedText: String) -> [String] {
        lowercasedText
            .replacingOccurrences(of: #"[^\p{L}\p{N}']+"#, with: " ", options: .regularExpression)
            .split { $0.isWhitespace || $0.isNewline }
            .map(String.init)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { token in
                token.count >= 2
                    && BurnBarFTSQueryBuilder.englishStopwords.contains(token) == false
                    && aggregateNoiseTokens.contains(token) == false
            }
    }

    private static let resultCountWords: [String: Int] = [
        "one": 1,
        "two": 2,
        "three": 3,
        "four": 4,
        "five": 5,
        "six": 6,
        "seven": 7,
        "eight": 8,
        "nine": 9,
        "ten": 10,
        "eleven": 11,
        "twelve": 12
    ]

    private static func requestedResultCount(in lowercasedText: String) -> Int? {
        let numericPatterns = [
            #"\btop\s+(\d{1,3})\b"#,
            #"\b(?:show|return|give|surface|find|open)\s+(?:me\s+)?(?:the\s+)?(?:top\s+)?(\d{1,3})\b"#,
            #"\b(\d{1,3})\s+(?:exact\s+)?(?:jump\s+targets|matches|results|buttons|sessions|threads|conversations)\b"#
        ]
        for pattern in numericPatterns {
            if let value = firstCapturedInteger(in: lowercasedText, pattern: pattern) {
                return max(1, min(value, 24))
            }
        }

        let wordPatterns = [
            #"\btop\s+(one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)\b"#,
            #"\b(?:show|return|give|surface|find|open)\s+(?:me\s+)?(?:the\s+)?(?:top\s+)?(one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)\b"#
        ]
        for pattern in wordPatterns {
            if let word = firstCapturedWord(in: lowercasedText, pattern: pattern),
               let value = resultCountWords[word] {
                return value
            }
        }

        return nil
    }

    private static func rankingIntent(in lowercasedText: String) -> BurnBarSearchRankingIntent {
        if lowercasedText.range(of: #"\b(most recent|latest|newest)\b"#, options: .regularExpression) != nil {
            return .mostRecent
        }
        if lowercasedText.range(of: #"\bmost often\b"#, options: .regularExpression) != nil {
            return .mostOften
        }
        if lowercasedText.range(of: #"\btop\s+(\d+|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)\b"#, options: .regularExpression) != nil {
            return .top
        }
        return .none
    }

    private static func providerRankingIntent(in lowercasedText: String) -> Bool {
        let agentMention = lowercasedText.range(
            of: #"\b(which|what)\s+(agent|assistant|provider|model)\b"#,
            options: .regularExpression
        ) != nil
        let comparative = lowercasedText.range(
            of: #"\b(most often|more often|top)\b"#,
            options: .regularExpression
        ) != nil
        let strongLanguage = lowercasedText.range(
            of: #"\b(curse|cursed|cuss|cussed|swear|swore|swearing|profan|fuck|fucking|shit|damn|bitch|asshole)\b"#,
            options: .regularExpression
        ) != nil
        return agentMention && (comparative || strongLanguage) && strongLanguage
    }

    private static func firstCapturedInteger(in text: String, pattern: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let nsText = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)),
              match.numberOfRanges > 1
        else {
            return nil
        }
        return Int(nsText.substring(with: match.range(at: 1)))
    }

    private static func firstCapturedWord(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let nsText = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)),
              match.numberOfRanges > 1
        else {
            return nil
        }
        return nsText.substring(with: match.range(at: 1)).lowercased()
    }
}

extension BurnBarSearchPlan: Codable {}

extension BurnBarSearchPlan {
    /// True when the query should favor exact lookup semantics over semantic expansion.
    public var prefersLookupPrecision: Bool {
        !BurnBarLookupQueryHeuristics.allowsSemanticExpansion(for: semanticText)
    }

    /// Semantic retrieval should be disabled for lookup-style queries to avoid
    /// returning nearest-neighbor noise for exact keyword lookups.
    public var allowsSemanticSearch: Bool {
        !prefersLookupPrecision
    }
}

// MARK: - Relative time windows (NL → date filter)

/// Maps phrases like “in the last day” to a concrete range for SQL filters.
public enum BurnBarSearchTimeWindow: Sendable {
    /// Returns a range when the question clearly implies a relative window; otherwise `nil`.
    public static func inferredDateRange(
        from userText: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> ClosedRange<Date>? {
        let lower = userText.lowercased()
        let startOfToday = calendar.startOfDay(for: now)

        if lower.range(of: #"\b(last 24 hours|past 24 hours|in the last 24 hours|in the past 24 hours)\b"#, options: .regularExpression) != nil {
            return now.addingTimeInterval(-86_400)...now
        }
        if lower.range(of: #"\b(last day|in the last day|past day|in the past day)\b"#, options: .regularExpression) != nil {
            return now.addingTimeInterval(-86_400)...now
        }
        if lower.range(of: #"\byesterday\b"#, options: .regularExpression) != nil {
            guard let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: startOfToday) else { return nil }
            let yesterdayEnd = startOfToday.addingTimeInterval(-1)
            return yesterdayStart...min(yesterdayEnd, now)
        }
        if lower.range(of: #"\b(last week|past week|in the last week|in the past week)\b"#, options: .regularExpression) != nil {
            guard let weekAgo = calendar.date(byAdding: .day, value: -7, to: now) else { return nil }
            return weekAgo...now
        }
        if lower.range(of: #"\b(last seven days|past seven days|last 7 days|past 7 days)\b"#, options: .regularExpression) != nil {
            guard let d = calendar.date(byAdding: .day, value: -7, to: now) else { return nil }
            return d...now
        }
        if lower.range(of: #"\bthis week\b"#, options: .regularExpression) != nil {
            var c = calendar
            c.minimumDaysInFirstWeek = 4
            let comps = c.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
            guard let weekStart = c.date(from: comps) else { return nil }
            return weekStart...now
        }
        return nil
    }
}

// MARK: - Deterministic Query Expansion (Phase B)

/// Deterministic query expander for expanding acronyms, abbreviations, and project aliases.
/// This is a no-ML approach that uses static mappings and user settings.
public struct BurnBarQueryExpander {

    /// Common programming/tech acronyms that should expand to their full forms.
    public static let commonAcronyms: [String: [String]] = [
        // General programming
        "api": ["application programming interface"],
        "ui": ["user interface"],
        "ux": ["user experience"],
        "cli": ["command line interface"],
        "gui": ["graphical user interface"],
        "ide": ["integrated development environment"],
        "sdk": ["software development kit"],
        "orm": ["object relational mapper", "object relational mapping"],
        "crud": ["create read update delete"],
        "rest": ["representational state transfer"],
        "grpc": ["google remote procedure call"],
        "json": ["javascript object notation"],
        "xml": ["extensible markup language"],
        "html": ["hypertext markup language"],
        "css": ["cascading style sheets"],
        "dom": ["document object model"],
        "sql": ["structured query language"],
        "nosql": ["not only sql", "non relational database"],
        "http": ["hypertext transfer protocol"],
        "https": ["hypertext transfer protocol secure"],
        "tls": ["transport layer security"],
        "ssl": ["secure sockets layer"],
        "tcp": ["transmission control protocol"],
        "udp": ["user datagram protocol"],
        "dns": ["domain name system"],
        "cdn": ["content delivery network"],
        "jwt": ["json web token"],
        "oauth": ["open authorization"],
        "sso": ["single sign on"],
        "mfa": ["multi factor authentication"],
        "2fa": ["two factor authentication"],

        // Code/tech specific
        "tdd": ["test driven development"],
        "bdd": ["behavior driven development"],
        "ddd": ["domain driven design"],
        "oop": ["object oriented programming"],
        "fp": ["functional programming"],
        "mvc": ["model view controller"],
        "mvvm": ["model view viewmodel"],
        "di": ["dependency injection"],
        "ioc": ["inversion of control"],
        "dry": ["don't repeat yourself"],
        "kiss": ["keep it simple stupid"],
        "yagni": ["you aren't gonna need it"],
        "solid": ["single responsibility open closed liskov substitution interface segregation dependency inversion"],
        "ci": ["continuous integration"],
        "cd": ["continuous delivery", "continuous deployment"],
        "devops": ["development operations"],
        "git": ["version control"],
        "ssh": ["secure shell"],
        "vpn": ["virtual private network"],
        "aws": ["amazon web services"],
        "gcp": ["google cloud platform"],
        "azure": ["microsoft azure"],

        // Testing
        "ut": ["unit test"],
        "uit": ["unit integration test"],
        "e2e": ["end to end test"],
        "qa": ["quality assurance"],
        "uat": ["user acceptance test"],

        // Architecture
        "microservices": ["micro services"],
        "saas": ["software as a service"],
        "paas": ["platform as a service"],
        "iaas": ["infrastructure as a service"],
        "faas": ["functions as a service"],
        "serverless": ["serverless computing"],

        // Data
        "etl": ["extract transform load"],
        "olap": ["online analytical processing"],
        "oltp": ["online transaction processing"],
        "bi": ["business intelligence"],

        // AI/ML specific
        "ml": ["machine learning"],
        "ai": ["artificial intelligence"],
        "dl": ["deep learning"],
        "nlp": ["natural language processing"],
        "cv": ["computer vision"],
        "llm": ["large language model"],
        "rag": ["retrieval augmented generation"],
        "ann": ["approximate nearest neighbor"],
        "knn": ["k nearest neighbors"],
        "rnn": ["recurrent neural network"],
        "cnn": ["convolutional neural network"],
        "transformer": ["attention mechanism"]
    ]

    /// Common programming language abbreviations.
    public static let languageAbbreviations: [String: [String]] = [
        "js": ["javascript"],
        "ts": ["typescript"],
        "py": ["python"],
        "rb": ["ruby"],
        "go": ["golang"],
        "rs": ["rust"],
        "kt": ["kotlin"],
        "cs": ["csharp", "c#"],
        "cpp": ["c++", "c plus plus"],
        "swift": ["apple swift"],
        "objc": ["objective c", "objective-c"],
        "lua": ["lua scripting"],
        "r": ["r programming"],
        "scala": ["apache scala"],
        "hs": ["haskell"],
        "ml": ["ocaml", "standard ml"],
        "pl": ["perl"],
        "sh": ["shell", "bash"],
        "ps": ["powershell"],
        "vb": ["visual basic"],
        "fs": ["f#", "f sharp"]
    ]

    /// Synonyms for common technical terms to improve recall.
    public static let synonyms: [String: Set<String>] = [
        "bug": ["issue", "defect", "problem", "error", "crash", "failure"],
        "fix": ["repair", "resolve", "patch", "correct", "remediate"],
        "test": ["verify", "validate", "check", "inspect", "examine"],
        "build": ["compile", "construct", "assemble", "package"],
        "deploy": ["release", "publish", "push", "ship", "launch"],
        "config": ["configuration", "settings", "preferences", "setup"],
        "error": ["exception", "failure", "fault", "mistake"],
        "code": ["source", "implementation", "logic", "program"],
        "function": ["method", "procedure", "routine", "subroutine"],
        "variable": ["var", "parameter", "argument", "field", "property"],
        "database": ["db", "datastore", "data store", "repository"],
        "server": ["backend", "back end", "service", "daemon"],
        "client": ["frontend", "front end", "ui", "interface"],
        "documentation": ["docs", "doc", "guide", "manual"],
        "migration": ["upgrade", "transition", "conversion", "port"],
        "refactor": ["restructure", "reorganize", "rewrite", "improve"],
        "optimize": ["improve", "enhance", "tune", "accelerate"],
        "debug": ["troubleshoot", "diagnose", "investigate"],
        "feature": ["capability", "functionality", "function"],
        "performance": ["speed", "latency", "throughput", "efficiency"]
    ]

    /// Expansion result containing original and expanded terms.
    public struct ExpansionResult: Sendable {
        public let original: String
        public let expandedTerms: [String]
        public let expansions: [Expansion]

        public init(original: String, expandedTerms: [String], expansions: [Expansion]) {
            self.original = original
            self.expandedTerms = expandedTerms
            self.expansions = expansions
        }
    }

    /// A single expansion applied to a term.
    public struct Expansion: Sendable, Hashable {
        public let original: String
        public let expanded: String
        public let type: ExpansionType

        public init(original: String, expanded: String, type: ExpansionType) {
            self.original = original
            self.expanded = expanded
            self.type = type
        }
    }

    public enum ExpansionType: Sendable, Hashable {
        case acronym
        case abbreviation
        case synonym
        case projectAlias
        case userDefined
    }

    private let userDefinedExpansions: [String: [String]]
    private let projectAliases: [String: [String]]
    private let includeSynonyms: Bool
    private let includeAcronyms: Bool

    /// Creates a query expander with optional custom mappings.
    public init(
        userDefinedExpansions: [String: [String]] = [:],
        projectAliases: [String: [String]] = [:],
        includeSynonyms: Bool = true,
        includeAcronyms: Bool = true
    ) {
        self.userDefinedExpansions = userDefinedExpansions
        self.projectAliases = projectAliases
        self.includeSynonyms = includeSynonyms
        self.includeAcronyms = includeAcronyms
    }

    /// Expands a single term using all available expansion strategies.
    public func expandTerm(_ term: String) -> ExpansionResult {
        let normalized = term.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        var allExpansions: [Expansion] = []
        var expandedTerms: [String] = [normalized]
        var seenTerms: Set<String> = [normalized]

        // 1. User-defined expansions (highest priority)
        if let userTerms = userDefinedExpansions[normalized] {
            for userTerm in userTerms {
                let expanded = userTerm.lowercased()
                if !seenTerms.contains(expanded) {
                    seenTerms.insert(expanded)
                    expandedTerms.append(expanded)
                    allExpansions.append(Expansion(original: normalized, expanded: expanded, type: .userDefined))
                }
            }
        }

        // 2. Project aliases
        if let aliases = projectAliases[normalized] {
            for alias in aliases {
                let expanded = alias.lowercased()
                if !seenTerms.contains(expanded) {
                    seenTerms.insert(expanded)
                    expandedTerms.append(expanded)
                    allExpansions.append(Expansion(original: normalized, expanded: expanded, type: .projectAlias))
                }
            }
        }

        // 3. Acronyms
        if includeAcronyms {
            if let acronyms = Self.commonAcronyms[normalized] {
                for acronym in acronyms {
                    let expanded = acronym.lowercased()
                    if !seenTerms.contains(expanded) {
                        seenTerms.insert(expanded)
                        expandedTerms.append(expanded)
                        allExpansions.append(Expansion(original: normalized, expanded: expanded, type: .acronym))
                    }
                }
            }

            // Also check language abbreviations
            if let langs = Self.languageAbbreviations[normalized] {
                for lang in langs {
                    let expanded = lang.lowercased()
                    if !seenTerms.contains(expanded) {
                        seenTerms.insert(expanded)
                        expandedTerms.append(expanded)
                        allExpansions.append(Expansion(original: normalized, expanded: expanded, type: .abbreviation))
                    }
                }
            }
        }

        // 4. Synonyms
        if includeSynonyms {
            if let syns = Self.synonyms[normalized] {
                for syn in syns {
                    let expanded = syn.lowercased()
                    if !seenTerms.contains(expanded) {
                        seenTerms.insert(expanded)
                        expandedTerms.append(expanded)
                        allExpansions.append(Expansion(original: normalized, expanded: expanded, type: .synonym))
                    }
                }
            }
        }

        return ExpansionResult(original: normalized, expandedTerms: expandedTerms, expansions: allExpansions)
    }

    /// Expands all terms in a query string.
    public func expandQuery(_ query: String) -> [ExpansionResult] {
        let tokens = BurnBarFTSQueryBuilder.extractTokens(from: query)
        return tokens.map { expandTerm($0.text) }
    }

    /// Builds an OR-expanded FTS query from user input, with all expansions included.
    public func buildExpandedFTSQuery(
        _ query: String,
        fields: [BurnBarFTSField] = [.title, .chunkText]
    ) -> String {
        let expansions = expandQuery(query)
        var allTerms: [String] = []
        var seenTerms: Set<String> = []

        for result in expansions {
            for term in result.expandedTerms {
                let normalized = term.lowercased()
                if !seenTerms.contains(normalized) {
                    seenTerms.insert(normalized)
                    allTerms.append(normalized)
                }
            }
        }

        guard !allTerms.isEmpty else { return "" }

        // Use OR between expanded terms for maximum recall
        let ftsTerms = allTerms.map { term in
            let escaped = BurnBarFTSQueryBuilder.escapeToken(term)
            return "\"\(escaped)\""
        }

        // Build field-boosted query
        var fieldClauses: [String] = []
        let sortedFields = fields.sorted { BurnBarFieldBoostConfig().boost(for: $0) > BurnBarFieldBoostConfig().boost(for: $1) }

        for term in ftsTerms {
            var clauses: [String] = []
            for field in sortedFields {
                clauses.append("\(field.ftsColumnName):\(term)")
            }
            fieldClauses.append("(\(clauses.joined(separator: " OR ")))")
        }

        return fieldClauses.joined(separator: " OR ")
    }

    /// Returns a summary of all expansions applied to a query.
    public func expansionSummary(for query: String) -> String {
        let expansions = expandQuery(query)
        var lines: [String] = []
        for result in expansions where result.expansions.count > 1 {
            let expanded = result.expandedTerms.dropFirst().joined(separator: ", ")
            lines.append("\"\(result.original)\" expanded to: \(expanded)")
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n")
    }
}

extension BurnBarSearchPlan {
    /// Applies deterministic query expansion to this search plan.
    /// Returns a modified plan with expanded FTS query if expansion found meaningful results.
    public func applyingExpansion(
        _ expander: BurnBarQueryExpander = BurnBarQueryExpander()
    ) -> BurnBarSearchPlan {
        guard !lexicalFTSQuery.isEmpty else { return self }

        let expansionResults = expander.expandQuery(lexicalFTSQuery)
        let hasExpansions = expansionResults.contains { $0.expansions.count > 1 }

        if hasExpansions {
            let expandedQuery = expander.buildExpandedFTSQuery(lexicalFTSQuery)
            let expansionNote = expander.expansionSummary(for: lexicalFTSQuery)
            return BurnBarSearchPlan(
                mode: mode,
                lexicalFTSQuery: expandedQuery,
                semanticText: semanticText,
                aggregatePatterns: aggregatePatterns,
                requestedResultCount: requestedResultCount,
                rankingIntent: rankingIntent,
                analysisIntent: analysisIntent,
                note: expansionNote.isEmpty ? note : expansionNote
            )
        }

        return self
    }
}
