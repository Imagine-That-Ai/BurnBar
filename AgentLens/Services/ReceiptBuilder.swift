import Foundation
import GRDB
import OpenBurnBarKernel

// MARK: - The Receipt
//
// Joins indexed conversation transcripts to real usage spend and finds the
// problems that were solved more than once — the one artifact that requires
// both halves of the database. The output is a single honest claim:
//
//     "You solved these N problems more than once, across M agents.
//      Re-deriving them cost $X."
//
// Join key (verified against the live schema, not assumed):
//   * `conversations` identifies a session by `(provider, sessionId)` —
//     `ConversationRecord.stableId(provider:sessionId:)` is literally
//     "provider:sessionId".
//   * `token_usage` rows carry the same `(provider, sessionId)` pair, except
//     sub-agent rows suffix the session as "root/sub". Both existing join
//     sites collapse that suffix to the root before matching:
//     `UsageStore.sessionFacetsMap()` keys on "provider:rootSession", and the
//     v13 migration (`v13_backfill_claude_usage_timestamps`) joins
//     `c.sessionId = substr(token_usage.sessionId, 1, instr(...'/')-1)`.
//   The receipt uses the identical contract: SUM(cost) grouped by
//   `(provider, rootSessionId)`, matched to each conversation's
//   `(provider, sessionId)`.
//
// Honesty rules, in priority order:
//   1. A false "you re-solved this" destroys trust; an undercount is safe.
//      Every ambiguous case below resolves toward NOT clustering and toward
//      the SMALLER dollar figure.
//   2. Costs are never estimated. A conversation with no usage rows
//      contributes $0 and the snapshot is flagged `costIsPartial`.

// MARK: - Output models

/// One conversation inside a cluster: enough identity to open the session,
/// plus its attributed spend.
struct ReceiptConversationRef: Identifiable, Hashable, Sendable {
    /// `conversations.id` (the provider:session stable id).
    let id: String
    let provider: AgentProvider
    let startTime: Date
    /// Total real spend of the session, or 0 when no usage rows matched.
    let costUSD: Double
    /// False when no usage rows matched — the $0 above is "unknown", not "free".
    let hasUsage: Bool
}

/// A problem that was solved more than once.
struct ReceiptCluster: Identifiable, Hashable, Sendable {
    let id: String
    /// Raw `inferredTaskTitle` of the earliest member — the first solve names
    /// the problem.
    let representativeTitle: String
    let projectName: String
    /// Members in chronological order (earliest solve first).
    let conversations: [ReceiptConversationRef]
    /// The waste: total attributed cluster spend MINUS the cheapest member
    /// that actually has usage rows. The arithmetic is deliberately
    /// conservative — you needed ONE solve, so one member's cost is
    /// legitimate, not waste. We credit the cheapest *priced* member (never a
    /// $0 unknown) so the figure can only understate the waste, never
    /// overstate it. A cluster with no priced members reports $0.
    let rederivedCostUSD: Double

    var solveCount: Int { conversations.count }

    /// Distinct agents that re-solved this, in order of first appearance.
    var providers: [AgentProvider] {
        var seen = Set<AgentProvider>()
        return conversations.compactMap { seen.insert($0.provider).inserted ? $0.provider : nil }
    }
}

/// The whole receipt for one time window.
struct ReceiptSnapshot: Hashable, Sendable {
    /// Sorted by re-derived cost, most expensive waste first.
    let clusters: [ReceiptCluster]
    /// Distinct agents across every clustered conversation ("across M agents").
    let distinctAgentCount: Int
    /// Sum of every cluster's re-derived cost ("cost $X").
    let totalRederivedCostUSD: Double
    /// Day span of the window, nil for all-time.
    let windowDays: Int?
    /// True when any clustered conversation had no usage rows — the dollar
    /// figures are then a floor, not a total. Never estimated upward.
    let costIsPartial: Bool

    /// "N problems" in the headline.
    var problemCount: Int { clusters.count }
    var isEmpty: Bool { clusters.isEmpty }
}

// MARK: - Builder

enum ReceiptBuilder {

    // MARK: Tunables

    /// Minimum token-set Jaccard similarity between EVERY pair of titles in a
    /// cluster. 0.6 means a clear majority of the meaningful words overlap.
    static let jaccardThreshold = 0.6
    /// Two sessions closer than this are treated as one sitting (a
    /// continuation, not a re-derivation) and never cluster together.
    static let minimumSessionSeparation: TimeInterval = 30 * 60
    /// Titles that normalize below this many tokens carry too weak a signal
    /// to support a "same problem" claim — they never cluster.
    static let minimumTitleTokens = 2

    /// Function words only. Action verbs (fix / add / update / remove …) are
    /// deliberately KEPT: "fix login timeout" and "add login timeout" are
    /// different problems, and dropping the verb would falsely merge them —
    /// the exact overclaim the receipt must never make.
    private static let stopwords: Set<String> = [
        "a", "an", "the", "to", "of", "in", "on", "for", "and", "or", "with",
        "from", "into", "onto", "at", "by", "is", "are", "was", "be", "it",
        "its", "this", "that", "my", "our", "your", "we", "i", "so", "up", "out"
    ]

