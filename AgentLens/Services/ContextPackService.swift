import Foundation

// MARK: - Context Pack Domain Model

/// Date range covered by a context pack.
struct ContextPackDateWindow: Equatable, Sendable {
    let start: Date?
    let end: Date?
}

/// A ranked, capped bundle of session context for export to AI agents.
struct ContextPack: Equatable, Sendable {
    /// The project this context pack was assembled for (nil for cross-project).
    let project: String?
    /// The ordered, ranked list of included sessions.
    let sessions: [ContextPackSession]
    /// Deduplicated key file paths across all included sessions.
    let keyFiles: [String]
    /// Collected key commands across all included sessions (order-preserving dedup).
    let keyCommands: [String]
    /// Human-readable usage summary string.
    let usageSummary: String
    /// Approximate total character count of the shared body.
    let charEstimate: Int
    /// Date range covered by the included sessions (start, end).
    let dateWindow: ContextPackDateWindow

    /// Whether the pack contains any sessions.
    var isEmpty: Bool { sessions.isEmpty }
}

/// A single session entry in a context pack, with its inclusion reason.
struct ContextPackSession: Equatable, Sendable, Identifiable {
    let id: String          // ConversationRecord.id
    let provider: String    // AgentProvider.rawValue
    let sessionId: String
    let projectName: String
    let title: String
    let startTime: Date?
    let endTime: Date?
    let indexedAt: Date
    let summary: String?
    let keyFiles: [String]
    let keyCommands: [String]
    let keyTools: [String]
    let messageCount: Int
    let bodyText: String
    /// Human-readable reason explaining why this session was included.
    let reasonLabel: String
    /// The computed rank score (for testing/debugging transparency).
    let rankScore: Double

    var stableSortKey: String {
        let end = endTime?.timeIntervalSince1970 ?? 0
        let start = startTime?.timeIntervalSince1970 ?? 0
        let indexed = indexedAt.timeIntervalSince1970
        return String(format: "%012.3f|%012.3f|%012.3f|%@", end, start, indexed, id)
    }
}

// MARK: - Context Pack Assembly Parameters

/// Parameters for assembling a context pack.
struct ContextPackAssemblyParams: Equatable, Sendable {
    /// Optional anchor project to boost same-project sessions.
    let anchorProject: String?
    /// Optional date range filter for candidate sessions.
    let dateRange: ClosedRange<Date>?
    /// Maximum number of sessions to include (default 5).
    let maxSessions: Int
    /// Maximum character budget for the shared body (default 12000).
    let maxCharBudget: Int
    /// Reference date for recency calculations (default Date()).
    let referenceDate: Date

    init(
        anchorProject: String? = nil,
        dateRange: ClosedRange<Date>? = nil,
        maxSessions: Int = 5,
        maxCharBudget: Int = 12_000,
        referenceDate: Date = Date()
    ) {
        self.anchorProject = anchorProject
        self.dateRange = dateRange
        self.maxSessions = max(1, maxSessions)
        self.maxCharBudget = max(1, maxCharBudget)
        self.referenceDate = referenceDate
    }
}

// MARK: - Context Pack Service

/// Assembles context packs from conversation records with deterministic ranking and capping.
enum ContextPackService {

    // MARK: - Configuration

    /// Ranking weight for same-project boost.
    static let sameProjectBoost: Double = 2.0
    /// Recency weight multiplier for sessions within the last 7 days.
    static let recentWeight: Double = 2.0
    /// Recency window in days for "recent" sessions.
    static let recencyWindowDays: Int = 7
    /// Ranking contribution for having a summary.
    static let summaryBoost: Double = 1.0
    /// Ranking contribution per signal item (keyFiles + keyCommands).
    static let signalPerItem: Double = 0.1

    // MARK: - Public API

