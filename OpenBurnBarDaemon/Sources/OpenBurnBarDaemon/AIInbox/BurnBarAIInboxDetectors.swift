import Foundation
import OpenBurnBarEngine

/// Deterministic pattern detectors.
///
/// These are the reason the inbox is genuinely useful with egress turned off:
/// no model is involved, nothing leaves the machine, and the arithmetic is
/// reproducible and auditable. The analyst model later *narrates* and connects
/// these; it does not replace them.
///
/// Every detector follows the same discipline:
///   • operate only on the evidence pack (no I/O of its own)
///   • emit a fingerprint built from identity, never from a measurement
///   • cite real evidence ids
///   • stay quiet unless the signal clears a threshold worth interrupting for
struct BurnBarAIInboxDetectors: Sendable {
    let now: Date

    init(now: Date = Date()) {
        self.now = now
    }

    func run(pack: BurnBarAIInboxEvidencePack, config: BurnBarInboxConfig) -> [BurnBarAIInboxFinding] {
        var findings: [BurnBarAIInboxFinding] = []
        findings.append(contentsOf: detectCIWaste(pack: pack))
        findings.append(contentsOf: detectPromisedNotLanded(pack: pack))
        findings.append(contentsOf: detectUncommittedWork(pack: pack))
        findings.append(contentsOf: detectCostAnomaly(pack: pack))
        findings.append(contentsOf: detectStuckPullRequests(pack: pack))
        findings.append(contentsOf: detectIndexHealth(pack: pack))
        return findings
    }

    // MARK: - CI waste

    /// The marquee detector.
    ///
    /// A workflow that fails or is cancelled on most of its runs is burning
    /// compute for no signal, and it is *invisible* day to day: each individual
    /// red run looks like a normal flake. Only the aggregate reveals it. That is
    /// exactly the class of blind spot this feature exists to close.
    ///
    /// Signals, per workflow:
    ///   • waste rate = (failed + cancelled + timed out) / finished runs
    ///   • wasted wall-clock minutes
    ///   • duplicate runs on the same commit (a redundant-trigger smell)
    ///
    /// Priority escalates with both rate and absolute minutes, because a 100%
    /// failure rate over three 4-second runs is noise, while 95% over 40 runs of
    /// 8 minutes each is a fire.
    static let ciWasteMinimumRuns = 6
    static let ciWasteRateThreshold = 0.45
    static let ciWasteP1RateThreshold = 0.80
    static let ciWasteP1MinimumWastedMinutes = 60.0

