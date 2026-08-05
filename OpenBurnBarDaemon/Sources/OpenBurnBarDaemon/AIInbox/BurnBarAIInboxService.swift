import Foundation
import OpenBurnBarEngine

/// The AI Inbox: a daemon-resident background analyst.
///
/// ## Why this shape
///
/// The daemon is already the always-on, code-signed, credential-holding process
/// that owns the local index. Putting the analyst here means the loop survives
/// app restarts, needs no new launchd job (the daemon is `KeepAlive`, and this
/// repo has no `StartInterval` precedent), and never has to move conversation
/// text between processes to do its work.
///
/// ## The cost discipline
///
/// The loop wakes 288 times a day. Almost every wake must be free, or the
/// feature is a tax rather than a service. So:
///
///   1. A cheap local change signature short-circuits the tick before any
///      subprocess, network call, or model call happens.
///   2. Deterministic detectors run before any model, and they are the ones that
///      catch the highest-value patterns (the CI-waste case). With egress off,
///      the inbox is still genuinely useful and costs exactly nothing.
///   3. The model is the *last* stage, is capped per tick, and is checked
///      against a daily budget read from the authoritative usage ledger.
///
/// ## The trust discipline
///
/// Conversation text is untrusted input (written by other models, quoting the
/// open internet) being fed to a model that can propose memories. Redaction
/// happens at pack-build time, prompts fence and neutralize the data, findings
/// must cite real evidence, a second model on a different provider tries to
/// refute them, and memory proposals still require human approval.
actor BurnBarAIInboxService {
    private let store: BurnBarAIInboxStore
    private let usageRecorder: BurnBarUsageRecorder
    private let executor: any BurnBarProviderExecuting
    private let router: BurnBarProviderRouter
    private let workspaceScout: BurnBarAIInboxWorkspaceScout
    private let github: BurnBarGitHubCLIClient
    private let changeGate: BurnBarAIInboxChangeGate
    private let packBuilder: BurnBarAIInboxEvidencePackBuilder
    private let publisher: BurnBarAIInboxPublisher
    private let logger: BurnBarDaemonLogger
    private let clock: @Sendable () -> Date

    private var loopTask: Task<Void, Never>?
    private var tickIndex = 0
    private var isTicking = false

    init(
        databasePath: String,
        usageRecorder: BurnBarUsageRecorder,
        configStore: BurnBarConfigStore,
        executor: any BurnBarProviderExecuting = BurnBarOpenAICompatibleProviderExecutor(),
        processRunner: any BurnBarAIInboxProcessRunning = BurnBarAIInboxProcessRunner(),
        notifier: (any BurnBarAIInboxNotifying)? = nil,
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "ai-inbox"),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        let store = try BurnBarAIInboxStore(databasePath: databasePath, logger: logger)
        let scout = BurnBarAIInboxWorkspaceScout(runner: processRunner, logger: logger)
        let github = BurnBarGitHubCLIClient(runner: processRunner, logger: logger)

        self.store = store
        self.usageRecorder = usageRecorder
        self.executor = executor
        self.router = BurnBarProviderRouter(
            configStore: configStore,
            logger: BurnBarDaemonLogger(category: "ai-inbox-router")
        )
        self.workspaceScout = scout
        self.github = github
        self.changeGate = BurnBarAIInboxChangeGate(store: store, logger: logger)
        self.packBuilder = BurnBarAIInboxEvidencePackBuilder(
            store: store,
            workspaceScout: scout,
            github: github,
            logger: logger
        )
        self.publisher = BurnBarAIInboxPublisher(
            store: store,
            usageRecorder: usageRecorder,
            notifier: notifier ?? BurnBarAIInboxDistributedNotifier(),
            logger: logger
        )
        self.logger = logger
        self.clock = clock
    }

    // MARK: - Lifecycle

    /// Starts the periodic loop.
    ///
    /// Sleep-first (matching the OAuth refresher): daemon boot is already busy,
    /// and an inbox tick during startup would compete with the work the user is
    /// actually waiting on.
    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = await self?.currentTickInterval() ?? TimeInterval(BurnBarInboxConfig.defaultTickSeconds)
                do {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self?.tick(forced: false)
            }
        }
        logger.info("ai_inbox_loop_started", metadata: [:])
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    private func currentTickInterval() -> TimeInterval {
        TimeInterval(configuration().tickSeconds)
    }

    // MARK: - Configuration

    func configuration() -> BurnBarInboxConfig {
        ((try? store.state(BurnBarAIInboxSchema.StateKey.config, as: BurnBarInboxConfig.self)) ?? nil)
            ?? BurnBarInboxConfig()
    }

    @discardableResult
    func updateConfiguration(_ config: BurnBarInboxConfig) -> BurnBarInboxConfig {
        // Re-init through the memberwise initializer so every value passes the
        // clamping in `BurnBarInboxConfig.init` — an RPC caller cannot persist a
        // 1-second cadence or a negative budget.
        let normalized = BurnBarInboxConfig(
            enabled: config.enabled,
            egressMode: config.egressMode,
            tickSeconds: config.tickSeconds,
            remotePhaseEveryNTicks: config.remotePhaseEveryNTicks,
            dailyBudgetUSD: config.dailyBudgetUSD,
            maxVerifierCallsPerTick: config.maxVerifierCallsPerTick,
            perTickPromptTokenCap: config.perTickPromptTokenCap,
            analystProviderID: config.analystProviderID,
            analystModel: config.analystModel,
            verifierProviderID: config.verifierProviderID,
            verifierModel: config.verifierModel,
            githubEnabled: config.githubEnabled,
            notifyOnP1: config.notifyOnP1,
            lookbackMinutes: config.lookbackMinutes
        )
        try? store.setState(
            BurnBarAIInboxSchema.StateKey.config,
            value: normalized,
            now: clock()
        )
        logger.info(
            "ai_inbox_config_updated",
            metadata: [
                "enabled": "\(normalized.enabled)",
                "egress_mode": normalized.egressMode.rawValue,
                "tick_seconds": "\(normalized.tickSeconds)"
            ]
        )
        return normalized
    }

    // MARK: - Reads

    func list(_ request: BurnBarInboxListRequest) throws -> BurnBarInboxListResponse {
        try store.list(request)
    }

    func item(id: String) throws -> BurnBarInboxItemDetail? {
        try store.item(id: id)
    }

    func recentRuns(limit: Int) async throws -> BurnBarInboxRunsResponse {
        let config = configuration()
        return BurnBarInboxRunsResponse(
            runs: try store.recentRuns(limit: limit),
            todaySpendUSD: (try? await spendToday()) ?? 0,
            dailyBudgetUSD: config.dailyBudgetUSD
        )
    }

    // MARK: - Tick

    @discardableResult
    func runNow(force: Bool) async -> BurnBarInboxRunNowResponse {
        guard isTicking == false else {
            return BurnBarInboxRunNowResponse(tickID: nil, accepted: false, reason: "A tick is already running.")
        }
        let config = configuration()
        guard config.enabled || force else {
            return BurnBarInboxRunNowResponse(
                tickID: nil,
                accepted: false,
                reason: "The AI Inbox is turned off."
            )
        }
        let tickID = await tick(forced: force)
        return BurnBarInboxRunNowResponse(tickID: tickID, accepted: tickID != nil)
    }

    @discardableResult
    func tick(forced: Bool) async -> String? {
        guard isTicking == false else { return nil }
        isTicking = true
        defer { isTicking = false }

        tickIndex &+= 1
        let now = clock()
        let config = configuration()

        guard config.enabled || forced else { return nil }

        let tickID = "tick_\(UUID().uuidString.lowercased())"

        // Workspace signatures need a cheap pre-pass: the gate has to know
        // whether git moved before deciding to do real work.
        // The gate needs a workspace signal, but it must NOT pay for one. A full
        // `snapshots(for:)` here would spawn ~6 git subprocesses per workspace on
        // every one of the ~288 daily wakes — including the overwhelming majority
        // that end in "nothing changed". So the gate reads a `stat`-only
        // fingerprint, and the real snapshot is taken inside the pipeline, only
        // once the gate has actually opened.
        let recentPaths = ((try? store.recentConversations(
            since: now.addingTimeInterval(-Double(config.lookbackMinutes) * 60),
            limit: BurnBarAIInboxEvidencePackBuilder.maxConversations
        )) ?? []).compactMap(\.workingDirectory)

        let decision = changeGate.decide(
            config: config,
            tickIndex: tickIndex,
            forced: forced,
            usageLedgerSignature: await usageLedgerSignature(),
            workspaceSignatures: [workspaceScout.gateFingerprint(for: recentPaths)],
            now: now
        )

        var telemetry = BurnBarInboxRunTelemetry(
            tickID: tickID,
            startedAt: now,
            gateResult: decision.telemetryResult,
            egressMode: config.egressMode
        )
        try? store.beginRun(telemetry, gateSignature: decision.signature)

        guard decision.runsPipeline else {
            // The common case. One SQL write, nothing else.
            telemetry = Self.finishing(telemetry, finishedAt: clock())
            try? store.finishRun(telemetry)
            return tickID
        }

        do {
            let result = try await runPipeline(
                tickID: tickID,
                config: config,
                decision: decision,
                now: now
            )
            changeGate.commit(signature: decision.signature, now: now)
            telemetry = BurnBarInboxRunTelemetry(
                tickID: tickID,
                startedAt: now,
                finishedAt: clock(),
                gateResult: decision.telemetryResult,
                egressMode: config.egressMode,
                llmCalls: result.calls.count,
                inputTokens: result.calls.reduce(0) { $0 + $1.inputTokens },
                outputTokens: result.calls.reduce(0) { $0 + $1.outputTokens },
                costUSD: result.calls.reduce(0) { $0 + $1.costUSD },
                itemsNew: result.publish.itemsNew,
                itemsUpdated: result.publish.itemsUpdated,
                itemsResolved: result.publish.itemsResolved
            )
            try? store.finishRun(telemetry)
            logger.info(
                "ai_inbox_tick_completed",
                metadata: [
                    "gate": decision.telemetryResult.rawValue,
                    "llm_calls": "\(result.calls.count)",
                    "items_new": "\(result.publish.itemsNew)",
                    "items_resolved": "\(result.publish.itemsResolved)"
                ]
            )
        } catch {
            telemetry = BurnBarInboxRunTelemetry(
                tickID: tickID,
                startedAt: now,
                finishedAt: clock(),
                gateResult: .failed,
                egressMode: config.egressMode,
                error: String(describing: error).prefix(300).description
            )
            try? store.finishRun(telemetry)
            logger.warning("ai_inbox_tick_failed", metadata: ["error": "\(error)"])
        }
        return tickID
    }

    private struct PipelineResult {
        let calls: [BurnBarAIInboxModelCall]
        let publish: BurnBarAIInboxPublishResult
    }

    private func runPipeline(
        tickID: String,
        config: BurnBarInboxConfig,
        decision: BurnBarAIInboxGateDecision,
        now: Date
    ) async throws -> PipelineResult {
        let pack = await packBuilder.build(
            tickID: tickID,
            config: config,
            includeRemote: decision.includesRemote,
            now: now
        )

        let detectors = BurnBarAIInboxDetectors(now: now)
        var findings = detectors.run(pack: pack, config: config)
        findings.append(contentsOf: detectors.detectCostAnomaly(
            pack: pack,
            baselines: costBaselines()
        ))
        updateCostBaselines(pack: pack, now: now)

        if let notice = githubAvailabilityFinding(pack: pack, now: now) {
            findings.append(notice)
        }

        var calls: [BurnBarAIInboxModelCall] = []
        var briefMarkdown = ""
        var modelProvenance = "local-rules"
        var suppressed: [String] = []

        let budget = await budgetState(config: config)
        if config.egressMode.allowsModelCalls, budget.isExhausted == false, pack.isEmpty == false {
            let analyst = BurnBarAIInboxAnalyst(executor: executor, router: router, logger: logger)
            do {
                let analysis = try await analyst.analyze(
                    pack: pack,
                    detectorFindings: findings,
                    config: config,
                    now: now
                )
                calls.append(contentsOf: analysis.calls)
                briefMarkdown = analysis.briefMarkdown
                if let first = analysis.calls.first { modelProvenance = first.provenance }

                let verifier = BurnBarAIInboxVerifier(
                    executor: executor,
                    router: router,
                    workspaceScout: workspaceScout,
                    logger: logger
                )
                let verification = await verifier.verify(
                    findings: findings + analysis.findings,
                    pack: pack,
                    config: config,
                    now: now
                )
                calls.append(contentsOf: verification.calls)
                findings = verification.findings
                suppressed = verification.suppressedFingerprints
                if let verifierCall = verification.calls.first {
                    modelProvenance += "+\(verifierCall.provenance)"
                }
            } catch {
                // Publish the deterministic findings anyway. A provider outage
                // must degrade the feature, not disable it.
                logger.warning("ai_inbox_analysis_failed", metadata: ["error": "\(error)"])
                briefMarkdown = Self.ruleBasedBrief(pack: pack, findings: findings, now: now)
            }
        } else {
            briefMarkdown = Self.ruleBasedBrief(pack: pack, findings: findings, now: now)
            if budget.isExhausted, config.egressMode.allowsModelCalls {
                findings.append(Self.budgetFinding(budget: budget, config: config, now: now))
            }
        }

        let publish = await publisher.publish(
            findings: findings,
            briefMarkdown: briefMarkdown,
            pack: pack,
            config: config,
            tickID: tickID,
            modelProvenance: modelProvenance,
            calls: calls,
            newlySuppressedFingerprints: suppressed,
            now: now
        )
        return PipelineResult(calls: calls, publish: publish)
    }

    // MARK: - Budget

    struct BudgetState: Sendable {
        let spentUSD: Double
        let limitUSD: Double
        var isExhausted: Bool { limitUSD > 0 && spentUSD >= limitUSD }
        var remainingUSD: Double { max(0, limitUSD - spentUSD) }
    }

    /// Reads the authoritative daemon ledger, not the app's SQLite mirror: the
    /// mirror lags behind an app-side import, and a budget that lags is a budget
    /// that overspends.
    func budgetState(config: BurnBarInboxConfig) async -> BudgetState {
        BudgetState(spentUSD: (try? await spendToday()) ?? 0, limitUSD: config.dailyBudgetUSD)
    }

    private func spendToday() async throws -> Double {
        let startOfDay = Calendar.current.startOfDay(for: clock())
        return try await usageRecorder.records()
            .map(\.event)
            .filter { $0.executionSourceID == BurnBarAIInboxUsage.executionSourceID && $0.recordedAt >= startOfDay }
            .reduce(0) { $0 + $1.cost }
    }

    /// Cheap "did spend happen?" signal for the change gate — count and latest
    /// timestamp, no full scan of amounts.
    private func usageLedgerSignature() async -> String {
        guard let records = try? await usageRecorder.records() else { return "ledger-unavailable" }
        let latest = records.map(\.event.recordedAt).max()
        return BurnBarAIInboxStableHasher.hash([
            String(records.count),
            latest.map(BurnBarAIInboxTimestamp.string(from:)) ?? "-"
        ])
    }

    // MARK: - Cost baselines

    private func costBaselines() -> [String: BurnBarAIInboxDetectors.CostBaseline] {
        let stored = try? store.state(
            BurnBarAIInboxSchema.StateKey.costBaselines,
            as: [String: BurnBarAIInboxDetectors.CostBaseline].self
        )
        return stored.flatMap { $0 } ?? [:]
    }

    /// Appends this window's spend per project to the rolling baseline.
    ///
    /// Rate-limited to one sample per hour: sampling every tick would make the
    /// baseline a measure of tick cadence rather than of spending habits.
    private func updateCostBaselines(pack: BurnBarAIInboxEvidencePack, now: Date) {
        var baselines = costBaselines()
        let byProject = Dictionary(grouping: pack.usage, by: \.projectName)
        for (project, aggregates) in byProject where project.isEmpty == false {
            let windowCost = aggregates.reduce(0.0) { $0 + $1.costUSD }
            var baseline = baselines[project] ?? BurnBarAIInboxDetectors.CostBaseline(
                samples: [],
                updatedAt: Date(timeIntervalSince1970: 0)
            )
            guard now.timeIntervalSince(baseline.updatedAt) >= 3_600 else { continue }
            baseline.samples.append(windowCost)
            if baseline.samples.count > BurnBarAIInboxDetectors.CostBaseline.maxSamples {
                baseline.samples.removeFirst(baseline.samples.count - BurnBarAIInboxDetectors.CostBaseline.maxSamples)
            }
            baseline.updatedAt = now
            baselines[project] = baseline
        }
        try? store.setState(BurnBarAIInboxSchema.StateKey.costBaselines, value: baselines, now: now)
    }

    // MARK: - Synthetic findings

    /// Surfaces a capability gap as a one-time item, so "GitHub checks silently
    /// off" never masquerades as "nothing to report".
    private func githubAvailabilityFinding(
        pack: BurnBarAIInboxEvidencePack,
        now: Date
    ) -> BurnBarAIInboxFinding? {
        guard case .available = pack.githubAvailability else {
            guard let explanation = pack.githubAvailability.explanation else { return nil }
            // Only complain when there is actually a GitHub repo in play.
            guard pack.workspaces.contains(where: { $0.githubSlug != nil }) else { return nil }
            return BurnBarAIInboxFinding(
                kind: .system,
                title: "GitHub checks are unavailable",
                summaryMarkdown: explanation,
                priority: .p4,
                confidence: 1.0,
                evidenceIDs: [],
                fingerprint: BurnBarAIInboxFinding.fingerprint(
                    kind: .system,
                    scope: "github",
                    subject: "availability"
                ),
                needsVerification: false,
                deterministicVerification: BurnBarInboxVerification(
                    verdict: .deterministic,
                    reason: "Probed the local `gh` installation.",
                    checkedAt: now
                ),
                source: .detector
            )
        }
        return nil
    }

    static func budgetFinding(
        budget: BudgetState,
        config: BurnBarInboxConfig,
        now: Date
    ) -> BurnBarAIInboxFinding {
        BurnBarAIInboxFinding(
            kind: .budget,
            title: "AI Inbox reached its daily budget",
            summaryMarkdown: """
                The inbox has spent \(BurnBarAIInboxDetectors.currency(budget.spentUSD)) today, reaching its \
                \(BurnBarAIInboxDetectors.currency(budget.limitUSD)) limit, so it has fallen back to \
                local-only analysis for the rest of the day.

                Deterministic detection keeps running — only the written summaries pause.
                """,
            priority: .p4,
            confidence: 1.0,
            evidenceIDs: [],
            fingerprint: BurnBarAIInboxFinding.fingerprint(
                kind: .budget,
                scope: "global",
                subject: BurnBarAIInboxDetectors.dayBucket(now)
            ),
            metrics: [
                "spent_usd": String(format: "%.4f", budget.spentUSD),
                "limit_usd": String(format: "%.2f", budget.limitUSD)
            ],
            actions: [
                BurnBarInboxAction(
                    id: "open-settings",
                    kind: .openSettings,
                    title: "Adjust the budget",
                    value: "ai-inbox",
                    isPrimary: true
                )
            ],
            needsVerification: false,
            deterministicVerification: nil,
            source: .detector
        )
    }

    /// The zero-egress brief.
    ///
    /// This is the honest, arithmetic-only version of "what has been going on".
    /// It is what the user gets by default, and it is deliberately good enough to
    /// be worth reading on its own.
    static func ruleBasedBrief(
        pack: BurnBarAIInboxEvidencePack,
        findings: [BurnBarAIInboxFinding],
        now: Date
    ) -> String {
        guard pack.conversations.isEmpty == false || findings.isEmpty == false else { return "" }

        var lines: [String] = []
        let projects = Dictionary(grouping: pack.conversations) { $0.projectName ?? "unattributed" }
            .mapValues(\.count)
            .sorted { $0.value > $1.value }

        if pack.conversations.isEmpty == false {
            let projectSummary = projects
                .prefix(3)
                .map { "**\($0.key)** (\($0.value) session\($0.value == 1 ? "" : "s"))" }
                .joined(separator: ", ")
            lines.append("\(pack.conversations.count) agent session\(pack.conversations.count == 1 ? "" : "s") since \(BurnBarAIInboxDetectors.relativeDescription(from: pack.windowStart, to: now)), mostly in \(projectSummary).")
        }

        let dirty = pack.workspaces.filter(\.isDirty)
        if dirty.isEmpty == false {
            lines.append("\(dirty.count) workspace\(dirty.count == 1 ? " has" : "s have") uncommitted changes.")
        }

        let totalSpend = pack.usage.reduce(0.0) { $0 + $1.costUSD }
        if totalSpend > 0 {
            lines.append("Spend in this window: \(BurnBarAIInboxDetectors.currency(totalSpend)).")
        }

        let alerts = findings.filter { $0.kind.isAlert }
        if alerts.isEmpty == false {
            lines.append("\(alerts.count) thing\(alerts.count == 1 ? "" : "s") worth a look below.")
        }

        // Say when the picture is stale rather than presenting it as current.
        // A brief that quietly describes a 10-minute-old world is worse than one
        // that admits it.
        if pack.hasNotableIndexLag, let lag = pack.indexLagSeconds {
            lines.append("(Sessions from the last \(Int(lag / 60)) minutes may not be included yet.)")
        }

        return lines.joined(separator: " ")
    }

    private static func finishing(
        _ telemetry: BurnBarInboxRunTelemetry,
        finishedAt: Date
    ) -> BurnBarInboxRunTelemetry {
        BurnBarInboxRunTelemetry(
            tickID: telemetry.tickID,
            startedAt: telemetry.startedAt,
            finishedAt: finishedAt,
            gateResult: telemetry.gateResult,
            egressMode: telemetry.egressMode,
            llmCalls: telemetry.llmCalls,
            inputTokens: telemetry.inputTokens,
            outputTokens: telemetry.outputTokens,
            costUSD: telemetry.costUSD,
            itemsNew: telemetry.itemsNew,
            itemsUpdated: telemetry.itemsUpdated,
            itemsResolved: telemetry.itemsResolved,
            error: telemetry.error
        )
    }
}

/// Ships P1 notifications to the app through the existing daemon→app
/// distributed-notification channel (the same one Mission Control uses), so the
/// inbox needs no notification plumbing of its own.
struct BurnBarAIInboxDistributedNotifier: BurnBarAIInboxNotifying {
    func notify(title: String, body: String, itemID: String) async {
        try? await BurnBarLocalNotificationBridge.shared.deliver(
            title: title,
            body: body,
            // Tapping the alert opens the item, not just the app.
            deepLink: "openburnbar://inbox/\(itemID)",
            category: OpenBurnBarDistributedNotifications.Category.aiInbox
        )
    }
}
