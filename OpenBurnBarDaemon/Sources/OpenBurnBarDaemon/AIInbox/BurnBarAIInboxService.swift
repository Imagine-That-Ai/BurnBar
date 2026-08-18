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
            lookbackMinutes: config.lookbackMinutes,
            founderLensEnabled: config.founderLensEnabled,
            perReplyBudgetUSD: config.perReplyBudgetUSD,
            maxThreadTurns: config.maxThreadTurns,
            budgetCountsSubscriptionSpend: config.budgetCountsSubscriptionSpend,
            // Carried through explicitly: this initializer is the normalization
            // gate, and a field omitted here silently resets to its default on
            // every config update.
            briefDetail: config.briefDetail,
            briefRegister: config.briefRegister
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

    // MARK: - Founder Lens: threads + replies

    func thread(fingerprint: String) throws -> BurnBarInboxThread? {
        try store.thread(fingerprint: fingerprint)
    }

    func reply(_ request: BurnBarInboxReplyRequest) async -> BurnBarInboxReplyResponse {
        let config = configuration()
        let budget = await budgetState(config: config)
        // Bind the thread to its condition's most recent item so the reply can
        // quote what the user is actually looking at.
        let item = try? store.itemDetail(fingerprint: request.fingerprint)
        let service = BurnBarAIInboxReplyService(
            store: store,
            executor: executor,
            router: router,
            usageRecorder: usageRecorder,
            logger: logger
        )
        return await service.reply(
            request: request,
            config: config,
            dailyBudget: budget,
            item: item,
            now: clock()
        )
    }

    // MARK: - Founder Lens: plan ledger

    func plansList(_ request: BurnBarInboxPlansListRequest) throws -> BurnBarInboxPlansListResponse {
        BurnBarInboxPlansListResponse(plans: try store.plans(statuses: request.statuses, limit: request.limit))
    }

    func planGet(_ request: BurnBarInboxPlanGetRequest) throws -> BurnBarInboxPlanGetResponse {
        BurnBarInboxPlanGetResponse(plan: try store.plan(id: request.id))
    }

    func planAccept(_ request: BurnBarInboxPlanAcceptRequest) throws -> BurnBarInboxPlanAcceptResponse {
        // The pack decides which judgment voice owns the plan; reject unknowns
        // rather than storing free text a later prompt would interpolate.
        guard BurnBarFounderLens.Pack(rawValue: request.pack) != nil else {
            throw BurnBarAIInboxStoreError.sqlite("Unknown judgment pack: \(request.pack)")
        }
        let (plan, step) = try store.acceptPlan(
            candidate: request.candidate,
            pack: request.pack,
            now: clock()
        )
        logger.info(
            "ai_inbox_plan_accepted",
            metadata: ["plan_id": plan.id, "step_id": step.id]
        )
        return BurnBarInboxPlanAcceptResponse(plan: plan, step: step)
    }

    func planUpdateStep(_ request: BurnBarInboxPlanUpdateStepRequest) throws -> BurnBarInboxPlanUpdateStepResponse {
        BurnBarInboxPlanUpdateStepResponse(
            step: try store.updatePlanStep(
                stepID: request.stepID,
                status: request.status,
                missionID: request.missionID,
                followupID: request.followupID,
                now: clock()
            )
        )
    }

    func planGrade(_ request: BurnBarInboxPlanGradeRequest) throws -> BurnBarInboxPlanGradeResponse {
        let (step, average) = try store.gradePlanStep(
            stepID: request.stepID,
            grade: request.grade,
            noteMarkdown: request.noteMarkdown,
            now: clock()
        )
        return BurnBarInboxPlanGradeResponse(step: step, planGradeAverage: average)
    }

    func memoryExport(_ request: BurnBarInboxMemoryExportRequest) throws -> BurnBarInboxMemoryExportResponse {
        BurnBarInboxMemoryExportResponse(
            stored: try store.replaceMemoryExport(entries: request.entries, now: clock())
        )
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
        let recentPaths = (try? store.recentConversationWorkingDirectories(
            since: now.addingTimeInterval(-Double(config.lookbackMinutes) * 60),
            limit: BurnBarAIInboxEvidencePackBuilder.maxConversations
        )) ?? []

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
                itemsResolved: result.publish.itemsResolved,
                // The run finished, but say so honestly when the analyst was
                // skipped: a row of zeros with no explanation is what let this
                // fail silently for a whole night.
                error: result.analystFailure.map { "analyst unavailable: \($0)" }
            )
            try? store.finishRun(telemetry)
            logger.info(
                "ai_inbox_tick_completed",
                metadata: [
                    "gate": decision.telemetryResult.rawValue,
                    "llm_calls": "\(result.calls.count)",
                    "items_new": "\(result.publish.itemsNew)",
                    "items_resolved": "\(result.publish.itemsResolved)",
                    "analyst_failed": result.analystFailure == nil ? "false" : "true"
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
        /// Set when the analyst threw and the tick degraded to the rule-based
        /// brief. Carried into run telemetry so `daemon.inbox.runs.recent`
        /// answers "why is llmCalls 0?" without a log-privacy safari.
        let analystFailure: String?
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
        var analystFailure: String?
        // Surviving action hints from this tick. Empty on every path that never
        // reached the analyst, which is exactly right: no model, no hints.
        var actionHints: [BurnBarAIInboxActionHint] = []

        // Standing commitments: active Founder Plans and approved snippets the
        // synthesis must build on. Populated from the plan ledger; empty when
        // the lens is off or nothing is active.
        let standingCommitments = config.founderLensEnabled
            ? await standingCommitments(now: now)
            : []

        let budget = await budgetState(config: config)
        if config.egressMode.allowsModelCalls, budget.isExhausted == false, pack.isEmpty == false {
            let analyst = BurnBarAIInboxAnalyst(executor: executor, router: router, logger: logger)
            do {
                let analysis = try await analyst.analyze(
                    pack: pack,
                    detectorFindings: findings,
                    config: config,
                    now: now,
                    standingCommitments: standingCommitments
                )
                calls.append(contentsOf: analysis.calls)
                briefMarkdown = analysis.briefMarkdown
                actionHints = analysis.actionHints
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
                //
                // But degrade LOUDLY. This used to be a `logger.warning`, and
                // every level except `silentFailure` emits its payload under
                // os_log's private-redaction specifier — so a mis-pinned model
                // or an unusable credential looked exactly like "nothing to
                // report" for as long as nobody rebuilt the daemon.
                // `silentFailure` emits publicly and still runs the metadata
                // through the secret scrubber, which is the right trade for a
                // provider/model routing diagnostic.
                //
                // Keep every brace character out of this comment.
                // tools/error-debt/count-error-debt.py finds catch bodies with
                // a regex whose body group excludes the closing brace, so the
                // first brace inside a comment truncates the match and makes
                // this fully-populated block report as an empty catch.
                let reason = Self.analystFailureReason(error)
                logger.silentFailure(
                    "ai_inbox_analysis",
                    error: error,
                    context: [
                        "analyst_provider": config.analystProviderID,
                        "analyst_model": config.analystModel,
                        "egress_mode": config.egressMode.rawValue
                    ]
                )
                analystFailure = reason
                findings.append(
                    Self.analystUnavailableFinding(reason: reason, config: config, now: now)
                )
                briefMarkdown = Self.ruleBasedBrief(pack: pack, findings: findings, now: now)
            }
        } else {
            briefMarkdown = Self.ruleBasedBrief(pack: pack, findings: findings, now: now)
            if budget.isExhausted, config.egressMode.allowsModelCalls {
                findings.append(Self.budgetFinding(budget: budget, config: config, now: now))
            }
        }

        if config.founderLensEnabled {
            // One primary next move per item, enforced in code (never by the
            // model), and unverified claims lose theirs. The rule-based brief
            // mentions standing commitments so the no-model path compounds too.
            findings = findings.map(BurnBarFounderLens.NextMoveRouter.enforce(finding:))
            modelProvenance += "+\(BurnBarFounderLens.provenanceStamp)"
            if standingCommitments.isEmpty == false {
                let lines = standingCommitments.prefix(3).map { "- \($0.summary)" }
                briefMarkdown += (briefMarkdown.isEmpty ? "" : "\n\n")
                    + "**Standing commitments:**\n" + lines.joined(separator: "\n")
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
            briefActionHints: actionHints,
            now: now
        )
        return PipelineResult(calls: calls, publish: publish, analystFailure: analystFailure)
    }

    // MARK: - Standing commitments

    /// Active Founder Plans (and, later, approved memory snippets) rendered as
    /// context lines for synthesis. Reads the daemon-owned plan ledger; returns
    /// empty when the ledger has nothing active — the hook itself is always
    /// safe to call.
    func standingCommitments(now: Date) async -> [BurnBarFounderLens.StandingCommitment] {
        do {
            return try store.standingCommitments(limit: 8, now: now)
        } catch {
            logger.warning("ai_inbox_standing_commitments_failed", metadata: ["error": "\(error)"])
            return []
        }
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
        let countsSubscription = configuration().budgetCountsSubscriptionSpend
        return try await usageRecorder.sumCost(since: startOfDay) { event in
            guard event.executionSourceID == BurnBarAIInboxUsage.executionSourceID else {
                return false
            }
            // The protective budget guards real dollars. Subscription-routed
            // calls are plan-covered imputed value — they only count when the
            // user opts in. `unknown` counts as spend: fail-protective.
            if countsSubscription { return true }
            return BurnBarBillingProvenance.effectiveKind(of: event) != .subscription
        }
    }

    /// Cheap "did spend happen?" signal for the change gate — count and latest
    /// timestamp, no full scan of amounts.
    private func usageLedgerSignature() async -> String {
        guard let signature = try? await usageRecorder.signature() else { return "ledger-unavailable" }
        return BurnBarAIInboxStableHasher.hash([
            String(signature.recordCount),
            signature.latestRecordedAt.map(BurnBarAIInboxTimestamp.string(from:)) ?? "-"
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

    /// Human-readable reason for an analyst throw.
    ///
    /// `LocalizedError.errorDescription` is the sentence the router and the
    /// executor already wrote for a human ("Provider 'x' is missing
    /// credentials."); `String(describing:)` on those enums yields
    /// `missingCredential("x")`, which is worse. Fall back to the raw
    /// description only for errors that carry no message.
    static func analystFailureReason(_ error: Error) -> String {
        let localized = (error as? LocalizedError)?.errorDescription?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let reason: String
        if let localized, localized.isEmpty == false {
            reason = localized
        } else {
            reason = String(describing: error)
        }
        return String(reason.prefix(400))
    }

    /// Surfaces "the analyst never ran" as an inbox item.
    ///
    /// Without this the inbox degrades to the rule-based brief and looks
    /// *identical* to a healthy quiet day — which is exactly how a broken model
    /// pin survives.
    ///
    /// The fingerprint is deliberately NOT scoped to the pinned route. The
    /// condition is "the analyst is down", not "the analyst is down on this
    /// route" — scoping by route means trying four models to find a working one
    /// leaves four permanently-open items. The route is *measurement*, so it
    /// lives in the body and the metrics, and the single item updates in place.
    static func analystUnavailableFinding(
        reason: String,
        config: BurnBarInboxConfig,
        now: Date
    ) -> BurnBarAIInboxFinding {
        let route = "\(config.analystProviderID):\(config.analystModel)"
        return BurnBarAIInboxFinding(
            kind: .system,
            title: "Analyst could not run",
            summaryMarkdown: """
                The AI Inbox fell back to local rules because its analyst model could not be reached.

                **Route:** `\(route)`
                **Reason:** \(reason)

                Deterministic detection kept running, so alerts below are still real — but there is no \
                written synthesis for this tick, and nothing was spent.
                """,
            priority: .p2,
            confidence: 1.0,
            evidenceIDs: [],
            fingerprint: BurnBarAIInboxFinding.analystUnavailableFingerprint,
            metrics: [
                // `analyst_provider` doubles as the marker the publisher looks
                // for when deciding this notice can be auto-resolved.
                "analyst_provider": config.analystProviderID,
                "analyst_model": config.analystModel
            ],
            actions: [
                BurnBarInboxAction(
                    id: "open-settings",
                    kind: .openSettings,
                    title: "Check the analyst model",
                    value: "ai-inbox",
                    isPrimary: true
                )
            ],
            needsVerification: false,
            deterministicVerification: BurnBarInboxVerification(
                verdict: .deterministic,
                reason: "Observed directly: the analyst call threw on this tick.",
                checkedAt: now
            ),
            source: .detector
        )
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

    /// The zero-egress brief — short colleague prose from deterministic evidence.
    ///
    /// This is what the user gets by default (`egressMode` off, budget exhausted,
    /// or model failure). It must be worth reading without an LLM: concentration,
    /// thin-index honesty, workspace dirt, spend context, and pointers to alerts.
    static func ruleBasedBrief(
        pack: BurnBarAIInboxEvidencePack,
        findings: [BurnBarAIInboxFinding],
        now: Date
    ) -> String {
        BurnBarAIInboxBriefAuthor.ruleBasedBrief(pack: pack, findings: findings, now: now)
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

// MARK: - Zero-egress brief author

/// Writes the default (no-model) brief and chooses citations worth clicking.
///
/// Arithmetic glue — "9 sessions mostly in X (9 sessions)" — is not a brief.
/// This author turns the same pack into short colleague prose and refuses to
/// materialize five identical empty Factory shells as "evidence".
enum BurnBarAIInboxBriefAuthor {
    static func ruleBasedBrief(
        pack: BurnBarAIInboxEvidencePack,
        findings: [BurnBarAIInboxFinding],
        now: Date
    ) -> String {
        guard pack.conversations.isEmpty == false
            || pack.workspaces.isEmpty == false
            || pack.usage.isEmpty == false
            || findings.isEmpty == false else {
            return ""
        }

        var sentences: [String] = []
        sentences.append(contentsOf: leadSentences(pack: pack, now: now))
        if let signal = signalSentence(pack: pack) {
            sentences.append(signal)
        }
        if let workspace = workspaceSentence(pack: pack) {
            sentences.append(workspace)
        }
        if let github = githubSentence(pack: pack) {
            sentences.append(github)
        }
        if let spend = spendSentence(pack: pack) {
            sentences.append(spend)
        }

        let alerts = findings.filter(\.kind.isAlert)
        if alerts.isEmpty == false {
            let titles = alerts.prefix(2).map(\.title)
            if alerts.count == 1, let only = titles.first {
                sentences.append("One thing to check below: \(only).")
            } else {
                let listed = titles.joined(separator: "; ")
                let more = alerts.count > titles.count
                    ? " (+\(alerts.count - titles.count) more)"
                    : ""
                sentences.append("Worth a look below: \(listed)\(more).")
            }
        }

        if pack.hasNotableIndexLag, let lag = pack.indexLagSeconds {
            sentences.append(
                "Sessions from the last \(max(1, Int(lag / 60))) minutes may not be included yet."
            )
        }

        return sentences.joined(separator: " ")
    }

    static func title(pack: BurnBarAIInboxEvidencePack, now: Date) -> String {
        let projects = rankedProjects(pack: pack)
        let sessions = pack.conversations.count
        let substantive = pack.conversations.filter { $0.messageCount > 0 }.count

        if projects.count == 1, let project = projects.first {
            if sessions == 0 {
                return "Activity around \(project.name)"
            }
            if substantive == 0 {
                return "\(project.name): \(sessions) session\(sessions == 1 ? "" : "s"), thin index"
            }
            if sessions == 1 {
                return "Session in \(project.name)"
            }
            if project.share >= 0.8 {
                return "\(project.name) focus — \(sessions) sessions"
            }
            return "\(sessions) sessions, mostly \(project.name)"
        }

        if projects.count > 1 {
            let top = projects.prefix(2).map(\.name).joined(separator: " + ")
            return "\(sessions) sessions across \(top)"
        }

        if sessions > 0 {
            return substantive == 0
                ? "\(sessions) sessions, thin index"
                : "\(sessions) recent sessions"
        }
        if pack.workspaces.contains(where: \.isDirty) {
            return "Uncommitted work waiting"
        }
        return "Recent activity"
    }

    static func evidenceIDs(pack: BurnBarAIInboxEvidencePack, limit: Int = 5) -> [String] {
        var ids: [String] = []
        var seenWorkspaces = Set<String>()
        /// Empty Factory shells often share a project label but carry nil
        /// `workspacePath` and unique conversation ids — dedupe on the short
        /// project/path label or we re-list the same hollow row five times.
        var seenEmptyGroups = Set<String>()

        func consider(_ conversation: BurnBarAIInboxConversationExcerpt) {
            guard ids.count < limit else { return }
            let workspaceKey = conversation.workspacePath ?? conversation.conversationID
            if conversation.messageCount == 0 {
                let group = shortLabel(conversation.projectName)
                    ?? shortLabel(conversation.workspacePath)
                    ?? conversation.workspacePath
                    ?? conversation.conversationID
                guard seenEmptyGroups.insert(group).inserted else { return }
                _ = seenWorkspaces.insert(workspaceKey)
            } else {
                _ = seenWorkspaces.insert(workspaceKey)
            }
            ids.append(conversation.evidenceID)
        }

        let substantive = pack.conversations
            .filter { $0.messageCount > 0 }
            .sorted { ($0.endedAt ?? .distantPast) > ($1.endedAt ?? .distantPast) }
        for conversation in substantive {
            consider(conversation)
        }

        for workspace in pack.workspaces where workspace.isDirty {
            guard ids.count < limit else { break }
            let id = "workspace:\(workspace.path)"
            if ids.contains(id) == false {
                ids.append(id)
            }
        }

        for aggregate in pack.usage.sorted(by: { $0.costUSD > $1.costUSD }) where aggregate.costUSD > 0 {
            guard ids.count < limit else { break }
            let id = "usage:\(aggregate.projectName):\(aggregate.model)"
            if ids.contains(id) == false {
                ids.append(id)
            }
        }

        if ids.count < limit {
            let shells = pack.conversations
                .filter { $0.messageCount == 0 }
                .sorted { ($0.endedAt ?? .distantPast) > ($1.endedAt ?? .distantPast) }
            for conversation in shells {
                consider(conversation)
            }
        }

        return ids
    }

    static func metrics(pack: BurnBarAIInboxEvidencePack) -> [String: String] {
        var metrics: [String: String] = [:]
        let sessions = pack.conversations.count
        let substantive = pack.conversations.filter { $0.messageCount > 0 }.count
        let projects = Set(
            pack.conversations.compactMap {
                shortLabel($0.projectName) ?? shortLabel($0.workspacePath)
            }
        )
        let dirty = pack.workspaces.filter(\.isDirty).count
        let spend = pack.usage.reduce(0.0) { $0 + $1.costUSD }

        if sessions > 0 {
            metrics["sessions"] = String(sessions)
        }
        if substantive > 0, substantive != sessions {
            metrics["with_messages"] = String(substantive)
        }
        if projects.isEmpty == false {
            metrics["projects"] = String(projects.count)
        }
        if dirty > 0 {
            metrics["dirty_workspaces"] = String(dirty)
        }
        if spend > 0 {
            metrics["spend_usd"] = String(format: "%.3f", spend)
        }
        return metrics
    }

    static func conversationDetail(_ conversation: BurnBarAIInboxConversationExcerpt) -> String {
        let provider = conversation.provider.trimmingCharacters(in: .whitespacesAndNewlines)
        if conversation.messageCount <= 0 {
            let name = provider.isEmpty ? "session" : provider
            return "\(name) · empty shell (not indexed yet)"
        }
        let providerBit = provider.isEmpty ? "session" : provider
        return "\(providerBit) · \(conversation.messageCount) messages"
    }

    static func shortLabel(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        if trimmed == "unattributed" { return nil }
        if trimmed.contains("/") || trimmed.hasPrefix("~") {
            let component = BurnBarAIInboxDetectors.lastPathComponent(trimmed)
            return component.isEmpty ? nil : component
        }
        return trimmed
    }

    // MARK: Private

    private struct RankedProject {
        let name: String
        let count: Int
        var share: Double
    }

    private static func rankedProjects(pack: BurnBarAIInboxEvidencePack) -> [RankedProject] {
        let total = max(1, pack.conversations.count)
        let grouped = Dictionary(grouping: pack.conversations) {
            shortLabel($0.projectName) ?? shortLabel($0.workspacePath) ?? "unattributed"
        }
        return grouped
            .map {
                RankedProject(
                    name: $0.key,
                    count: $0.value.count,
                    share: Double($0.value.count) / Double(total)
                )
            }
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    private static func leadSentences(
        pack: BurnBarAIInboxEvidencePack,
        now: Date
    ) -> [String] {
        let sessions = pack.conversations.count
        guard sessions > 0 else {
            if pack.workspaces.contains(where: \.isDirty) {
                return ["No new agent sessions in this window, but workspace dirt is still sitting around."]
            }
            return []
        }

        let window = BurnBarAIInboxDetectors.relativeDescription(from: pack.windowStart, to: now)
        let projects = rankedProjects(pack: pack)
        let substantive = pack.conversations.filter { $0.messageCount > 0 }.count
        let providers = Dictionary(grouping: pack.conversations, by: \.provider)
            .mapValues(\.count)
            .sorted { $0.value > $1.value }

        let lead: String
        if let top = projects.first, top.share >= 0.7 {
            lead = "Most of the last stretch (\(window)) was spent in **\(top.name)** — \(sessions) agent session\(sessions == 1 ? "" : "s")."
        } else if projects.count >= 2 {
            let named = projects.prefix(3).map { "**\($0.name)** (\($0.count))" }.joined(separator: ", ")
            lead = "\(sessions) agent session\(sessions == 1 ? "" : "s") since \(window), split across \(named)."
        } else if let top = projects.first {
            lead = "\(sessions) agent session\(sessions == 1 ? "" : "s") since \(window), centered on **\(top.name)**."
        } else {
            lead = "\(sessions) agent session\(sessions == 1 ? "" : "s") since \(window), without a clear project attribution."
        }

        var extras: [String] = [lead]
        if substantive == 0 {
            extras.append(
                "The index only has empty shells so far (titles are workspace paths, 0 messages) — treat the count as activity, not a finished narrative."
            )
        } else if substantive < sessions {
            extras.append(
                "Only \(substantive) of those sessions have indexed messages; the rest are still empty shells."
            )
        }

        if providers.count > 1, let primary = providers.first {
            let others = providers.dropFirst().prefix(2).map(\.key).joined(separator: ", ")
            extras.append(
                "Harness mix: mostly \(primary.key)\(others.isEmpty ? "" : ", plus \(others)")."
            )
        }

        return extras
    }

    private static func signalSentence(pack: BurnBarAIInboxEvidencePack) -> String? {
        let substantive = pack.conversations
            .filter { $0.messageCount > 0 }
            .sorted { ($0.endedAt ?? .distantPast) > ($1.endedAt ?? .distantPast) }
        guard let headline = substantive.first else { return nil }

        let snippets = substantive.prefix(3).compactMap { conversation -> String? in
            if let fromBody = firstUsefulLine(conversation.body) {
                return fromBody
            }
            if conversation.keyFiles.isEmpty == false {
                let files = conversation.keyFiles.prefix(2)
                    .map { BurnBarAIInboxDetectors.lastPathComponent($0) }
                    .joined(separator: ", ")
                return "touched \(files)"
            }
            if conversation.keyCommands.isEmpty == false {
                return "ran `\(conversation.keyCommands[0])`"
            }
            if conversation.title.isEmpty == false,
               conversation.title.contains("/") == false,
               conversation.title != conversation.projectName {
                return conversation.title
            }
            return nil
        }

        guard snippets.isEmpty == false else {
            let messages = substantive.reduce(0) { $0 + $1.messageCount }
            let project = shortLabel(headline.projectName) ?? "the active project"
            return "Indexed transcripts cover \(messages) messages in **\(project)**."
        }

        if snippets.count == 1 {
            return "Latest signal: \(snippets[0])."
        }
        return "What the transcripts show: \(snippets[0]); also \(snippets[1])."
    }

    private static func workspaceSentence(pack: BurnBarAIInboxEvidencePack) -> String? {
        let dirty = pack.workspaces.filter(\.isDirty)
        guard dirty.isEmpty == false else { return nil }
        let names = dirty.prefix(3).map { workspace -> String in
            let label = shortLabel(workspace.path)
                ?? BurnBarAIInboxDetectors.displayPath(workspace.path)
            let files = workspace.dirtyFiles.count + workspace.untrackedCount
            return "**\(label)** (\(files) files)"
        }
        if dirty.count == 1, let only = names.first {
            return "\(only) still has uncommitted work."
        }
        let listed = names.joined(separator: ", ")
        let more = dirty.count > names.count ? " and \(dirty.count - names.count) more" : ""
        return "Uncommitted work is sitting in \(listed)\(more)."
    }

    private static func githubSentence(pack: BurnBarAIInboxEvidencePack) -> String? {
        let openPRs = pack.repositories.reduce(0) { $0 + $1.openPullRequests.count }
        let wasted = pack.repositories.reduce(0) { partial, repository in
            partial + repository.recentRuns.filter(\.isWasted).count
        }
        if openPRs == 0, wasted == 0 { return nil }
        var bits: [String] = []
        if openPRs > 0 {
            bits.append("\(openPRs) open PR\(openPRs == 1 ? "" : "s")")
        }
        if wasted > 0 {
            bits.append("\(wasted) recent wasted CI run\(wasted == 1 ? "" : "s")")
        }
        return "GitHub still shows \(bits.joined(separator: " and "))."
    }

    private static func spendSentence(pack: BurnBarAIInboxEvidencePack) -> String? {
        let total = pack.usage.reduce(0.0) { $0 + $1.costUSD }
        guard total > 0 else { return nil }
        let top = pack.usage.max(by: { $0.costUSD < $1.costUSD })
        let amount = BurnBarAIInboxDetectors.currency(total)
        if let top, top.costUSD > 0, top.costUSD / total >= 0.5 {
            let project = shortLabel(top.projectName) ?? top.projectName
            return "Spend in this window: \(amount), mostly \(top.model) on **\(project)**."
        }
        return "Spend in this window: \(amount)."
    }

    private static func firstUsefulLine(_ body: String) -> String? {
        let line = body
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { candidate in
                candidate.count >= 24
                    && candidate.hasPrefix("#") == false
                    && candidate.hasPrefix("```") == false
            }
        guard let line else { return nil }
        return BurnBarAIInboxDetectors.truncate(line, 140)
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
