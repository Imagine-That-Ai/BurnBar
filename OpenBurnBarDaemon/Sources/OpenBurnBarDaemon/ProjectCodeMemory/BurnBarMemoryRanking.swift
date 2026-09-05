import Foundation
import OpenBurnBarEngine

/// Deterministic in-process lexical ranking for decrypted project memories.
/// This intentionally mirrors the local MCP engine's tokenizer and BM25 knobs;
/// memory bodies never enter a plaintext FTS table.
enum BurnBarMemoryRanking {
    private static let kindWeights: [String: Double] = [
        "decision": 1.0,
        "gotcha": 1.0,
        "architecture": 0.95,
        "preference": 0.95,
        "profile": 0.9,
        "procedure": 0.85,
        "fact": 0.85,
        "relationship": 0.8,
        "todo": 0.7,
        "event": 0.6,
        "note": 0.6,
        "other": 0.5
    ]
    private static let shortHalfLifeKinds: Set<String> = ["event", "todo"]
    private static let stopwords = Set(
        """
        a an the and or but if then else of to in on at for with by from as is are was were be been being
        it its this that these those there here we you i he she they them his her their our your my me us
        do does did done doing have has had having not no yes so than too very can could should would will
        just also about into over under again further once all any both each few more most other some such
        only own same up down out off through during before after above below between while where when why
        how what which who whom whose because until against
        """.split(whereSeparator: \Character.isWhitespace).map(String.init)
    )

