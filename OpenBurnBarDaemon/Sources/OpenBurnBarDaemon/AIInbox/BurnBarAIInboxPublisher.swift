import Foundation
import OpenBurnBarEngine

struct BurnBarAIInboxPublishResult: Sendable {
    let itemsNew: Int
    let itemsUpdated: Int
    let itemsResolved: Int
    let notifiedFingerprints: [String]
}

/// Turns verified findings into durable inbox items.
///
/// Responsibilities, in order:
///   1. **Suppression** — drop anything the user rejected or a verifier refuted.
///   2. **Auto-resolution** — close open items whose evidence disappeared. This
///      is what keeps the inbox from decaying into a wall of stale alerts, and
///      it is why "resolved" is a first-class state rather than a delete.
///   3. **Upsert** — one open row per fingerprint, bumping occurrences.
///   4. **Accounting** — one usage-ledger event per model sub-call.
///   5. **Notification** — at most one, only for a genuinely new P1.
struct BurnBarAIInboxPublisher: Sendable {
    private let store: BurnBarAIInboxStore
    private let usageRecorder: BurnBarUsageRecorder
    private let notifier: (any BurnBarAIInboxNotifying)?
    private let logger: BurnBarDaemonLogger

    /// Open items untouched for this long are expired. Long enough to survive a
    /// weekend, short enough that the list reflects the present.
    static let itemTTL: TimeInterval = 7 * 24 * 60 * 60
    /// Briefs are dated snapshots, not conditions, so they age out on their own
    /// short clock instead of accumulating one open row per day.
    static let briefTTL: TimeInterval = 36 * 60 * 60
    /// Per-fingerprint notification cooldown.
    static let notificationCooldown: TimeInterval = 60 * 60
    /// Hard ceiling per tick — a pathological pack must not produce a wall of
    /// notifications.
    static let maxNotificationsPerTick = 1

    init(
        store: BurnBarAIInboxStore,
        usageRecorder: BurnBarUsageRecorder,
        notifier: (any BurnBarAIInboxNotifying)?,
        logger: BurnBarDaemonLogger
    ) {
        self.store = store
        self.usageRecorder = usageRecorder
        self.notifier = notifier
        self.logger = logger
    }

