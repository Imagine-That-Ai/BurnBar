import Foundation
import OpenBurnBarCore

// MARK: - Ranking / scoring utilities

extension SearchService {

    internal func normalizedSourceKinds(_ kinds: Set<SearchSourceKind>?) -> [SearchSourceKind]? {
        guard let kinds, kinds.isEmpty == false else { return nil }
        return kinds.sorted { $0.rawValue < $1.rawValue }
    }

    internal func normalizedSourceIDs(_ ids: Set<String>?) -> [String]? {
        guard let ids else { return nil }
        let cleaned = ids
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()
        return cleaned.isEmpty ? nil : cleaned
    }

    internal func matchesFilters(
        document: SearchDocumentRecord,
        conversation: ConversationRecord?,
        filters: RetrievalFilters,
        readableSharedSourceIDs: Set<String>?
    ) -> Bool {
        if let provider = filters.provider, document.provider != provider.rawValue {
            return false
        }

        if let projectName = filters.projectName?.trimmingCharacters(in: .whitespacesAndNewlines), projectName.isEmpty == false {
            if (document.projectName ?? "").caseInsensitiveCompare(projectName) != .orderedSame {
                return false
            }
        }

        if let artifactTypes = filters.artifactTypes, artifactTypes.isEmpty == false, artifactTypes.contains(document.sourceKind) == false {
            return false
        }

        if let sourceIDs = filters.sourceIDs, sourceIDs.isEmpty == false, sourceIDs.contains(document.sourceID) == false {
            return false
        }

        if document.sourceKind == .sharedArtifact {
            guard
                let readableSharedSourceIDs,
                readableSharedSourceIDs.contains(document.sourceID)
            else {
                return false
            }
        }

        switch filters.ownership {
        case .any:
            break
        case .personal:
            if document.sourceKind == .sharedArtifact { return false }
        case .shared:
            if document.sourceKind != .sharedArtifact { return false }
        }

        if let dateRange = filters.dateRange {
            let date = document.sourceUpdatedAt ?? document.indexedAt
            if date < dateRange.lowerBound || date > dateRange.upperBound {
                return false
            }
        }

        if let conversationSources = filters.conversationSources, conversationSources.isEmpty == false {
            guard document.sourceKind == .conversation, let conversation else { return false }
            if conversationSources.contains(conversation.sourceType) == false {
                return false
            }
        }

        return true
    }

    internal func shouldEnforceSharedArtifactAccess(
        filters: RetrievalFilters,
        sourceKinds: [SearchSourceKind]?
    ) -> Bool {
        if filters.ownership == .personal {
            return false
        }

        if let sourceKinds, sourceKinds.contains(.sharedArtifact) == false {
            return false
        }

        if let artifactTypes = filters.artifactTypes,
           artifactTypes.isEmpty == false,
           artifactTypes.contains(.sharedArtifact) == false {
            return false
        }

        return true
    }

    internal func recencyScore(_ date: Date) -> Double {
        let ageSeconds = max(0, nowProvider().timeIntervalSince(date))
        let ageDays = ageSeconds / 86_400
        return 1.0 / (1.0 + (ageDays / 30.0))
    }

    internal func preliminaryScore(for candidate: CandidateAccumulator) -> Double {
        (Self.normalizedLexicalScore(candidate.lexicalRank) * 0.7) + (max(0, candidate.semanticScore ?? 0) * 0.3)
    }

    /// Reciprocal rank fusion across sparse (lexical) and dense (semantic) orderings.
    internal static func reciprocalRankFusion(
        lexicalRank: Int?,
        semanticRank: Int?,
        k: Double
    ) -> Double {
        var score = 0.0
        if let r = lexicalRank { score += 1.0 / (k + Double(r)) }
        if let r = semanticRank { score += 1.0 / (k + Double(r)) }
        return score
    }

    /// Maps RRF raw score to \[0, 1\] given how many retrievers matched this chunk (at rank 1 each would contribute `1/(k+1)`).
    internal static func normalizedRRFForRerank(
        _ raw: Double,
        lexicalRank: Int?,
        semanticRank: Int?,
        k: Double
    ) -> Double {
        let lists = (lexicalRank != nil ? 1 : 0) + (semanticRank != nil ? 1 : 0)
        guard lists > 0 else { return 0 }
        let maxPossible = Double(lists) / (k + 1.0)
        guard maxPossible > 0 else { return 0 }
        return min(1.0, raw / maxPossible)
    }

    internal static func normalizedLexicalScore(_ lexicalRank: Double?) -> Double {
        guard let lexicalRank else { return 0 }
        return 1.0 / (1.0 + abs(lexicalRank))
    }

    internal static func queryTokens(from query: String) -> [String] {
        query
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline || $0.isPunctuation })
            .map(String.init)
            .filter { $0.count >= 2 }
    }

    internal static func exactTokenCoverageScore(tokens: [String], title: String, chunkText: String) -> Double {
        guard tokens.isEmpty == false else { return 0 }
        let loweredTitle = title.lowercased()
        let loweredChunk = chunkText.lowercased()

        var weightedMatches = 0.0
        for token in tokens {
            if loweredTitle.contains(token) {
                weightedMatches += 2.0
            } else if loweredChunk.contains(token) {
                weightedMatches += 1.0
            }
        }

        let denominator = Double(tokens.count) * 2.0
        guard denominator > 0 else { return 0 }
        return min(1.0, weightedMatches / denominator)
    }

    internal static func makeSnippet(lexicalSnippet: String?, chunkText: String, fallback: String) -> String {
        let cleanedLexical = lexicalSnippet?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if cleanedLexical.isEmpty == false {
            return cleanedLexical
        }

        let cleanedChunk = chunkText.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanedChunk.isEmpty == false {
            return String(cleanedChunk.prefix(220))
        }

        return String(fallback.trimmingCharacters(in: .whitespacesAndNewlines).prefix(220))
    }

    static func looksLikeSensitiveExactLookup(_ query: String) -> Bool {
        let lower = query.lowercased()
        let patterns = [
            #"\bapi[\s_\-]?keys?\b"#,
            #"\btoken\b"#,
            #"\bsecret\b"#,
            #"\bpassword\b"#,
            #"\.env\b"#,
            #"\bopenai\b"#,
            #"\banthropic\b"#,
            #"\bglm[\s_\-]?api[\s_\-]?key\b"#
        ]
        return patterns.contains { lower.range(of: $0, options: .regularExpression) != nil }
    }
}

private struct CandidateAccumulator {
    var lexicalRank: Double?
    var semanticScore: Double?
    var lexicalSnippet: String?
}
}
