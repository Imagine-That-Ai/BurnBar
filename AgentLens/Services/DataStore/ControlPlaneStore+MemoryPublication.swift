// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
@preconcurrency import GRDB
import OpenBurnBarData
import OpenBurnBarKernel

// MARK: - Agent-lane publication (I-56)

/// Approving an agent-lane memory in the app is two things, and only one of them
/// is the app's.
///
/// The app owns the VERDICT: `setMemoryReviewStatus` flips `review_status` and
/// writes the `memory.approve` / `memory.reject` audit row with `actor:"app"`.
/// The daemon owns the PUBLICATION: only its `setReviewStatus` moves a body out
/// of `memory_quarantine_bodies` into the project-memory snapshot, refills the
/// syncable body under the engine id its `body_hash` keys on, and re-embeds it
/// for recall. Before this file, an in-app approval did the first and not the
/// second, so the member saw the memory in Approved while its `body_hash` stayed
/// empty (the convergence fold could not dedupe it across devices) and the
/// agent's own recall did not serve it until the daemon happened to touch the
/// row — the residual the Po'dex integration log carries as **I-56**.
///
/// The ruling is that the app calls `daemon.memory.review_status` after its own
/// approval, so the daemon stays the single publisher. Nothing here moves a body.
extension ControlPlaneStore {

    /// How one review verdict reaches the daemon. Injected on the store so tests
    /// can drive both outcomes without a socket; production wires
    /// `liveAgentMemoryReviewPublisher`.
    typealias AgentMemoryReviewPublishing = @Sendable (
        _ memoryID: MemoryID,
        _ projectPath: String,
        _ status: MemoryReviewStatus
    ) async throws -> Void

    /// The shipping publisher: one `daemon.memory.review_status` call over the
    /// control socket, off the calling executor because the socket round trip is
    /// a blocking read (the house `daemonRPC` shape).
    static let liveAgentMemoryReviewPublisher: AgentMemoryReviewPublishing = { memoryID, projectPath, status in
        _ = try await Task.detached(priority: .userInitiated) {
            try OpenBurnBarDaemonSocketClient.memoryReviewStatus(
                memoryID: memoryID,
                projectPath: projectPath,
                status: status,
                at: OpenBurnBarDaemonRuntimePaths.live().socketURL
            )
        }.value
    }

    /// The two shapes `agent_memories.body_redacted` takes for a daemon-written
    /// row, and the reason this lane needs no new column: the reference says
    /// where the body currently LIVES, and the app never rewrites it. So a row
    /// whose verdict and whose body reference disagree is exactly a verdict the
    /// daemon has not published yet.
    enum AgentMemoryBodyReference {
        /// `BurnBarProjectCodeMemoryStore.memoryBodyReference` — published.
        static let published = "Project Memory snapshot ref:"
        /// `BurnBarProjectCodeMemoryStore.quarantineBodyReference` — parked.
        static let quarantined = "Quarantine body ref:"
    }

    /// Whether this row is approved-in-app (or rejected-in-app) but not yet
    /// published by the daemon — the "pending publication" state the review
    /// inbox shows and `retryPendingAgentMemoryPublications` drains.
    ///
    /// Derived, never stored: it is true for exactly as long as the two
    /// statements disagree and false the instant the daemon reconciles them, so
    /// a retry cannot resurrect a row somebody already published, and a crash
    /// between the verdict and the call leaves the state on disk for free.
    static func isAwaitingDaemonPublication(_ memory: Memory) -> Bool {
        guard memory.sourceKind == .agent else { return false }
        return memory.reviewStatus == .approved
            ? memory.bodyRedacted.hasPrefix(AgentMemoryBodyReference.quarantined)
            : memory.bodyRedacted.hasPrefix(AgentMemoryBodyReference.published)
    }

    /// The same rule as `isAwaitingDaemonPublication`, in SQL. Built from the one
    /// pair of prefix constants so the two readings cannot drift apart.
    static let awaitingDaemonPublicationSQL = """
        source_kind = 'agent'
        AND (
            (review_status = 'approved'
             AND body_redacted LIKE '\(AgentMemoryBodyReference.quarantined)%')
            OR (review_status != 'approved'
                AND body_redacted LIKE '\(AgentMemoryBodyReference.published)%')
        )
        """

    /// One verdict waiting for the daemon: the row, and the root the DAEMON
    /// itself recorded for it.
    struct PendingAgentMemoryPublication: Equatable, Sendable {
        let memoryID: MemoryID
        let projectPath: String
        let status: MemoryReviewStatus
    }