    func publish(
        findings: [BurnBarAIInboxFinding],
        briefMarkdown: String,
        pack: BurnBarAIInboxEvidencePack,
        config: BurnBarInboxConfig,
        tickID: String,
        modelProvenance: String,
        calls: [BurnBarAIInboxModelCall],
        newlySuppressedFingerprints: [String],
        now: Date
    ) async -> BurnBarAIInboxPublishResult {
        var suppressed = Set((try? store.state(
            BurnBarAIInboxSchema.StateKey.suppressedFingerprints,
            as: [String].self
        )) ?? [])
        if newlySuppressedFingerprints.isEmpty == false {
            suppressed.formUnion(newlySuppressedFingerprints)
            // Bounded so a long-lived profile cannot grow this without limit.
            try? store.setState(
                BurnBarAIInboxSchema.StateKey.suppressedFingerprints,
                value: Array(suppressed.suffix(500)),
                now: now
            )
        }

        // Fold any new 👍/👎 into the learned calibration before ranking, so a
        // rating given a minute ago already affects this tick.
        var calibration = loadCalibration()
        absorbFeedback(into: &calibration, now: now)

        var itemsNew = 0
        var itemsUpdated = 0
        var notified: [String] = []
        var publishedFingerprints = Set<String>()

        // Brief first, so it sorts as the day's narrative anchor.
        var toPublish: [BurnBarAIInboxFinding] = []
        if briefMarkdown.isEmpty == false {
            toPublish.append(Self.briefFinding(markdown: briefMarkdown, pack: pack, now: now))
        }
        toPublish.append(contentsOf: findings)

        for finding in toPublish {
            guard suppressed.contains(finding.fingerprint) == false else { continue }
            publishedFingerprints.insert(finding.fingerprint)

            // A learned demotion must be visible, not mysterious: carry the
            // reason so the item footer can say why it ranks where it does.
            var metrics = finding.metrics
            if let explanation = calibration.explanation(for: finding.kind) {
                metrics["calibration_note"] = explanation
            }

            let payload = BurnBarInboxItemPayload(
                evidence: Self.evidence(for: finding, pack: pack),
                memoryCandidates: finding.memoryCandidates,
                actions: finding.actions,
                metrics: metrics,
                verification: finding.deterministicVerification
            )

            // Learned demotion: a kind the user consistently marks unhelpful, or
            // that keeps resolving on its own within minutes, drops one band.
            // Bounded and never silencing — see `BurnBarAIInboxCalibration`.
            let effectivePriority = calibration.adjustedPriority(
                for: finding.kind,
                proposed: finding.priority
            )

            let write = BurnBarAIInboxItemWrite(
                fingerprint: finding.fingerprint,
                kind: finding.kind,
                priority: effectivePriority,
                title: finding.title,
                summaryMarkdown: finding.summaryMarkdown,
                payload: payload,
                projectID: finding.projectID,
                projectName: finding.projectName,
                tickID: tickID,
                modelProvenance: finding.source == .detector ? "local-rules" : modelProvenance
            )

            do {
                let outcome = try store.upsertItem(write, now: now)
                if outcome.wasCreated {
                    itemsNew += 1
                } else if outcome.contentChanged {
                    itemsUpdated += 1
                }

                if config.notifyOnP1,
                   effectivePriority == .p1,
                   outcome.wasCreated,
                   notified.count < Self.maxNotificationsPerTick,
                   Self.shouldNotify(fingerprint: finding.fingerprint, store: store, now: now) {
                    await notifier?.notify(
                        title: finding.title,
                        body: Self.notificationBody(finding),
                        itemID: outcome.id
                    )
                    notified.append(finding.fingerprint)
                    Self.recordNotification(fingerprint: finding.fingerprint, store: store, now: now)
                }
            } catch {
                logger.warning(
                    "ai_inbox_item_upsert_failed",
                    metadata: ["kind": finding.kind.rawValue, "error": "\(error)"]
                )
            }
        }

        let itemsResolved = resolveDisappearedItems(
            pack: pack,
            publishedFingerprints: publishedFingerprints,
            suppressed: suppressed,
            calibration: &calibration,
            now: now
        )

        // Expire anything nothing has re-confirmed.
        var expired = (try? store.expireStaleItems(
            olderThan: Self.itemTTL,
            now: now,
            excluding: [.brief]
        )) ?? 0

        // Briefs get their own, much shorter TTL rather than an exemption.
        // A brief is fingerprinted per day, so exempting it meant every day
        // minted a permanently-open row that nothing could ever resolve — the
        // list would grow by one forever. 36 hours lets today's brief survive
        // re-publication while yesterday's ages out on the next day's first tick.
        expired += (try? store.expireStaleItems(
            olderThan: Self.briefTTL,
            now: now,
            excluding: Set(BurnBarInboxItemKind.allCases).subtracting([.brief])
        )) ?? 0

        await record(calls: calls, tickID: tickID, now: now)
        saveCalibration(calibration, now: now)

        return BurnBarAIInboxPublishResult(
            itemsNew: itemsNew,
            itemsUpdated: itemsUpdated,
            itemsResolved: itemsResolved + expired,
            notifiedFingerprints: notified
        )
    }

    // MARK: - Calibration

    func loadCalibration() -> BurnBarAIInboxCalibration {
        let stored = try? store.state(
            BurnBarAIInboxSchema.StateKey.calibration,
            as: BurnBarAIInboxCalibration.self
        )
        return stored.flatMap { $0 } ?? .empty
    }

    private func saveCalibration(_ calibration: BurnBarAIInboxCalibration, now: Date) {
        try? store.setState(BurnBarAIInboxSchema.StateKey.calibration, value: calibration, now: now)
    }