    func detectCIWaste(pack: BurnBarAIInboxEvidencePack) -> [BurnBarAIInboxFinding] {
        var findings: [BurnBarAIInboxFinding] = []

        for repository in pack.repositories {
            let finished = repository.recentRuns.filter(\.isFinished)
            guard finished.isEmpty == false else { continue }

            // Group by workflow identity, not display name: a renamed workflow is
            // the same workflow, and two workflows may share a display title.
            let grouped = Dictionary(grouping: finished) { $0.workflowName ?? $0.name }

            for (workflow, runs) in grouped where runs.count >= Self.ciWasteMinimumRuns {
                let wasted = runs.filter(\.isWasted)
                let wasteRate = Double(wasted.count) / Double(runs.count)
                guard wasteRate >= Self.ciWasteRateThreshold else { continue }

                let wastedMinutes = wasted.reduce(0.0) { $0 + $1.durationSeconds } / 60.0
                let totalMinutes = runs.reduce(0.0) { $0 + $1.durationSeconds } / 60.0

                // Duplicate runs on one commit: the same workflow triggered more
                // than once for a single SHA, usually push+PR double-triggering.
                let shaCounts = Dictionary(grouping: runs, by: \.headSHA).mapValues(\.count)
                let duplicateShas = shaCounts.filter { $0.key.isEmpty == false && $0.value > 1 }
                let duplicateRunCount = duplicateShas.values.reduce(0) { $0 + ($1 - 1) }

                let priority: BurnBarInboxPriority = {
                    if wasteRate >= Self.ciWasteP1RateThreshold, wastedMinutes >= Self.ciWasteP1MinimumWastedMinutes {
                        return .p1
                    }
                    if wasteRate >= Self.ciWasteP1RateThreshold || wastedMinutes >= Self.ciWasteP1MinimumWastedMinutes {
                        return .p2
                    }
                    return .p3
                }()

                let conclusionCounts = Dictionary(grouping: wasted) { $0.conclusion ?? "unknown" }
                    .mapValues(\.count)
                    .sorted { $0.value > $1.value }
                let breakdown = conclusionCounts
                    .map { "\($0.value) \($0.key.replacingOccurrences(of: "_", with: " "))" }
                    .joined(separator: ", ")

                let percent = Int((wasteRate * 100).rounded())
                let workflowLabel = Self.workflowDisplayName(workflow)

                var summary = """
                    **\(percent)% of `\(workflowLabel)` runs in \(repository.slug) are producing no signal.**

                    Of the last \(runs.count) completed runs, \(wasted.count) ended in failure or cancellation \
                    (\(breakdown)), burning roughly **\(Int(wastedMinutes.rounded())) minutes** of the \
                    \(Int(totalMinutes.rounded())) minutes this workflow consumed.
                    """
                if duplicateRunCount > 0 {
                    summary += """


                        \(duplicateRunCount) of those runs were **repeat runs on a commit this workflow had already \
                        built** — a sign the workflow is triggered by more than one event for the same change.
                        """
                }
                summary += """


                    Worth checking whether the trigger conditions or the job itself need fixing before this \
                    keeps compounding.
                    """

                let citedRuns = wasted
                    .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
                    .prefix(5)
                    .map { "run:\(repository.slug)#\($0.id)" }

                findings.append(
                    BurnBarAIInboxFinding(
                        kind: .ciWaste,
                        title: "\(percent)% of \(workflowLabel) runs are wasted in \(repository.slug)",
                        summaryMarkdown: summary,
                        priority: priority,
                        confidence: 0.95,
                        evidenceIDs: Array(citedRuns),
                        projectName: repository.slug,
                        fingerprint: BurnBarAIInboxFinding.fingerprint(
                            kind: .ciWaste,
                            scope: repository.slug,
                            subject: workflow
                        ),
                        metrics: [
                            "waste_rate": String(format: "%.3f", wasteRate),
                            "wasted_runs": String(wasted.count),
                            "total_runs": String(runs.count),
                            "wasted_minutes": String(format: "%.1f", wastedMinutes),
                            "total_minutes": String(format: "%.1f", totalMinutes),
                            "duplicate_runs": String(duplicateRunCount),
                            "workflow": workflowLabel
                        ],
                        actions: [
                            BurnBarInboxAction(
                                id: "open-runs",
                                kind: .openURL,
                                title: "View workflow runs",
                                value: "https://github.com/\(repository.slug)/actions",
                                isPrimary: true
                            )
                        ],
                        memoryCandidates: [],
                        // Arithmetic over fetched run records — nothing for an
                        // adversarial model to usefully dispute.
                        needsVerification: false,
                        deterministicVerification: BurnBarInboxVerification(
                            verdict: .deterministic,
                            reason: "Computed from \(runs.count) completed workflow runs returned by the GitHub API.",
                            checkedAt: now
                        ),
                        source: .detector
                    )
                )
            }
        }
        return findings
    }

    static func workflowDisplayName(_ raw: String) -> String {
        // ".github/workflows/nightly-matrix.yml" → "nightly-matrix"
        guard raw.contains("/") || raw.hasSuffix(".yml") || raw.hasSuffix(".yaml") else { return raw }
        let file = raw.split(separator: "/").last.map(String.init) ?? raw
        return file
            .replacingOccurrences(of: ".yml", with: "")
            .replacingOccurrences(of: ".yaml", with: "")
    }

    // MARK: - Promised but not landed

    /// Catches work an agent said it finished that has no trace in git or GitHub.
    ///
    /// Conservative by construction: it fires only when a *completion* claim is
    /// present AND the workspace shows no matching commit AND no PR references
    /// the work. Even then it is P3 and flagged for verification — a false
    /// "you didn't finish this" is more annoying than a missed one.
    static let completionClaimPatterns = [
        #"(?i)\b(i(?:'ve| have)?\s+(?:now\s+)?(?:committed|pushed|merged|landed|shipped|opened a PR|created a PR))"#,
        #"(?i)\b(the (?:fix|change|patch|PR) (?:is|has been) (?:committed|pushed|merged|landed|shipped))"#,
        #"(?i)\b(all (?:tests|checks) (?:pass|are passing) and (?:i|we) (?:committed|pushed|merged))"#
    ]