    static func tokenize(_ text: String) -> [String] {
        var output: [String] = []
        let rawTokens = text.split { character in
            isASCIITokenCharacter(character) == false
        }
        for rawSubstring in rawTokens {
            let raw = String(rawSubstring)
            let lowered = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "._/-"))
            guard lowered.isEmpty == false else { continue }
            let subparts = raw.split { $0 == "." || $0 == "_" || $0 == "/" || $0 == "-" }.map(String.init)
            var expanded: [String] = []
            for subpart in subparts {
                if isAcronymPlural(subpart) {
                    expanded.append(String(subpart.dropLast()))
                } else {
                    expanded.append(contentsOf: splitCamelCase(subpart))
                }
            }
            if expanded.count > 1, lowered.count <= 48 {
                output.append(lowered)
            }
            for piece in expanded.map({ $0.lowercased() }) where piece.count >= 2 && stopwords.contains(piece) == false {
                output.append(stem(piece))
            }
        }
        return output
    }

    static func bm25Rank(
        documents: [String: [String]],
        queryTokens: [String],
        limit: Int,
        k1: Double = 1.2,
        b: Double = 0.75
    ) -> [(id: String, score: Double)] {
        guard documents.isEmpty == false, queryTokens.isEmpty == false else { return [] }
        let documentLengths = documents.mapValues(\.count)
        let averageLength = Double(documentLengths.values.reduce(0, +)) / Double(documents.count)
        var documentFrequency: [String: Int] = [:]
        var termFrequency: [String: [String: Int]] = [:]
        for (id, tokens) in documents {
            var counts: [String: Int] = [:]
            for token in tokens { counts[token, default: 0] += 1 }
            termFrequency[id] = counts
            for token in counts.keys { documentFrequency[token, default: 0] += 1 }
        }
        let uniqueQueryTokens = Set(queryTokens)
        let ranked = documents.keys.compactMap { id -> (id: String, score: Double)? in
            guard let counts = termFrequency[id] else { return nil }
            let documentLength = Double(documentLengths[id] ?? 0)
            let normalization = k1 * (1.0 - b + b * (averageLength > 0 ? documentLength / averageLength : 0))
            let score = uniqueQueryTokens.reduce(0.0) { partial, token in
                let frequency = Double(counts[token] ?? 0)
                guard frequency > 0 else { return partial }
                let matches = Double(documentFrequency[token] ?? 0)
                let inverseDocumentFrequency = log(1.0 + (Double(documents.count) - matches + 0.5) / (matches + 0.5))
                return partial + inverseDocumentFrequency * (frequency * (k1 + 1.0)) / (frequency + normalization)
            }
            return score > 0 ? (id, score) : nil
        }
        .sorted { lhs, rhs in lhs.score == rhs.score ? lhs.id < rhs.id : lhs.score > rhs.score }
        return Array(ranked.prefix(max(1, limit)))
    }

    static func reciprocalRankScores(lexical: [String], semantic: [String], k: Double = 60) -> [String: Double] {
        let semanticActive = semantic.isEmpty == false
        let lexicalWeight = semanticActive ? 0.6 : 1.0
        let semanticWeight = semanticActive ? 1.0 : 0.0
        let normalization = (lexicalWeight + semanticWeight) / (k + 1.0)
        var scores: [String: Double] = [:]
        for (index, id) in lexical.enumerated() {
            scores[id, default: 0] += lexicalWeight / (k + Double(index + 1))
        }
        for (index, id) in semantic.enumerated() {
            scores[id, default: 0] += semanticWeight / (k + Double(index + 1))
        }
        guard normalization > 0 else { return [:] }
        return scores.mapValues { $0 / normalization }
    }

    static func salience(kind: String, confidence: Double, accessCount: Int) -> Double {
        let base = (kindWeights[kind] ?? 0.5) * clamp(confidence, minimum: 0.05, maximum: 1.0)
        let boost = min(1.5, 1.0 + 0.1 * log2(1.0 + Double(max(0, accessCount))))
        return clamp(base * boost, minimum: 0, maximum: 1.5)
    }

    static func recencyFactor(kind: String, updatedAt: String, lastAccessedAt: String?, now: Date) -> Double {
        let dates = [parseDate(updatedAt), parseDate(lastAccessedAt)].compactMap { $0 }
        guard let anchor = dates.max() else { return 1.0 }
        let halfLifeDays = shortHalfLifeKinds.contains(kind) ? 30.0 : 365.0
        let ageDays = max(0, now.timeIntervalSince(anchor) / 86_400.0)
        return 0.5 + 0.5 * pow(0.5, ageDays / halfLifeDays)
    }

    private static func isAcronymPlural(_ value: String) -> Bool {
        guard value.count >= 3, value.last == "s" else { return false }
        return value.dropLast().allSatisfy { $0.isLetter && $0.isUppercase }
    }

    private static func isASCIITokenCharacter(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 45, 46, 47, 48...57, 65...90, 95, 97...122:
            return true
        default:
            return false
        }
    }

    private static func splitCamelCase(_ value: String) -> [String] {
        let characters = Array(value)
        guard let first = characters.first else { return [] }
        var pieces: [String] = []
        var current = String(first)
        for index in characters.indices.dropFirst() {
            let character = characters[index]
            let previous = characters[characters.index(before: index)]
            let next = characters.index(after: index) < characters.endIndex
                ? characters[characters.index(after: index)]
                : nil
            let boundary = character.isUppercase
                && (previous.isLowercase || previous.isNumber || (previous.isUppercase && next?.isLowercase == true))
            if boundary {
                pieces.append(current)
                current = String(character)
            } else {
                current.append(character)
            }
        }
        pieces.append(current)
        return pieces
    }

    private static func stem(_ token: String) -> String {
        guard token.count > 2, token.allSatisfy(\.isLetter) else { return token }
        var word = token
        if word.hasSuffix("ies"), word.count > 4 {
            word = String(word.dropLast(3)) + "y"
        } else if word.hasSuffix("sses") {
            word = String(word.dropLast(2))
        } else if word.hasSuffix("es"), word.count > 4,
                  word.hasSuffix("xes") || word.hasSuffix("zes") || word.hasSuffix("ches") || word.hasSuffix("shes") || word.hasSuffix("sses") {
            word = String(word.dropLast(2))
        } else if word.hasSuffix("s"), word.hasSuffix("ss") == false, word.count > 3 {
            word = String(word.dropLast())
        }
        for suffix in ["ingly", "edly", "ing", "ed", "ly", "ence", "ance", "ness", "ment"]
            where word.hasSuffix(suffix) && word.count - suffix.count >= 2 {
            word = String(word.dropLast(suffix.count))
            break
        }
        if word.count >= 3, word.hasSuffix("e") {
            word = String(word.dropLast())
        }
        return word
    }

    private static func clamp(_ value: Double, minimum: Double, maximum: Double) -> Double {
        min(maximum, max(minimum, value))
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        return ThreadSafeISO8601DateFormatter.parse(value)
    }

    // MARK: - Why breakdown (B9)

    /// The ranking report for one fused candidate, in the engine's shape: a
    /// `matchedBy` lane plus the eight-member `why` breakdown, rounded to four
    /// decimals exactly as `_read.py` rounds it.
    ///
    /// Pure reporting. It reads the same lexical/semantic lists and the same
    /// salience/recency values the scorer already computed and writes nothing
    /// back, so a recall's ordering is identical with and without it.
    static func why(
        id: String,
        lexical: [(id: String, score: Double)],
        semantic: [(id: String, score: Double)],
        salience: Double,
        recency: Double,
        rerankScore: Double? = nil,
        reranker: String? = nil
    ) -> (matchedBy: String, why: BurnBarMemoryWhyBreakdown) {
        let lexicalIndex = lexical.firstIndex { $0.id == id }
        let semanticIndex = semantic.firstIndex { $0.id == id }
        let lexicalRank = lexicalIndex.map { $0 + 1 }
        let semanticRank = semanticIndex.map { $0 + 1 }

        let matchedBy: String
        switch (lexicalRank, semanticRank) {
        case (.some, .some): matchedBy = "hybrid"
        case (.some, .none): matchedBy = "lexical"
        case (.none, .some): matchedBy = "semantic"
        case (.none, .none): matchedBy = "browse"
        }

        return (
            matchedBy,
            BurnBarMemoryWhyBreakdown(
                lexicalRank: lexicalRank,
                bm25: lexicalIndex.map { rounded(lexical[$0].score) },
                semanticRank: semanticRank,
                cosine: semanticIndex.map { rounded(semantic[$0].score) },
                salience: rounded(salience),
                recency: rounded(recency),
                rerankScore: rerankScore,
                reranker: reranker
            )
        )
    }

    /// Four decimals, matching `round(value, 4)` on the engine side.
    private static func rounded(_ value: Double) -> Double {
        (value * 10000).rounded() / 10000
    }
}