    /// Folds newly-rated items into the calibration.
    ///
    /// The app writes 👍/👎 into its own `ai_inbox_item_state` table; the daemon
    /// reads it. Consumed item ids are remembered so a rating counts exactly
    /// once no matter how many ticks observe it — without that, a single 👎 would
    /// compound every five minutes until the kind was buried.
    private func absorbFeedback(into calibration: inout BurnBarAIInboxCalibration, now: Date) {
        guard let states = try? store.itemUserStates(), states.isEmpty == false else { return }
        var consumed = Set(((try? store.state(
            BurnBarAIInboxSchema.StateKey.consumedFeedback,
            as: [String].self
        )) ?? []) ?? [])

        var didChange = false
        for (itemID, state) in states {
            guard let feedback = state.feedback, feedback.isEmpty == false else { continue }
            // Key on id+verdict so a user who changes their mind is re-counted.
            let key = "\(itemID):\(feedback)"
            guard consumed.contains(key) == false else { continue }
            guard let detail = try? store.item(id: itemID) else { continue }

            calibration.recordFeedback(
                kind: detail.summary.kind,
                useful: feedback == "useful",
                now: now
            )
            consumed.insert(key)
            didChange = true
        }

        guard didChange else { return }
        // Bounded: the tail is enough to cover any item still on screen.
        try? store.setState(
            BurnBarAIInboxSchema.StateKey.consumedFeedback,
            value: Array(consumed.suffix(1_000)),
            now: now
        )
    }

    // MARK: - Auto-resolution

    /// Closes open items whose triggering evidence is gone.
    ///
    /// This runs on the *remote phase* even when nothing changed locally,
    /// because the most satisfying resolution — "that PR you were nagged about
    /// merged" — happens on GitHub, not on this machine.
    private func resolveDisappearedItems(
        pack: BurnBarAIInboxEvidencePack,
        publishedFingerprints: Set<String>,
        suppressed: Set<String>,
        calibration: inout BurnBarAIInboxCalibration,
        now: Date
    ) -> Int {
        var resolved = 0
        let openItems = (try? store.openItems()) ?? []

        for item in openItems {
            // A fingerprint re-published this tick is by definition still live.
            guard publishedFingerprints.contains(item.fingerprint) == false else { continue }

            if suppressed.contains(item.fingerprint) {
                if (try? store.resolveItem(
                    id: item.id,
                    note: "Dismissed — this no longer looks like a real problem.",
                    now: now
                )) == true {
                    resolved += 1
                }
                continue
            }

            guard let note = resolutionNote(for: item, pack: pack) else { continue }
            if (try? store.resolveItem(id: item.id, note: note, now: now)) == true {
                resolved += 1
                // How long it survived is the cheapest honest signal of whether
                // raising it was worth the user's attention.
                calibration.recordResolution(
                    kind: item.kind,
                    firstSeenAt: item.firstSeenAt,
                    resolvedAt: now,
                    now: now
                )
                logger.debug(
                    "ai_inbox_item_auto_resolved",
                    metadata: ["kind": item.kind.rawValue]
                )
            }
        }
        return resolved
    }