    // MARK: Input rows

    /// Metadata-only conversation projection. Deliberately excludes
    /// `fullText` / `lastAssistantMessage`: those columns can live on
    /// thousands of encrypted overflow pages, and the receipt never needs
    /// transcript bodies (see the warning on
    /// `ConversationStore.fetchConversationActivitySummaries`).
    struct SourceConversation: Sendable {
        let id: String
        let provider: AgentProvider
        let sessionId: String
        let projectName: String
        let startTime: Date?
        let inferredTaskTitle: String
    }

    /// Join key: provider raw value + root session id (sub-agent "root/sub"
    /// suffixes collapsed, mirroring `sessionFacetsMap()` and v13).
    struct SessionKey: Hashable, Sendable {
        let provider: String
        let rootSessionId: String
    }

    // MARK: Build from the store

    /// Fetches both halves of the join in one read transaction (a single
    /// consistent snapshot) and assembles the receipt off the main actor.
    static func build(
        dataStore: DataStore,
        window: ClosedRange<Date>?,
        now: Date = Date()
    ) async throws -> ReceiptSnapshot {
        let dbQueue = dataStore.actor.dbQueue
        let (conversations, spendBySession) = try await dbQueue.read { db in
            (try fetchSourceConversations(db), try fetchSpendBySession(db))
        }
        return assemble(
            conversations: conversations,
            spendBySession: spendBySession,
            window: window,
            now: now
        )
    }