    func detectPromisedNotLanded(pack: BurnBarAIInboxEvidencePack) -> [BurnBarAIInboxFinding] {
        // A stale index is the main way this detector produces a false "you did
        // not finish this": the commit may exist on disk and simply not be
        // visible yet. Telling someone their work vanished when it did not is
        // the single worst failure this feature can have, so when the index is
        // meaningfully behind, stay quiet and let the next tick decide.
        guard pack.hasNotableIndexLag == false else { return [] }

        var findings: [BurnBarAIInboxFinding] = []
        let workspacesByPath = Dictionary(
            pack.workspaces.map { ($0.path, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for conversation in pack.conversations {
            guard let workspacePath = conversation.workspacePath,
                  let workspace = workspacesByPath[
                    URL(fileURLWithPath: (workspacePath as NSString).expandingTildeInPath)
                        .standardizedFileURL.path
                  ] else { continue }

            guard Self.containsCompletionClaim(conversation.body) else { continue }

            // Did anything actually land? Look for a commit or PR whose subject
            // overlaps meaningfully with the session's task.
            let taskTokens = Self.significantTokens(conversation.title)
            guard taskTokens.isEmpty == false else { continue }

            let landedInGit = workspace.recentCommitSubjects.contains { subject in
                Self.overlapScore(taskTokens, Self.significantTokens(subject)) >= 0.5
            }
            let repository = pack.repositories.first { $0.slug == workspace.githubSlug }
            let landedInPR = (repository.map { repo in
                (repo.openPullRequests + repo.recentlyMergedPullRequests).contains { pullRequest in
                    Self.overlapScore(taskTokens, Self.significantTokens(pullRequest.title)) >= 0.5
                }
            }) ?? false

            guard landedInGit == false, landedInPR == false else { continue }

            // A dirty tree is corroborating evidence; a clean tree with no commit
            // is more ambiguous (the work may have landed under a different name).
            let dirtyNote = workspace.isDirty
                ? "The worktree still has \(workspace.dirtyFiles.count) modified file(s) and \(workspace.untrackedCount) untracked file(s)."
                : "The worktree is clean, so the work may have landed under a different description — worth a glance either way."

            var evidence = [conversation.evidenceID, "workspace:\(workspace.path)"]
            if let repository { evidence.append(contentsOf: repository.openPullRequests.prefix(2).map { "pr:\(repository.slug)#\($0.number)" }) }

            findings.append(
                BurnBarAIInboxFinding(
                    kind: .promisedNotLanded,
                    title: "\"\(Self.truncate(conversation.title, 60))\" may not have landed",
                    summaryMarkdown: """
                        A session in `\(Self.displayPath(workspace.path))` reported finishing this work, but no \
                        recent commit or pull request in that repository matches it.

                        \(dirtyNote)

                        Last activity \(Self.relativeDescription(from: conversation.endedAt, to: now)).
                        """,
                    priority: workspace.isDirty ? .p2 : .p3,
                    confidence: workspace.isDirty ? 0.7 : 0.45,
                    evidenceIDs: evidence,
                    projectName: conversation.projectName,
                    fingerprint: BurnBarAIInboxFinding.fingerprint(
                        kind: .promisedNotLanded,
                        scope: workspace.path,
                        subject: conversation.conversationID
                    ),
                    metrics: [
                        "dirty_files": String(workspace.dirtyFiles.count),
                        "untracked_files": String(workspace.untrackedCount),
                        "branch": workspace.branch ?? "unknown"
                    ],
                    actions: [
                        // The finding says "an agent claimed done and nothing
                        // landed" — so the one primary move is to go land it.
                        // The button names the OUTCOME; the mechanism (resuming
                        // the session in its CLI) is the vehicle, not the story.
                        BurnBarInboxAction(
                            id: "resume",
                            kind: .resumeConversation,
                            title: "Pick it back up and land it",
                            value: conversation.conversationID,
                            isPrimary: true
                        ),
                        BurnBarInboxAction(
                            id: "open-log",
                            kind: .openSessionLog,
                            title: "Read the session",
                            value: conversation.conversationID
                        )
                    ],
                    memoryCandidates: [],
                    // Text-matching heuristic — precisely the kind of claim an
                    // adversarial verifier should be allowed to shoot down.
                    needsVerification: true,
                    deterministicVerification: nil,
                    source: .detector
                )
            )
        }
        return findings
    }

    static func containsCompletionClaim(_ text: String) -> Bool {
        completionClaimPatterns.contains { pattern in
            text.range(of: pattern, options: [.regularExpression]) != nil
        }
    }

    // MARK: - Uncommitted work

    /// A dirty worktree whose session has gone quiet. This is the "you walked
    /// away mid-change" nudge — the most common way real work evaporates.
    static let uncommittedQuietPeriod: TimeInterval = 45 * 60
    static let uncommittedMinimumFiles = 3

    func detectUncommittedWork(pack: BurnBarAIInboxEvidencePack) -> [BurnBarAIInboxFinding] {
        var findings: [BurnBarAIInboxFinding] = []

        for workspace in pack.workspaces where workspace.isDirty {
            let changedCount = workspace.dirtyFiles.count + workspace.untrackedCount
            guard changedCount >= Self.uncommittedMinimumFiles else { continue }

            // Only nudge once the session has actually gone quiet; otherwise this
            // fires constantly while someone is mid-edit, which is worse than
            // useless.
            let lastActivity = pack.conversations
                .filter { $0.workspacePath.map { Self.samePath($0, workspace.path) } ?? false }
                .compactMap(\.endedAt)
                .max()
            guard let lastActivity, now.timeIntervalSince(lastActivity) >= Self.uncommittedQuietPeriod else {
                continue
            }

            let sample = workspace.dirtyFiles.prefix(6).map { "`\($0)`" }.joined(separator: ", ")
            findings.append(
                BurnBarAIInboxFinding(
                    kind: .uncommittedWork,
                    title: "\(changedCount) uncommitted change\(changedCount == 1 ? "" : "s") in \(Self.lastPathComponent(workspace.path))",
                    summaryMarkdown: """
                        `\(Self.displayPath(workspace.path))` has \(workspace.dirtyFiles.count) modified and \
                        \(workspace.untrackedCount) untracked file(s) on `\(workspace.branch ?? "HEAD")`, and the \
                        session working there went quiet \(Self.relativeDescription(from: lastActivity, to: now)).

                        \(sample.isEmpty ? "" : "Changed: \(sample)")
                        """,
                    priority: changedCount >= 15 ? .p2 : .p3,
                    confidence: 0.9,
                    evidenceIDs: ["workspace:\(workspace.path)"],
                    fingerprint: BurnBarAIInboxFinding.fingerprint(
                        kind: .uncommittedWork,
                        scope: workspace.path,
                        subject: workspace.branch ?? "HEAD"
                    ),
                    metrics: [
                        "dirty_files": String(workspace.dirtyFiles.count),
                        "untracked_files": String(workspace.untrackedCount),
                        "ahead": String(workspace.aheadCount),
                        "branch": workspace.branch ?? "unknown"
                    ],
                    actions: [
                        BurnBarInboxAction(
                            id: "open-project",
                            kind: .openProject,
                            title: "Open project",
                            value: workspace.path,
                            isPrimary: true
                        )
                    ],
                    needsVerification: false,
                    deterministicVerification: BurnBarInboxVerification(
                        verdict: .deterministic,
                        reason: "Read directly from `git status` in the workspace.",
                        checkedAt: now
                    ),
                    source: .detector
                )
            )
        }
        return findings
    }

    // MARK: - Cost anomaly

    /// Flags spend that breaks sharply from its own trailing baseline.
    ///
    /// Uses a robust z-score (median + MAD) rather than mean + standard
    /// deviation: token spend is heavy-tailed, and one expensive afternoon would
    /// poison a mean-based baseline into never firing again.
    static let costAnomalyMinimumSamples = 5
    static let costAnomalyZThreshold = 3.5
    static let costAnomalyMinimumUSD = 1.0

    struct CostBaseline: Codable, Sendable, Hashable {
        var samples: [Double]
        var updatedAt: Date

        static let maxSamples = 48
    }

    func detectCostAnomaly(
        pack: BurnBarAIInboxEvidencePack,
        baselines: [String: CostBaseline] = [:]
    ) -> [BurnBarAIInboxFinding] {
        var findings: [BurnBarAIInboxFinding] = []

        let byProject = Dictionary(grouping: pack.usage, by: \.projectName)
        for (project, aggregates) in byProject where project.isEmpty == false {
            let windowCost = aggregates.reduce(0.0) { $0 + $1.costUSD }
            guard windowCost >= Self.costAnomalyMinimumUSD else { continue }
            guard let baseline = baselines[project], baseline.samples.count >= Self.costAnomalyMinimumSamples else {
                continue
            }

            let median = Self.median(baseline.samples)
            let deviations = baseline.samples.map { abs($0 - median) }
            let mad = Self.median(deviations)
            // 1.4826 scales MAD to be a consistent estimator of σ for normal data.
            let scale = max(mad * 1.4826, 0.01)
            let zScore = (windowCost - median) / scale
            guard zScore >= Self.costAnomalyZThreshold else { continue }

            let topModel = aggregates.max { $0.costUSD < $1.costUSD }
            findings.append(
                BurnBarAIInboxFinding(
                    kind: .costAnomaly,
                    title: "Spend in \(project) is \(Self.multiplierDescription(windowCost, median)) its usual level",
                    summaryMarkdown: """
                        `\(project)` has used **\(Self.currency(windowCost))** in the last window, against a typical \
                        \(Self.currency(median)).

                        \(topModel.map { "Most of it is `\($0.model)` (\(Self.currency($0.costUSD)) across \($0.callCount) calls)." } ?? "")
                        """,
                    priority: zScore >= 6 ? .p2 : .p3,
                    confidence: 0.8,
                    evidenceIDs: aggregates.prefix(3).map { "usage:\($0.projectName):\($0.model)" },
                    projectName: project,
                    fingerprint: BurnBarAIInboxFinding.fingerprint(
                        kind: .costAnomaly,
                        scope: project,
                        // Bucket by day so a sustained anomaly updates one item
                        // per day instead of one per tick.
                        subject: Self.dayBucket(now)
                    ),
                    metrics: [
                        "window_cost_usd": String(format: "%.4f", windowCost),
                        "baseline_median_usd": String(format: "%.4f", median),
                        "z_score": String(format: "%.2f", zScore)
                    ],
                    needsVerification: false,
                    deterministicVerification: BurnBarInboxVerification(
                        verdict: .deterministic,
                        reason: "Robust z-score over \(baseline.samples.count) prior windows.",
                        checkedAt: now
                    ),
                    source: .detector
                )
            )
        }
        return findings
    }

    // MARK: - Stuck pull requests

    static let stuckPRQuietPeriod: TimeInterval = 5 * 24 * 60 * 60

    /// Individual stalled PRs surfaced per repository before the rest are rolled
    /// into one summary row.
    ///
    /// Without this, a repository with 30 stale open PRs — ordinary on an active
    /// project — produces 30 items in a single tick, and the fingerprint dedupe
    /// then keeps every one of them alive. The inbox becomes a backlog listing,
    /// which is the opposite of "here is what needs you". Five is enough to act
    /// on; the summary keeps the total honest.
    static let maxIndividualStuckPRs = 5

    func detectStuckPullRequests(pack: BurnBarAIInboxEvidencePack) -> [BurnBarAIInboxFinding] {
        var findings: [BurnBarAIInboxFinding] = []

        for repository in pack.repositories {
            // Collect first so the most actionable ones can be surfaced
            // individually and the tail summarized, rather than emitting in
            // whatever order the API returned.
            let stuck = repository.openPullRequests
                .filter { pullRequest in
                    guard pullRequest.isDraft == false, let updatedAt = pullRequest.updatedAt else { return false }
                    return now.timeIntervalSince(updatedAt) >= Self.stuckPRQuietPeriod
                }
                .sorted { lhs, rhs in
                    // Approved-and-forgotten first: the work is done and only
                    // needs a merge, so it is the cheapest thing to act on.
                    let lhsApproved = lhs.reviewDecision?.uppercased() == "APPROVED"
                    let rhsApproved = rhs.reviewDecision?.uppercased() == "APPROVED"
                    if lhsApproved != rhsApproved { return lhsApproved }
                    return (lhs.updatedAt ?? .distantFuture) < (rhs.updatedAt ?? .distantFuture)
                }

            for pullRequest in stuck.prefix(Self.maxIndividualStuckPRs) {
                guard let updatedAt = pullRequest.updatedAt else { continue }
                let days = Int(now.timeIntervalSince(updatedAt) / 86_400)
                let approved = pullRequest.reviewDecision?.uppercased() == "APPROVED"
                findings.append(
                    BurnBarAIInboxFinding(
                        kind: .stuckPR,
                        title: "PR #\(pullRequest.number) has been quiet for \(days) days",
                        summaryMarkdown: """
                            [\(Self.truncate(pullRequest.title, 80))](\(pullRequest.url)) in `\(repository.slug)` \
                            has had no activity for \(days) days\(approved ? " and is already approved" : "").

                            +\(pullRequest.additions) −\(pullRequest.deletions) on `\(pullRequest.headRefName)`.
                            """,
                        // Approved-and-forgotten is the more actionable case: the
                        // work is done and just needs a merge.
                        priority: approved ? .p2 : .p3,
                        confidence: 0.95,
                        evidenceIDs: ["pr:\(repository.slug)#\(pullRequest.number)"],
                        projectName: repository.slug,
                        fingerprint: BurnBarAIInboxFinding.fingerprint(
                            kind: .stuckPR,
                            scope: repository.slug,
                            subject: String(pullRequest.number)
                        ),
                        metrics: [
                            "days_idle": String(days),
                            "review_decision": pullRequest.reviewDecision ?? "none",
                            "additions": String(pullRequest.additions),
                            "deletions": String(pullRequest.deletions)
                        ],
                        actions: [
                            BurnBarInboxAction(
                                id: "open-pr",
                                kind: .openURL,
                                title: "Open PR #\(pullRequest.number)",
                                value: pullRequest.url,
                                isPrimary: true
                            )
                        ],
                        needsVerification: false,
                        deterministicVerification: BurnBarInboxVerification(
                            verdict: .deterministic,
                            reason: "Read from the pull request's own `updatedAt` timestamp.",
                            checkedAt: now
                        ),
                        source: .detector
                    )
                )
            }

            // The tail becomes one row rather than dozens. A count the user can
            // act on beats a list they will scroll past.
            let remainder = stuck.count - Self.maxIndividualStuckPRs
            if remainder > 0 {
                let overflow = Array(stuck.dropFirst(Self.maxIndividualStuckPRs))
                let approvedCount = overflow.filter { $0.reviewDecision?.uppercased() == "APPROVED" }.count
                let quietDays = Int(Self.stuckPRQuietPeriod / 86_400)
                findings.append(
                    BurnBarAIInboxFinding(
                        kind: .stuckPR,
                        title: "\(remainder) more stalled PRs in \(repository.slug)",
                        summaryMarkdown: """
                            Beyond the ones listed separately, \(remainder) other pull \
                            request\(remainder == 1 ? "" : "s") in `\(repository.slug)` \
                            \(remainder == 1 ? "has" : "have") gone quiet for over \(quietDays) \
                            days\(approvedCount > 0 ? ", \(approvedCount) of them already approved" : "").

                            Listing each separately would bury the rest of your inbox, so they are \
                            summarized here.
                            """,
                        priority: approvedCount > 0 ? .p3 : .p4,
                        confidence: 0.95,
                        evidenceIDs: overflow.prefix(5).map { "pr:\(repository.slug)#\($0.number)" },
                        projectName: repository.slug,
                        fingerprint: BurnBarAIInboxFinding.fingerprint(
                            kind: .stuckPR,
                            scope: repository.slug,
                            // Identity, not the count — otherwise every PR that
                            // goes stale mints a brand-new summary row.
                            subject: "stalled-pr-overflow"
                        ),
                        metrics: [
                            "additional_stalled": String(remainder),
                            "additional_approved": String(approvedCount)
                        ],
                        actions: [
                            BurnBarInboxAction(
                                id: "open-prs",
                                kind: .openURL,
                                title: "Review open PRs",
                                value: "https://github.com/\(repository.slug)/pulls",
                                isPrimary: true
                            )
                        ],
                        needsVerification: false,
                        deterministicVerification: BurnBarInboxVerification(
                            verdict: .deterministic,
                            reason: "Counted from the repository's own open pull requests.",
                            checkedAt: now
                        ),
                        source: .detector
                    )
                )
            }
        }
        return findings
    }

    // MARK: - Index health

    /// The inbox reasons over the local index, so it has to be honest when that
    /// index is stale — otherwise a quiet inbox is ambiguous between "nothing
    /// happened" and "I can't see what happened".
    static let indexStalenessThreshold: TimeInterval = 45 * 60

    func detectIndexHealth(pack: BurnBarAIInboxEvidencePack) -> [BurnBarAIInboxFinding] {
        guard pack.conversations.isEmpty else { return [] }

        // No indexed conversations in the window, but agent logs changed
        // recently → the indexer is behind, not the user idle.
        let recentLogActivity = BurnBarAIInboxChangeGate.agentLogSignature(since: pack.windowStart)
        let quietSignature = BurnBarAIInboxChangeGate.agentLogSignature(
            since: now.addingTimeInterval(-60)
        )
        guard recentLogActivity != quietSignature else { return [] }

        return [
            BurnBarAIInboxFinding(
                kind: .indexHealth,
                title: "Recent agent activity is not indexed yet",
                summaryMarkdown: """
                    Agent session logs changed in the last window, but no conversations from that period are in \
                    the index yet, so this brief may be incomplete.

                    OpenBurnBar indexes sessions on a periodic refresh; this usually resolves on its own within \
                    a few minutes.
                    """,
                priority: .p4,
                confidence: 0.6,
                evidenceIDs: [],
                fingerprint: BurnBarAIInboxFinding.fingerprint(
                    kind: .indexHealth,
                    scope: "local",
                    subject: "index-lag"
                ),
                metrics: [:],
                needsVerification: false,
                deterministicVerification: BurnBarInboxVerification(
                    verdict: .deterministic,
                    reason: "Agent log files changed but no matching indexed conversations were found.",
                    checkedAt: now
                ),
                source: .detector
            )
        ]
    }

    // MARK: - Helpers

    /// Tokens that carry meaning for overlap comparison — stop words and short
    /// fragments removed so "the fix for the bug" does not match everything.
    static func significantTokens(_ text: String) -> Set<String> {
        let stopWords: Set<String> = [
            "the", "a", "an", "and", "or", "but", "for", "to", "of", "in", "on", "at", "by", "with",
            "from", "into", "is", "are", "was", "were", "be", "been", "it", "this", "that", "we",
            "i", "you", "add", "fix", "update", "change", "make", "use", "then", "so", "if", "when"
        ]
        let cleaned = text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " }
        return Set(
            String(cleaned)
                .split(separator: " ")
                .map(String.init)
                .filter { $0.count >= 4 && stopWords.contains($0) == false }
        )
    }

    /// Overlap as a fraction of the smaller set — asymmetric on purpose, so a
    /// short commit subject can still match a long task title.
    static func overlapScore(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        guard lhs.isEmpty == false, rhs.isEmpty == false else { return 0 }
        let intersection = lhs.intersection(rhs).count
        return Double(intersection) / Double(min(lhs.count, rhs.count))
    }

    static func median(_ values: [Double]) -> Double {
        guard values.isEmpty == false else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    static func samePath(_ lhs: String, _ rhs: String) -> Bool {
        let normalize: (String) -> String = {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL.path
        }
        return normalize(lhs) == normalize(rhs)
    }

    static func displayPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    static func lastPathComponent(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    static func truncate(_ text: String, _ maxLength: Int) -> String {
        guard text.count > maxLength else { return text }
        return String(text.prefix(maxLength - 1)) + "…"
    }

    static func currency(_ value: Double) -> String {
        value >= 1 ? String(format: "$%.2f", value) : String(format: "$%.3f", value)
    }

    static func multiplierDescription(_ value: Double, _ baseline: Double) -> String {
        guard baseline > 0 else { return "well above" }
        let multiple = value / baseline
        return multiple >= 10 ? "more than 10× " : String(format: "%.1f× ", multiple)
    }

    static func dayBucket(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    /// Human-scale relative time. Deliberately vague at the low end — "just now"
    /// reads better than "3 minutes ago" in a summary sentence.
    static func relativeDescription(from date: Date?, to now: Date) -> String {
        guard let date else { return "at an unknown time" }
        let seconds = now.timeIntervalSince(date)
        if seconds < 120 { return "just now" }
        if seconds < 3_600 { return "\(Int(seconds / 60)) minutes ago" }
        if seconds < 86_400 {
            let hours = Int(seconds / 3_600)
            return "\(hours) hour\(hours == 1 ? "" : "s") ago"
        }
        let days = Int(seconds / 86_400)
        return "\(days) day\(days == 1 ? "" : "s") ago"
    }
}