    /// Positive evidence that a condition ended. Deliberately conservative: only
    /// resolve when the pack actually observed the relevant surface, so a GitHub
    /// outage cannot mass-resolve the inbox.
    private func resolutionNote(
        for item: BurnBarInboxItemSummary,
        pack: BurnBarAIInboxEvidencePack
    ) -> String? {
        switch item.kind {
        case .stuckPR:
            guard pack.repositories.isEmpty == false else { return nil }
            guard let detail = try? store.item(id: item.id) else { return nil }
            for evidence in detail.payload.evidence where evidence.kind == .pullRequest {
                let reference = evidence.id.replacingOccurrences(of: "pr:", with: "")
                let parts = reference.split(separator: "#")
                guard parts.count == 2, let number = Int(parts[1]) else { continue }
                guard let repository = pack.repositories.first(where: { $0.slug == String(parts[0]) }) else {
                    continue
                }
                if repository.recentlyMergedPullRequests.contains(where: { $0.number == number }) {
                    return "PR #\(number) has been merged."
                }
                if repository.openPullRequests.contains(where: { $0.number == number }) == false {
                    return "PR #\(number) is no longer open."
                }
            }
            return nil

        case .promisedNotLanded:
            guard pack.workspaces.isEmpty == false else { return nil }
            guard let detail = try? store.item(id: item.id) else { return nil }
            for evidence in detail.payload.evidence where evidence.id.hasPrefix("workspace:") {
                let path = String(evidence.id.dropFirst("workspace:".count))
                guard let workspace = pack.workspaces.first(where: { $0.path == path }) else { continue }
                if workspace.isDirty == false {
                    return "The workspace is clean now — the work appears to have landed."
                }
            }
            return nil

        case .uncommittedWork:
            guard pack.workspaces.isEmpty == false else { return nil }
            guard let detail = try? store.item(id: item.id) else { return nil }
            for evidence in detail.payload.evidence where evidence.id.hasPrefix("workspace:") {
                let path = String(evidence.id.dropFirst("workspace:".count))
                guard let workspace = pack.workspaces.first(where: { $0.path == path }) else { continue }
                if workspace.isDirty == false {
                    return "Those changes have been committed."
                }
            }
            return nil

        case .ciWaste:
            // Only resolve on positive evidence that the workflow recovered —
            // a missing repository snapshot means "we did not look", not "fixed".
            guard pack.repositories.isEmpty == false,
                  let projectName = item.projectName,
                  let repository = pack.repositories.first(where: { $0.slug == projectName }),
                  let detail = try? store.item(id: item.id),
                  let workflow = detail.payload.metrics["workflow"] else { return nil }
            let runs = repository.recentRuns.filter {
                $0.isFinished && BurnBarAIInboxDetectors.workflowDisplayName($0.workflowName ?? $0.name) == workflow
            }
            guard runs.count >= BurnBarAIInboxDetectors.ciWasteMinimumRuns else { return nil }
            let wasteRate = Double(runs.filter(\.isWasted).count) / Double(runs.count)
            if wasteRate < BurnBarAIInboxDetectors.ciWasteRateThreshold {
                return "This workflow is passing again (\(Int((1 - wasteRate) * 100))% of recent runs succeeded)."
            }
            return nil

        case .indexHealth:
            return pack.conversations.isEmpty ? nil : "The index has caught up."

        case .system:
            // The analyst-down notice is the one `system` item that has a
            // positive end condition: this tick published findings without it,
            // so the analyst ran. Matched on the metric marker rather than the
            // fingerprint so notices minted by an older, route-scoped
            // fingerprint clear out too instead of sitting open forever.
            guard let detail = try? store.item(id: item.id),
                  detail.payload.metrics["analyst_provider"] != nil else { return nil }
            return "The analyst is running again."

        case .costAnomaly, .brief, .budget:
            return nil
        }
    }

    // MARK: - Accounting

    /// One ledger event per model sub-call.
    ///
    /// Follows the Elder Wand fusion convention: every sub-call gets a DISTINCT
    /// idempotency key (so none is deduped away) but shares a `parentRequestID`
    /// equal to the tick id (so the N rows for one tick roll up to one logical
    /// request). `executionSourceID` is the inbox, which is what makes the daily
    /// budget query possible.
    private func record(calls: [BurnBarAIInboxModelCall], tickID: String, now: Date) async {
        for (index, call) in calls.enumerated() {
            let event = BurnBarUsageEvent(
                providerID: call.providerID,
                modelID: call.modelID,
                inputTokens: call.inputTokens,
                outputTokens: call.outputTokens,
                cacheCreationTokens: call.cacheCreationTokens,
                cacheReadTokens: call.cacheReadTokens,
                reasoningTokens: 0,
                cost: call.costUSD,
                recordedAt: now,
                projectName: BurnBarAIInboxUsage.projectName,
                executionSourceID: BurnBarAIInboxUsage.executionSourceID,
                executionSourceName: BurnBarAIInboxUsage.executionSourceName,
                executionSourceKind: .automation,
                executionSourceConfidence: .exact,
                confidence: .exact,
                parentRequestID: tickID,
                // The inbox router only dials key-backed provider slots today,
                // so every analyst/verifier/reply call is real API spend. A
                // future subscription-bridged route must stamp .subscription
                // here or the budget gate will over-count it.
                billingKind: .api
            )
            do {
                _ = try await usageRecorder.record(
                    event,
                    idempotencyKey: "ai-inbox:\(tickID):\(call.role):\(index)"
                )
            } catch {
                logger.warning("ai_inbox_usage_record_failed", metadata: ["error": "\(error)"])
            }
        }
    }