    private static func fetchSourceConversations(_ db: Database) throws -> [SourceConversation] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, provider, sessionId, projectName, startTime, inferredTaskTitle
            FROM conversations
            WHERE deletedAt IS NULL
            """)
        return rows.compactMap { row in
            guard let id = row["id"] as? String,
                  let providerRaw = row["provider"] as? String,
                  let provider = AgentProvider(rawValue: providerRaw),
                  let sessionId = row["sessionId"] as? String,
                  let projectName = row["projectName"] as? String else { return nil }
            return SourceConversation(
                id: id,
                provider: provider,
                sessionId: sessionId,
                projectName: projectName,
                startTime: OpenBurnBarDatabase.parseDateValue(row["startTime"]),
                inferredTaskTitle: (row["inferredTaskTitle"] as? String) ?? ""
            )
        }
    }

    private static func fetchSpendBySession(_ db: Database) throws -> [SessionKey: Double] {
        // Same root-session collapse expression as the v13 migration join.
        let rows = try Row.fetchAll(db, sql: """
            SELECT provider,
                   CASE WHEN instr(sessionId, '/') > 0
                        THEN substr(sessionId, 1, instr(sessionId, '/') - 1)
                        ELSE sessionId END AS rootSessionId,
                   SUM(cost) AS totalCost
            FROM token_usage
            GROUP BY provider, rootSessionId
            """)
        var spend: [SessionKey: Double] = [:]
        for row in rows {
            guard let provider = row["provider"] as? String,
                  let rootSessionId = row["rootSessionId"] as? String else { continue }
            let key = SessionKey(provider: provider, rootSessionId: rootSessionId)
            let totalCost: Double = row["totalCost"] ?? 0
            spend[key, default: 0] += totalCost
        }
        return spend
    }

    // MARK: Pure assembly

    /// Deterministic core — everything after the fetch. Takes plain values so
    /// tests can drive it through the real store or directly.
    static func assemble(
        conversations: [SourceConversation],
        spendBySession: [SessionKey: Double],
        window: ClosedRange<Date>?,
        now: Date = Date()
    ) -> ReceiptSnapshot {
        let windowDays = window.map(dayCount(of:))

        // A conversation participates only when the claim it supports can be
        // verified end to end:
        //   * a startTime exists (without a clock the 30-minute separation
        //     rule cannot be checked — so we don't cluster it, per honesty
        //     rule 1),
        //   * it falls inside the window,
        //   * its normalized title carries enough signal,
        //   * it is a real provider transcript, not the in-app CLI thread.
        let candidates: [Candidate] = conversations.compactMap { conversation in
            guard conversation.id != ConversationRecord.cliAssistantId,
                  let startTime = conversation.startTime else { return nil }
            if let window, !window.contains(startTime) { return nil }
            let tokens = titleTokens(conversation.inferredTaskTitle)
            guard tokens.count >= minimumTitleTokens else { return nil }
            return Candidate(conversation: conversation, startTime: startTime, tokens: tokens)
        }

        // Titles never cluster across projects: "fix flaky auth test" in two
        // different repos is two different problems.
        let byProject = Dictionary(grouping: candidates, by: { $0.conversation.projectName })

        var clusters: [ReceiptCluster] = []
        for (projectName, members) in byProject {
            for group in clusterWithinProject(members) where group.count >= 2 {
                clusters.append(makeCluster(
                    projectName: projectName,
                    members: group,
                    spendBySession: spendBySession
                ))
            }
        }

        clusters.sort { lhs, rhs in
            if lhs.rederivedCostUSD != rhs.rederivedCostUSD {
                return lhs.rederivedCostUSD > rhs.rederivedCostUSD
            }
            if lhs.solveCount != rhs.solveCount { return lhs.solveCount > rhs.solveCount }
            return lhs.representativeTitle < rhs.representativeTitle
        }

        let distinctAgents = Set(clusters.flatMap { $0.conversations.map(\.provider) })
        return ReceiptSnapshot(
            clusters: clusters,
            distinctAgentCount: distinctAgents.count,
            totalRederivedCostUSD: clusters.reduce(0) { $0 + $1.rederivedCostUSD },
            windowDays: windowDays,
            costIsPartial: clusters.contains { cluster in
                cluster.conversations.contains { !$0.hasUsage }
            }
        )
    }

    // MARK: Clustering

    private struct Candidate {
        let conversation: SourceConversation
        let startTime: Date
        let tokens: Set<String>
    }

    /// Complete-linkage greedy clustering in chronological order: a
    /// conversation joins a cluster only when it clears BOTH gates against
    /// EVERY existing member —
    ///   * title Jaccard >= 0.6 (no transitive chaining: A~B and B~C never
    ///     drag a dissimilar A and C into one cluster), and
    ///   * start times >= 30 minutes apart (closer pairs are one sitting).
    /// A candidate that fails either gate seeds its own cluster instead. When
    /// in doubt, this splits rather than merges — undercounting is safe.
    private static func clusterWithinProject(_ members: [Candidate]) -> [[Candidate]] {
        let ordered = members.sorted { $0.startTime < $1.startTime }
        var clusters: [[Candidate]] = []
        for candidate in ordered {
            let joinedIndex = clusters.firstIndex { cluster in
                cluster.allSatisfy { member in
                    jaccard(member.tokens, candidate.tokens) >= jaccardThreshold
                        && abs(member.startTime.timeIntervalSince(candidate.startTime))
                            >= minimumSessionSeparation
                }
            }
            if let joinedIndex {
                clusters[joinedIndex].append(candidate)
            } else {
                clusters.append([candidate])
            }
        }
        return clusters
    }

    private static func makeCluster(
        projectName: String,
        members: [Candidate],
        spendBySession: [SessionKey: Double]
    ) -> ReceiptCluster {
        let refs = members.map { member -> ReceiptConversationRef in
            let key = SessionKey(
                provider: member.conversation.provider.rawValue,
                rootSessionId: rootSessionID(member.conversation.sessionId)
            )
            let cost = spendBySession[key]
            return ReceiptConversationRef(
                id: member.conversation.id,
                provider: member.conversation.provider,
                startTime: member.startTime,
                costUSD: cost ?? 0,
                hasUsage: cost != nil
            )
        }

        // The honest arithmetic: one solve was necessary, only the repeats
        // were waste. Credit the cheapest member that actually has a price —
        // never a $0 unknown, which would silently inflate the waste figure.
        let priced = refs.filter(\.hasUsage).map(\.costUSD)
        let total = priced.reduce(0, +)
        let rederived = priced.isEmpty ? 0 : max(0, total - (priced.min() ?? 0))

        let first = refs[0]
        return ReceiptCluster(
            id: "receipt:\(first.id)",
            representativeTitle: members[0].conversation.inferredTaskTitle,
            projectName: projectName,
            conversations: refs,
            rederivedCostUSD: rederived
        )
    }

    // MARK: Normalization

    /// Lowercase, strip everything but letters (punctuation AND digits — so
    /// "PR #1234" and "PR #1287" don't split on ticket numbers), collapse
    /// whitespace, drop function-word stopwords, drop 1-letter leftovers.
    static func titleTokens(_ title: String) -> Set<String> {
        let lowered = title.lowercased()
        let scalars = lowered.unicodeScalars.map { scalar -> Character in
            CharacterSet.letters.contains(scalar) ? Character(String(scalar)) : " "
        }
        let words = String(scalars)
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        return Set(words.filter { $0.count >= 2 && !stopwords.contains($0) })
    }

    static func jaccard(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        guard !lhs.isEmpty || !rhs.isEmpty else { return 0 }
        let union = lhs.union(rhs).count
        guard union > 0 else { return 0 }
        return Double(lhs.intersection(rhs).count) / Double(union)
    }

    /// "root/sub" → "root"; matches the SQL collapse in `fetchSpendBySession`.
    static func rootSessionID(_ sessionId: String) -> String {
        if let slashIndex = sessionId.firstIndex(of: "/") {
            return String(sessionId[..<slashIndex])
        }
        return sessionId
    }

    /// Whole-day span of a window, rounded up, minimum 1.
    private static func dayCount(of window: ClosedRange<Date>) -> Int {
        let seconds = window.upperBound.timeIntervalSince(window.lowerBound)
        return max(1, Int((seconds / 86_400).rounded(.up)))
    }
}
