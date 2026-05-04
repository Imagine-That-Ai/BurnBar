import Foundation
import GRDB
import OpenBurnBarCore

extension DataStore {
    nonisolated func upsertSearchDocument(_ document: SearchDocumentRecord) throws {
        try searchIndexStore.upsertDocument(document)
    }

    nonisolated func fetchSearchDocuments(limit: Int = 500) throws -> [SearchDocumentRecord] {
        try searchIndexStore.fetchDocuments(limit: limit)
    }

    /// Paginated document fetch using offset-based cursor.
    nonisolated func fetchSearchDocuments(limit: Int, offset: Int) throws -> [SearchDocumentRecord] {
        try searchIndexStore.fetchDocuments(limit: limit, offset: offset)
    }

    nonisolated func fetchSearchDocuments(
        limit: Int = 500,
        provider: AgentProvider? = nil,
        projectName: String? = nil,
        sourceKinds: [SearchSourceKind]? = nil,
        dateRange: ClosedRange<Date>? = nil
    ) throws -> [SearchDocumentRecord] {
        try searchIndexStore.fetchDocuments(
            limit: limit,
            provider: provider?.rawValue,
            projectName: projectName,
            sourceKinds: sourceKinds,
            dateRange: dateRange
        )
    }

    /// Paginated document fetch with filtering using offset-based cursor.
    nonisolated func fetchSearchDocuments(
        limit: Int,
        offset: Int,
        sourceKinds: [SearchSourceKind]?
    ) throws -> [SearchDocumentRecord] {
        try searchIndexStore.fetchDocuments(
            limit: limit,
            offset: offset,
            provider: nil,
            projectName: nil,
            sourceKinds: sourceKinds,
            dateRange: nil
        )
    }

    nonisolated func fetchSearchDocuments(ids: [String]) throws -> [SearchDocumentRecord] {
        try searchIndexStore.fetchDocuments(ids: ids)
    }

    nonisolated func fetchSearchDocument(id: String) throws -> SearchDocumentRecord? {
        try searchIndexStore.fetchDocument(id: id)
    }

    nonisolated func fetchSearchDocuments(sourceKind: SearchSourceKind, sourceID: String) throws -> [SearchDocumentRecord] {
        try searchIndexStore.fetchDocuments(sourceKind: sourceKind, sourceID: sourceID)
    }

    nonisolated func countSearchDocuments(
        provider: AgentProvider? = nil,
        projectName: String? = nil,
        sourceKinds: [SearchSourceKind]? = nil,
        dateRange: ClosedRange<Date>? = nil
    ) throws -> Int {
        try searchIndexStore.countDocuments(
            provider: provider?.rawValue,
            projectName: projectName,
            sourceKinds: sourceKinds,
            dateRange: dateRange
        )
    }

    nonisolated func countSearchChunks(
        sourceKinds: [SearchSourceKind]? = nil,
        dateRange: ClosedRange<Date>? = nil
    ) throws -> Int {
        try searchIndexStore.countChunks(sourceKinds: sourceKinds, dateRange: dateRange)
    }

    nonisolated func countSearchChunks(documentID: String) throws -> Int {
        try searchIndexStore.countChunks(documentID: documentID)
    }

    nonisolated func replaceSearchChunks(documentID: String, title: String, chunks: [SearchChunkRecord]) throws {
        try searchIndexStore.replaceChunks(documentID: documentID, title: title, chunks: chunks)
    }

    /// Incrementally applies a chunk diff for a document.
    /// Compares new chunks against existing chunks by contentHash to minimize writes.
    /// Unchanged chunks (same contentHash AND chunkID) are skipped entirely.
    nonisolated func applySearchChunkDiff(documentID: String, title: String, chunks: [SearchChunkRecord]) throws -> ChunkDiffResult {
        try searchIndexStore.applyChunkDiff(documentID: documentID, title: title, newChunks: chunks)
    }