    // MARK: - Notifications

    private static func shouldNotify(fingerprint: String, store: BurnBarAIInboxStore, now: Date) -> Bool {
        let stamps = ((try? store.state(
            BurnBarAIInboxSchema.StateKey.notificationStamps,
            as: [String: Date].self
        )) ?? [:]) ?? [:]
        guard let last = stamps[fingerprint] else { return true }
        return now.timeIntervalSince(last) >= notificationCooldown
    }

    private static func recordNotification(fingerprint: String, store: BurnBarAIInboxStore, now: Date) {
        var stamps = ((try? store.state(
            BurnBarAIInboxSchema.StateKey.notificationStamps,
            as: [String: Date].self
        )) ?? [:]) ?? [:]
        stamps[fingerprint] = now
        // Prune anything older than a day; the cooldown is an hour.
        stamps = stamps.filter { now.timeIntervalSince($0.value) < 24 * 60 * 60 }
        try? store.setState(BurnBarAIInboxSchema.StateKey.notificationStamps, value: stamps, now: now)
    }

    private static func notificationBody(_ finding: BurnBarAIInboxFinding) -> String {
        // Strip markdown so a notification never shows raw `**` or backticks.
        let plain = finding.summaryMarkdown
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(plain.prefix(180))
    }

    // MARK: - Item construction

    static func briefFinding(
        markdown: String,
        pack: BurnBarAIInboxEvidencePack,
        now: Date
    ) -> BurnBarAIInboxFinding {
        BurnBarAIInboxFinding(
            kind: .brief,
            title: Self.briefTitle(pack: pack, now: now),
            summaryMarkdown: markdown,
            priority: .p4,
            confidence: 0.9,
            evidenceIDs: BurnBarAIInboxBriefAuthor.evidenceIDs(pack: pack),
            fingerprint: BurnBarAIInboxFinding.fingerprint(
                kind: .brief,
                scope: "global",
                // One brief per day, updated in place as the day unfolds.
                subject: BurnBarAIInboxDetectors.dayBucket(now)
            ),
            metrics: BurnBarAIInboxBriefAuthor.metrics(pack: pack),
            needsVerification: false,
            deterministicVerification: nil,
            source: .analyst
        )
    }

    static func briefTitle(pack: BurnBarAIInboxEvidencePack, now: Date) -> String {
        BurnBarAIInboxBriefAuthor.title(pack: pack, now: now)
    }