    /// Assembles a context pack from a list of candidate conversation records.
    ///
    /// Pipeline: dedupe → rank → cap sessions → enforce char budget → assemble.
    static func assemble(
        candidates: [ConversationRecord],
        params: ContextPackAssemblyParams = ContextPackAssemblyParams()
    ) -> ContextPack {
        // Step 1: Dedupe by stable session identity
        let deduped = dedupeSessions(candidates)

        // Step 2: Compute rank scores
        let scored = deduped.map { record -> (ConversationRecord, Double, String) in
            let (score, reason) = computeRank(
                record: record,
                anchorProject: params.anchorProject,
                referenceDate: params.referenceDate
            )
            return (record, score, reason)
        }

        // Step 3: Sort by score descending, then deterministic tie-break
        // Priority: endTime desc → startTime desc → indexedAt desc → ID asc
        let ranked = scored.sorted { a, b in
            if a.1 != b.1 { return a.1 > b.1 }  // score descending
            // Tie-break: more recent timestamps first, then ascending ID
            let endA = a.0.endTime?.timeIntervalSince1970 ?? 0
            let endB = b.0.endTime?.timeIntervalSince1970 ?? 0
            if endA != endB { return endA > endB }  // endTime descending
            let startA = a.0.startTime?.timeIntervalSince1970 ?? 0
            let startB = b.0.startTime?.timeIntervalSince1970 ?? 0
            if startA != startB { return startA > startB }  // startTime descending
            let indexedA = a.0.indexedAt.timeIntervalSince1970
            let indexedB = b.0.indexedAt.timeIntervalSince1970
            if indexedA != indexedB { return indexedA > indexedB }  // indexedAt descending
            return a.0.id < b.0.id  // ID ascending (lower first)
        }

        // Step 4: Cap to max sessions
        let capped = Array(ranked.prefix(params.maxSessions))

        // Step 5: Build session entries
        var sessions = capped.map { record, score, reason -> ContextPackSession in
            let title = record.summaryTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? record.summaryTitle!
                : (record.inferredTaskTitle.isEmpty ? "Session" : record.inferredTaskTitle)
            let body = buildSessionBody(record)
            return ContextPackSession(
                id: record.id,
                provider: record.provider.rawValue,
                sessionId: record.sessionId,
                projectName: record.projectName,
                title: title,
                startTime: record.startTime,
                endTime: record.endTime,
                indexedAt: record.indexedAt,
                summary: record.summary,
                keyFiles: record.keyFiles,
                keyCommands: record.keyCommands,
                keyTools: record.keyTools,
                messageCount: record.messageCount,
                bodyText: body,
                reasonLabel: reason,
                rankScore: score
            )
        }

        // Step 6: Enforce character cap by trimming oldest included sessions first
        sessions = enforceCharBudget(sessions, maxChars: params.maxCharBudget)

        // Step 7: Collect deduped key files and commands
        let keyFiles = dedupeOrdered(sessions.flatMap(\.keyFiles))
        let keyCommands = dedupeOrdered(sessions.flatMap(\.keyCommands))

        // Step 8: Compute totals
        let totalChars = sessions.reduce(0) { $0 + $1.bodyText.count }
        let windowStart = sessions.compactMap(\.startTime).min()
        let windowEnd = sessions.compactMap(\.endTime).max()

        // Step 9: Build usage summary
        let providers = Set(sessions.map(\.provider))
        // Cost aggregation deferred — not in M1 core model scope
        let usageSummary = buildUsageSummary(
            sessionCount: sessions.count,
            providers: providers,
            windowStart: windowStart,
            windowEnd: windowEnd,
            totalChars: totalChars
        )

        // Step 10: Determine project
        let project = params.anchorProject ?? sessions.first?.projectName

        return ContextPack(
            project: project,
            sessions: sessions,
            keyFiles: keyFiles,
            keyCommands: keyCommands,
            usageSummary: usageSummary,
            charEstimate: totalChars,
            dateWindow: ContextPackDateWindow(start: windowStart, end: windowEnd)
        )
    }

    // MARK: - Deduplication

    /// Deduplicates sessions by stable identity (provider + sessionId), keeping the most recent.
    static func dedupeSessions(_ records: [ConversationRecord]) -> [ConversationRecord] {
        var best: [String: ConversationRecord] = [:]
        for record in records {
            // Build stable key from provider and sessionId
            let stableKey = "\(record.provider.rawValue):\(record.sessionId)"
            if let existing = best[stableKey] {
                // Keep the one with the later indexedAt (most recent index)
                if record.indexedAt > existing.indexedAt {
                    best[stableKey] = record
                } else if record.indexedAt == existing.indexedAt {
                    // Tie-break by id for determinism
                    if record.id > existing.id {
                        best[stableKey] = record
                    }
                }
            } else {
                best[stableKey] = record
            }
        }
        return Array(best.values)
    }

    // MARK: - Ranking

    /// Computes a rank score and human-readable reason label for a session.
    static func computeRank(
        record: ConversationRecord,
        anchorProject: String?,
        referenceDate: Date = Date()
    ) -> (score: Double, reason: String) {
        var score: Double = 0
        var reasons: [String] = []

        // 1. Same-project boost
        if let anchor = anchorProject, !anchor.isEmpty,
           record.projectName == anchor {
            score += sameProjectBoost
            reasons.append("same project")
        }

        // 2. Recency weighting
        let sessionDate = record.endTime ?? record.startTime ?? record.indexedAt
        let daysAgo = referenceDate.timeIntervalSince(sessionDate) / 86400.0
        if daysAgo <= Double(recencyWindowDays) {
            score += recentWeight
            reasons.append("recent (\(Int(daysAgo))d ago)")
        } else {
            // Decay: linear decay from 1.0 to 0.0 over 30 days after recency window
            let decayDays = daysAgo - Double(recencyWindowDays)
            let decayFactor = max(0.0, 1.0 - decayDays / 30.0)
            score += decayFactor
        }

        // 3. Summary presence boost
        if let summary = record.summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            score += summaryBoost
            reasons.append("has summary")
        }

        // 4. Signal boost from key files and commands
        let signalCount = record.keyFiles.count + record.keyCommands.count
        if signalCount > 0 {
            let signalContribution = min(Double(signalCount) * signalPerItem, 2.0)
            score += signalContribution
            reasons.append("\(signalCount) signals")
        }