    /// Fetches existing embeddings keyed by contentHash for a document.
    /// Returns a mapping of contentHash -> (chunkID, vectorBlob) for chunks
    /// that have embeddings for the given version.
    nonisolated func fetchEmbeddingByContentHash(documentID: String, embeddingVersionID: String) throws -> [String: (chunkID: String, vectorBlob: Data)] {
        try searchIndexStore.fetchEmbeddingByContentHash(documentID: documentID, embeddingVersionID: embeddingVersionID)
    }

    nonisolated func fetchSearchChunks(documentID: String) throws -> [SearchChunkRecord] {
        try searchIndexStore.fetchChunks(documentID: documentID)
    }

    nonisolated func fetchSearchChunks(ids: [String]) throws -> [SearchChunkRecord] {
        try searchIndexStore.fetchChunks(ids: ids)
    }

    nonisolated func fetchSearchChunks(sourceKind: SearchSourceKind, sourceID: String) throws -> [SearchChunkRecord] {
        try searchIndexStore.fetchChunks(sourceKind: sourceKind, sourceID: sourceID)
    }

    nonisolated func searchLexicalChunks(
        ftsQuery: String,
        provider: AgentProvider? = nil,
        projectName: String? = nil,
        sourceKinds: [SearchSourceKind]? = nil,
        dateRange: ClosedRange<Date>? = nil,
        visibility: SearchVisibilityScope = .all,
        sharedArtifactAccessContext: SharedArtifactAccessContext? = nil,
        sourceIDs: [String]? = nil,
        limit: Int = 120
    ) throws -> [SearchChunkLexicalMatch] {
        let trimmed = ftsQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return [] }