    /// Materializes citation ids into rich evidence rows the UI can render and
    /// deep-link. The model only ever produces ids; the labels and URLs are
    /// derived here from real data, so a model cannot fabricate a link.
    static func evidence(
        for finding: BurnBarAIInboxFinding,
        pack: BurnBarAIInboxEvidencePack
    ) -> [BurnBarInboxEvidence] {
        var rows: [BurnBarInboxEvidence] = []

        for id in finding.evidenceIDs {
            if let conversation = pack.conversations.first(where: { $0.evidenceID == id }) {
                let label: String = {
                    let title = conversation.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    if title.isEmpty == false,
                       title.contains("/") == false,
                       title.hasPrefix("~") == false {
                        return title
                    }
                    return BurnBarAIInboxBriefAuthor.shortLabel(conversation.projectName)
                        ?? BurnBarAIInboxBriefAuthor.shortLabel(conversation.workspacePath)
                        ?? BurnBarAIInboxDetectors.displayPath(title)
                }()
                rows.append(
                    BurnBarInboxEvidence(
                        id: id,
                        kind: .conversation,
                        label: label,
                        detail: BurnBarAIInboxBriefAuthor.conversationDetail(conversation),
                        url: "openburnbar://sessions/\(conversation.conversationID)",
                        occurredAt: conversation.endedAt
                    )
                )
                continue
            }

            if id.hasPrefix("workspace:") {
                let path = String(id.dropFirst("workspace:".count))
                if let workspace = pack.workspaces.first(where: { $0.path == path }) {
                    rows.append(
                        BurnBarInboxEvidence(
                            id: id,
                            kind: .file,
                            label: BurnBarAIInboxDetectors.displayPath(path),
                            detail: "\(workspace.branch ?? "HEAD") · \(workspace.dirtyFiles.count) modified, \(workspace.untrackedCount) untracked",
                            url: nil,
                            occurredAt: workspace.headCommittedAt
                        )
                    )
                }
                continue
            }

            for repository in pack.repositories {
                if id == "pr:\(repository.slug)#" { continue }
                if id.hasPrefix("pr:\(repository.slug)#"),
                   let number = Int(id.split(separator: "#").last ?? ""),
                   let pullRequest = (repository.openPullRequests + repository.recentlyMergedPullRequests)
                       .first(where: { $0.number == number }) {
                    rows.append(
                        BurnBarInboxEvidence(
                            id: id,
                            kind: .pullRequest,
                            label: "#\(number) \(pullRequest.title)",
                            detail: pullRequest.isMerged ? "merged" : pullRequest.state.lowercased(),
                            url: pullRequest.url,
                            occurredAt: pullRequest.updatedAt
                        )
                    )
                }
                if id.hasPrefix("issue:\(repository.slug)#"),
                   let number = Int(id.split(separator: "#").last ?? ""),
                   let issue = repository.openIssues.first(where: { $0.number == number }) {
                    rows.append(
                        BurnBarInboxEvidence(
                            id: id,
                            kind: .issue,
                            label: "#\(number) \(issue.title)",
                            detail: issue.state.lowercased(),
                            url: issue.url,
                            occurredAt: issue.updatedAt
                        )
                    )
                }
                if id.hasPrefix("run:\(repository.slug)#"),
                   let runID = Int(id.split(separator: "#").last ?? ""),
                   let run = repository.recentRuns.first(where: { $0.id == runID }) {
                    rows.append(
                        BurnBarInboxEvidence(
                            id: id,
                            kind: .workflowRun,
                            label: "\(run.name) · \(run.conclusion ?? run.status)",
                            detail: "\(run.headSHA.prefix(8)) on \(run.headBranch ?? "?") · \(Int(run.durationSeconds / 60))m",
                            url: run.url,
                            occurredAt: run.createdAt
                        )
                    )
                }
            }

            if id.hasPrefix("usage:") {
                let parts = id.dropFirst("usage:".count).split(separator: ":", maxSplits: 1).map(String.init)
                if parts.count == 2,
                   let aggregate = pack.usage.first(where: { $0.projectName == parts[0] && $0.model == parts[1] }) {
                    rows.append(
                        BurnBarInboxEvidence(
                            id: id,
                            kind: .usage,
                            label: "\(aggregate.model) in \(aggregate.projectName)",
                            detail: "\(aggregate.callCount) calls · \(BurnBarAIInboxDetectors.currency(aggregate.costUSD))",
                            url: nil,
                            occurredAt: nil
                        )
                    )
                }
            }
        }
        return rows
    }
}

/// Constants for attributing inbox spend in the usage ledger. Centralized
/// because the budget query must match the write exactly.
enum BurnBarAIInboxUsage {
    static let executionSourceID = "ai-inbox"
    static let executionSourceName = "OpenBurnBar AI Inbox"
    static let projectName = "OpenBurnBar AI Inbox"
}

/// Delivers a user-visible notification for a new P1.
///
/// Injected so the pipeline stays testable and so the daemon does not need to
/// know how the app surfaces notifications.
protocol BurnBarAIInboxNotifying: Sendable {
    func notify(title: String, body: String, itemID: String) async
}