        let reason = reasons.isEmpty ? "eligible session" : reasons.joined(separator: ", ")
        return (score, reason)
    }

    /// Deterministic tie-break sort key for ordering equal-scored sessions.
    /// Priority: endTime desc → startTime desc → indexedAt desc → stable ID asc.
    /// Uses zero-padded numeric strings so string comparison preserves numeric order.
    static func tieBreakKey(_ record: ConversationRecord) -> String {
        let end = record.endTime?.timeIntervalSince1970 ?? 0
        let start = record.startTime?.timeIntervalSince1970 ?? 0
        let indexed = record.indexedAt.timeIntervalSince1970
        // Use %020.0f to ensure string comparison preserves numeric order
        // (larger timestamps = more recent = higher rank)
        return String(format: "%020.0f|%020.0f|%020.0f|%@",
                      end, start, indexed, record.id)
    }

    // MARK: - Character Budget

    /// Enforces the character budget by removing oldest included sessions first.
    static func enforceCharBudget(
        _ sessions: [ContextPackSession],
        maxChars: Int
    ) -> [ContextPackSession] {
        var totalChars = sessions.reduce(0) { $0 + $1.bodyText.count }
        guard totalChars > maxChars else { return sessions }

        // Sessions are already ranked; trim from the end (oldest/lowest rank) first
        var trimmed = sessions
        while trimmed.count > 1 && totalChars > maxChars {
            let removed = trimmed.removeLast()
            totalChars -= removed.bodyText.count
        }

        // If a single session exceeds the budget, truncate its body to fit
        if trimmed.count == 1 && trimmed[0].bodyText.count > maxChars {
            let session = trimmed[0]
            let truncatedBody = String(session.bodyText.prefix(maxChars))
            trimmed[0] = ContextPackSession(
                id: session.id,
                provider: session.provider,
                sessionId: session.sessionId,
                projectName: session.projectName,
                title: session.title,
                startTime: session.startTime,
                endTime: session.endTime,
                indexedAt: session.indexedAt,
                summary: session.summary,
                keyFiles: session.keyFiles,
                keyCommands: session.keyCommands,
                keyTools: session.keyTools,
                messageCount: session.messageCount,
                bodyText: truncatedBody,
                reasonLabel: session.reasonLabel,
                rankScore: session.rankScore
            )
        }

        return trimmed
    }

    // MARK: - Session Body Builder

    /// Builds the shared body text for a single session entry.
    static func buildSessionBody(_ record: ConversationRecord) -> String {
        var lines: [String] = []

        // Title
        let title = record.summaryTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? record.summaryTitle!
            : (record.inferredTaskTitle.isEmpty ? "Session" : record.inferredTaskTitle)
        lines.append("## \(title)")
        lines.append("")

        // Provider and project
        lines.append("Provider: \(record.provider.displayName) | Project: \(record.projectName)")
        lines.append("")

        // Summary if available
        if let summary = record.summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("Summary: \(summary)")
            lines.append("")
        }

        // Key files
        if !record.keyFiles.isEmpty {
            lines.append("Key files: \(record.keyFiles.prefix(8).joined(separator: ", "))")
            lines.append("")
        }

        // Key commands
        if !record.keyCommands.isEmpty {
            lines.append("Key commands: \(record.keyCommands.prefix(5).joined(separator: ", "))")
            lines.append("")
        }

        // Transcript (truncated to a reasonable limit per session for the body)
        let maxSessionBody = 4000
        if !record.fullText.isEmpty {
            let truncated = record.fullText.count > maxSessionBody
                ? String(record.fullText.prefix(maxSessionBody)) + "\n... (truncated)"
                : record.fullText
            lines.append(truncated)
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Usage Summary Builder

    static func buildUsageSummary(
        sessionCount: Int,
        providers: Set<String>,
        windowStart: Date?,
        windowEnd: Date?,
        totalChars: Int
    ) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeZone = TimeZone(secondsFromGMT: 0)  // UTC for determinism
        formatter.locale = Locale(identifier: "en_US_POSIX")  // Fixed locale for cross-host determinism

        var parts: [String] = []

        parts.append("\(sessionCount) session\(sessionCount == 1 ? "" : "s")")

        let providerList = providers.sorted().joined(separator: ", ")
        if !providerList.isEmpty {
            parts.append("providers: \(providerList)")
        }

        if let start = windowStart, let end = windowEnd {
            parts.append("\(formatter.string(from: start)) – \(formatter.string(from: end))")
        } else if let start = windowStart {
            parts.append("from \(formatter.string(from: start))")
        } else if let end = windowEnd {
            parts.append("until \(formatter.string(from: end))")
        }

        parts.append("~\(totalChars) chars")

        return parts.joined(separator: "; ")
    }

    // MARK: - Order-Preserving Dedup

    /// Deduplicates strings while preserving first-occurrence order.
    static func dedupeOrdered(_ strings: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for s in strings {
            if seen.insert(s).inserted {
                result.append(s)
            }
        }
        return result
    }
}