        return try searchIndexStore.searchLexicalChunks(
            ftsQuery: trimmed,
            provider: provider?.rawValue,
            projectName: projectName,
            sourceKinds: sourceKinds,
            dateRange: dateRange,
            visibility: visibility,
            sharedArtifactAccessContext: sharedArtifactAccessContext,
            sourceIDs: sourceIDs,
            limit: limit
        )
    }

    nonisolated func deleteSearchDocuments(sourceKind: SearchSourceKind, sourceID: String) throws {
        try searchIndexStore.deleteDocuments(sourceKind: sourceKind, sourceID: sourceID)
    }

    /// Sums non-overlapping substring occurrence counts of each pattern in `conversations.fullText` (case-insensitive).
    nonisolated func countOccurrencesInConversationFullText(
        patterns: [String],
        provider: AgentProvider? = nil,
        projectName: String? = nil,
        dateRange: ClosedRange<Date>? = nil,
        conversationSources: Set<ConversationSourceType>? = nil
    ) throws -> Int {
        let cleaned = patterns
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard cleaned.isEmpty == false else { return 0 }

        var total = 0
        for raw in cleaned {
            let pattern = raw.lowercased()
            guard pattern.isEmpty == false else { continue }
            let count = try dbQueue.read { db -> Int in
                var sql = """
                SELECT COALESCE(SUM(
                    (LENGTH(COALESCE(c.fullText,'')) - LENGTH(REPLACE(LOWER(COALESCE(c.fullText,'')), ?, ''))) / LENGTH(?)
                ), 0)
                FROM conversations AS c
                WHERE 1 = 1
                """
                var args: [any DatabaseValueConvertible] = [pattern, pattern]
                if let provider {
                    sql += " AND c.provider = ?"
                    args.append(provider.rawValue)
                }
                if let projectName {
                    sql += " AND c.projectName = ?"
                    args.append(projectName)
                }
                if let range = dateRange {
                    sql += """
                     AND COALESCE(c.endTime, c.startTime, c.fileModifiedAt, c.indexedAt) >= ?
                     AND COALESCE(c.startTime, c.endTime, c.fileModifiedAt, c.indexedAt) <= ?
                    """
                    args.append(range.lowerBound)
                    args.append(range.upperBound)
                }
                if let sources = conversationSources, sources.isEmpty == false {
                    let rawValues = sources.map(\.rawValue)
                    let placeholders = Array(repeating: "?", count: rawValues.count).joined(separator: ", ")
                    sql += " AND c.sourceType IN (\(placeholders))"
                    args.append(contentsOf: rawValues)
                }
                let value = try Int64.fetchOne(db, sql: sql, arguments: StatementArguments(args)) ?? 0
                return Int(value)
            }
            total += count
        }

        return total
    }

    nonisolated func findConversationFullTextMatches(
        patterns: [String],
        provider: AgentProvider? = nil,
        projectName: String? = nil,
        dateRange: ClosedRange<Date>? = nil,
        conversationSources: Set<ConversationSourceType>? = nil,
        limit: Int = 12
    ) throws -> [ConversationJumpTarget] {
        let cleanedPatterns = Array(
            Set(
                patterns
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                    .filter { !$0.isEmpty }
            )
        )
        .sorted()
        let boundedLimit = max(1, min(limit, 200))
        guard cleanedPatterns.isEmpty == false else { return [] }

        // Phase 1: SQL prefilter — only materialise IDs for rows that actually contain a pattern.
        let candidateIDs = try dbQueue.read { db -> [String] in
            var instrConditions: [String] = []
            var args: [any DatabaseValueConvertible] = []
            for pattern in cleanedPatterns {
                instrConditions.append("INSTR(LOWER(COALESCE(c.fullText,'')), ?) > 0")
                args.append(pattern)
            }
            var sql = """
            SELECT DISTINCT c.id
            FROM conversations AS c
            WHERE (\(instrConditions.joined(separator: " OR ")))
            """
            if let provider {
                sql += " AND c.provider = ?"
                args.append(provider.rawValue)
            }
            if let projectName {
                sql += " AND c.projectName = ?"
                args.append(projectName)
            }
            if let range = dateRange {
                sql += """
                 AND COALESCE(c.endTime, c.startTime, c.fileModifiedAt, c.indexedAt) >= ?
                 AND COALESCE(c.startTime, c.endTime, c.fileModifiedAt, c.indexedAt) <= ?
                """
                args.append(range.lowerBound)
                args.append(range.upperBound)
            }
            if let sources = conversationSources, sources.isEmpty == false {
                let rawValues = sources.map(\.rawValue)
                let placeholders = Array(repeating: "?", count: rawValues.count).joined(separator: ", ")
                sql += " AND c.sourceType IN (\(placeholders))"
                args.append(contentsOf: rawValues)
            }
            sql += " ORDER BY COALESCE(c.endTime, c.startTime, c.indexedAt) DESC LIMIT ?"
            args.append(boundedLimit * 3)

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return rows.compactMap { $0["id"] as? String }
        }

        guard !candidateIDs.isEmpty else { return [] }

        // Phase 2: Fetch full records only for the candidate IDs.
        let conversations = try dbQueue.read { db -> [ConversationRecord] in
            let placeholders = Array(repeating: "?", count: candidateIDs.count).joined(separator: ", ")
            let sql = """
            SELECT * FROM conversations
            WHERE id IN (\(placeholders))
            ORDER BY COALESCE(endTime, startTime, indexedAt) DESC
            """
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(candidateIDs))
            return rows.compactMap(ConversationStore.conversation(from:))
        }

        var results: [ConversationJumpTarget] = []
        var seen = Set<String>()

        for conversation in conversations {
            let original = conversation.fullText
            guard original.isEmpty == false else { continue }

            let lowered = original.lowercased() as NSString
            let originalNSString = original as NSString

            for pattern in cleanedPatterns {
                let patternLength = pattern.count
                guard patternLength > 0 else { continue }

                var searchRange = NSRange(location: 0, length: lowered.length)
                while searchRange.length > 0 {
                    let found = lowered.range(of: pattern, options: [], range: searchRange)
                    guard found.location != NSNotFound else { break }

                    let dedupeKey = "\(conversation.id)|\(found.location)|\(found.length)"
                    if seen.insert(dedupeKey).inserted {
                        results.append(
                            ConversationJumpTarget(
                                conversation: conversation,
                                snippet: Self.aggregateMatchSnippet(text: originalNSString, matchRange: found),
                                startOffset: found.location,
                                endOffset: found.location + found.length,
                                source: .aggregateExact
                            )
                        )
                        if results.count >= boundedLimit {
                            return results
                        }
                    }

                    let nextLocation = found.location + max(found.length, 1)
                    guard nextLocation < lowered.length else { break }
                    searchRange = NSRange(location: nextLocation, length: lowered.length - nextLocation)
                }
            }
        }

        return results
    }

    nonisolated func countOccurrencesInConversationFullTextByProvider(
        patterns: [String],
        projectName: String? = nil,
        dateRange: ClosedRange<Date>? = nil,
        conversationSources: Set<ConversationSourceType>? = nil
    ) throws -> [ConversationProviderOccurrence] {
        let cleanedPatterns = Array(
            Set(
                patterns
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                    .filter { !$0.isEmpty }
            )
        )
        .sorted()
        guard cleanedPatterns.isEmpty == false else { return [] }

        return try dbQueue.read { db -> [ConversationProviderOccurrence] in
            var occurrenceExprs: [String] = []
            var instrConditions: [String] = []
            var args: [any DatabaseValueConvertible] = []

            for pattern in cleanedPatterns {
                occurrenceExprs.append(
                    """
                    (LENGTH(COALESCE(c.fullText,'')) - LENGTH(REPLACE(LOWER(COALESCE(c.fullText,'')), ?, ''))) / LENGTH(?)
                    """
                )
                instrConditions.append("INSTR(LOWER(COALESCE(c.fullText,'')), ?) > 0")
                args.append(pattern)
                args.append(pattern)
                args.append(pattern)
            }

            var sql = """
            SELECT c.provider,
                COALESCE(SUM(\(occurrenceExprs.joined(separator: " + "))), 0) AS occurrenceCount,
                COUNT(DISTINCT c.id) AS conversationCount
            FROM conversations AS c
            WHERE (\(instrConditions.joined(separator: " OR ")))
            """

            if let projectName {
                sql += " AND c.projectName = ?"
                args.append(projectName)
            }
            if let range = dateRange {
                sql += """
                 AND COALESCE(c.endTime, c.startTime, c.fileModifiedAt, c.indexedAt) >= ?
                 AND COALESCE(c.startTime, c.endTime, c.fileModifiedAt, c.indexedAt) <= ?
                """
                args.append(range.lowerBound)
                args.append(range.upperBound)
            }
            if let sources = conversationSources, sources.isEmpty == false {
                let rawValues = sources.map(\.rawValue)
                let placeholders = Array(repeating: "?", count: rawValues.count).joined(separator: ", ")
                sql += " AND c.sourceType IN (\(placeholders))"
                args.append(contentsOf: rawValues)
            }
            sql += " GROUP BY c.provider HAVING occurrenceCount > 0"

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return rows.compactMap { row in
                guard let providerRaw = row["provider"] as? String,
                      let provider = AgentProvider(rawValue: providerRaw) else { return nil }
                let occurrenceCount = Int((row["occurrenceCount"] as? Int64) ?? 0)
                let conversationCount = Int((row["conversationCount"] as? Int64) ?? 0)
                return ConversationProviderOccurrence(
                    provider: provider,
                    occurrenceCount: occurrenceCount,
                    conversationCount: conversationCount
                )
            }
            .sorted {
                if $0.occurrenceCount != $1.occurrenceCount {
                    return $0.occurrenceCount > $1.occurrenceCount
                }
                if $0.conversationCount != $1.conversationCount {
                    return $0.conversationCount > $1.conversationCount
                }
                return $0.provider.displayName < $1.provider.displayName
            }
        }
    }

    nonisolated func scanConversationFullTextForCredentialExposure(
        provider: AgentProvider? = nil,
        projectName: String? = nil,
        dateRange: ClosedRange<Date>? = nil,
        conversationSources: Set<ConversationSourceType>? = nil,
        limit: Int = 12
    ) throws -> CredentialExposureScanResult {
        let boundedLimit = max(1, min(limit, 200))
        let regexes = Self.credentialExposureRegexes
        guard regexes.isEmpty == false else {
            return CredentialExposureScanResult(totalMatches: 0, jumpTargets: [])
        }

        let batchSize = 100
        var totalMatches = 0
        var jumpTargets: [ConversationJumpTarget] = []
        var seen = Set<String>()
        var offset = 0

        while jumpTargets.count < boundedLimit {
            let batch = try conversationStore.fetchTranscriptScanBatch(
                provider: provider,
                projectName: projectName,
                dateRange: dateRange,
                conversationSources: conversationSources,
                limit: batchSize,
                offset: offset
            )
            guard !batch.isEmpty else { break }
            offset += batch.count

            for item in batch {
                let text = item.fullText
                guard text.isEmpty == false else { continue }
                let nsText = text as NSString

                for regex in regexes {
                    let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
                    for match in matches {
                        let matchText = nsText.substring(with: match.range)
                        if Self.looksLikePlaceholderCredential(matchText) {
                            continue
                        }

                        let dedupeKey = "\(item.id)|\(match.range.location)|\(match.range.length)"
                        guard seen.insert(dedupeKey).inserted else { continue }

                        totalMatches += 1
                        if jumpTargets.count < boundedLimit {
                            let conversation = try dbQueue.read { db -> ConversationRecord? in
                                try ConversationStore.fetchConversationRow(db, id: item.id)
                            }
                            guard let conversation = conversation else { continue }
                            jumpTargets.append(
                                ConversationJumpTarget(
                                    conversation: conversation,
                                    snippet: Self.aggregateMatchSnippet(text: nsText, matchRange: match.range),
                                    startOffset: match.range.location,
                                    endOffset: match.range.location + match.range.length,
                                    source: .aggregateExact
                                )
                            )
                        }
                    }
                }
            }
        }

        return CredentialExposureScanResult(totalMatches: totalMatches, jumpTargets: jumpTargets)
    }

    private static nonisolated func aggregateMatchSnippet(text: NSString, matchRange: NSRange, radius: Int = 120) -> String {
        let start = max(0, matchRange.location - radius)
        let end = min(text.length, matchRange.location + matchRange.length + radius)
        let snippetRange = NSRange(location: start, length: max(0, end - start))
        let raw = text.substring(with: snippetRange)
        let compact = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var prefix = ""
        var suffix = ""
        if start > 0 { prefix = "..." }
        if end < text.length { suffix = "..." }
        return prefix + compact + suffix
    }

    private static nonisolated let _credentialExposureRegexes: [NSRegularExpression]? = {
        let patterns = [
            #"(?i)\b[A-Z0-9_]*(?:API[_-]?KEY|ACCESS[_-]?TOKEN|TOKEN|SECRET|PASSWORD)\b\s*[:=]\s*["']?[A-Za-z0-9_\-./+=]{8,}"#,
            #"\bsk-[A-Za-z0-9]{16,}\b"#,
            #"\bAIza[0-9A-Za-z\-_]{16,}\b"#,
            #"\bgh[pousr]_[A-Za-z0-9]{20,}\b"#
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    private static nonisolated var credentialExposureRegexes: [NSRegularExpression] {
        _credentialExposureRegexes ?? []
    }

    private static nonisolated func nonOverlappingOccurrenceCount(of pattern: String, in lowercasedText: String) -> Int {
        guard pattern.isEmpty == false, lowercasedText.isEmpty == false else { return 0 }
        var count = 0
        var searchStart = lowercasedText.startIndex
        while searchStart < lowercasedText.endIndex,
              let range = lowercasedText.range(of: pattern, range: searchStart..<lowercasedText.endIndex) {
            count += 1
            searchStart = range.upperBound
        }
        return count
    }

    private static nonisolated func looksLikePlaceholderCredential(_ text: String) -> Bool {
        let lower = text.lowercased()
        let placeholders = [
            "your-key", "your_key", "your key", "key-here", "placeholder",
            "example", "dummy", "changeme", "replace-me", "***", "<", "test"
        ]
        return placeholders.contains { lower.contains($0) }
    }
}