    /// Ask the daemon to publish one agent-lane verdict.
    ///
    /// Never throws and never rolls the verdict back: the member's decision is
    /// already durable and audited, and an unreachable daemon must not undo it.
    /// A failure leaves the row in the derived pending-publication state — the
    /// inbox renders it as "Pending publication", and the next launch retries —
    /// which is the honest reading of "approved, not yet published". The one
    /// thing that never happens is a silent success.
    ///
    /// - Returns: whether the daemon published it.
    @discardableResult
    func publishAgentMemoryReview(
        id: MemoryID,
        status: MemoryReviewStatus,
        projectID: String?
    ) async -> Bool {
        guard let projectID, projectID.isEmpty == false else {
            AppLogger.dataStore.notice(
                "memory.agent_publication_skipped",
                metadata: ["memory_id": id, "reason": "no_project_id"]
            )
            return false
        }
        let projectPath: String?
        do {
            projectPath = try await memoryProjectRecordedRoot(engineProjectID: projectID)
        } catch {
            AppLogger.dataStore.silentFailure(
                "memory.agent_publication_root_unreadable",
                error: error,
                context: ["memory_id": id]
            )
            return false
        }
        guard let projectPath else {
            // The daemon resolves a path through its WRITING resolver, so a
            // guessed one would REGISTER a project instead of addressing one.
            // No recorded root means no call.
            AppLogger.dataStore.notice(
                "memory.agent_publication_skipped",
                metadata: ["memory_id": id, "reason": "no_recorded_root"]
            )
            return false
        }
        do {
            try await publishAgentMemoryReviewStatus(id, projectPath, status)
            return true
        } catch {
            AppLogger.dataStore.silentFailure(
                "memory.agent_publication_deferred",
                error: error,
                context: ["memory_id": id, "review_status": status.rawValue]
            )
            return false
        }
    }

    /// Every agent-lane verdict this Mac has taken and the daemon has not
    /// published, oldest first, with the root the daemon recorded for each.
    ///
    /// A plain join against the shared database: `pcm_projects` is the daemon's
    /// own registry and is read READ-ONLY here, exactly as `memoryHealthProjects`
    /// reads it. A row whose project has no recorded root is not listed — there
    /// is no path to address it by, and inventing one would register a project.
    func pendingAgentMemoryPublications(limit: Int = 200) async throws -> [PendingAgentMemoryPublication] {
        let cappedLimit = max(1, min(limit, 200))
        return try await dbQueue.read { db -> [PendingAgentMemoryPublication] in
            try Row.fetchAll(
                db,
                sql: """
                SELECT m.id AS memory_id, m.review_status AS review_status, p.primary_path AS primary_path
                FROM agent_memories m
                JOIN pcm_projects p ON p.project_id = m.project_id
                WHERE \(Self.awaitingDaemonPublicationSQL)
                  AND p.primary_path IS NOT NULL AND p.primary_path != ''
                ORDER BY m.updated_at ASC, m.id ASC
                LIMIT ?
                """,
                arguments: [cappedLimit]
            ).compactMap { row in
                guard let memoryID: String = row["memory_id"],
                      let statusRaw: String = row["review_status"],
                      let status = MemoryReviewStatus(rawValue: statusRaw),
                      let path: String = row["primary_path"] else { return nil }
                return PendingAgentMemoryPublication(memoryID: memoryID, projectPath: path, status: status)
            }
        }
    }

    /// Drain the pending-publication backlog: the retry the deferred state
    /// promises. Called once the daemon is healthy on launch
    /// (`OpenBurnBarDaemonManager.startMemoryProConcierge`).
    ///
    /// Idempotent by construction — a published row stops matching the query, so
    /// a re-run does nothing — and it stops at the first failure: the daemon
    /// being down is the common reason a backlog exists at all, and a hundred
    /// doomed socket connects on launch help nobody.
    ///
    /// - Returns: how many verdicts the daemon published.
    @discardableResult
    func retryPendingAgentMemoryPublications() async -> Int {
        let pending: [PendingAgentMemoryPublication]
        do {
            pending = try await pendingAgentMemoryPublications()
        } catch {
            AppLogger.dataStore.silentFailure("memory.agent_publication_backlog_unreadable", error: error)
            return 0
        }
        guard pending.isEmpty == false else { return 0 }
        var published = 0
        for entry in pending {
            do {
                try await publishAgentMemoryReviewStatus(entry.memoryID, entry.projectPath, entry.status)
                published += 1
            } catch {
                AppLogger.dataStore.silentFailure(
                    "memory.agent_publication_retry_deferred",
                    error: error,
                    context: [
                        "memory_id": entry.memoryID,
                        "remaining": String(pending.count - published)
                    ]
                )
                break
            }
        }
        if published > 0 {
            AppLogger.dataStore.info(
                "memory.agent_publication_backlog_drained",
                metadata: ["published": String(published), "pending": String(pending.count)]
            )
        }
        return published
    }
}
