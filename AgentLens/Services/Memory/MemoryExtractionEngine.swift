import Foundation
import OpenBurnBarCore

// MARK: - Memory Extraction Engine
//
// A `@MainActor @Observable` scheduler that drives `MemoryExtractionWorker.drainNext()`,
// mirroring `AutoSummaryEngine` (the established summary-feature pattern). It owns the
// drain loop, the live kill-switch atomic, the per-pump safety rails, and the observable
// progress state SwiftUI binds to. ALL heavy work (LLM I/O, the G7 gate, DB writes) lives
// in the worker + `ChatTranscriptExtractor`; this type stays MainActor-isolated so it can
// be observed and so the kill switch is updated synchronously from the UI.
//
// Durable writes are gated by fail-closed consent/fleet levers plus the authority-write
// default. The user
// CONSENT lever (G0) folds into `memoryExtractionEnabled` alongside the user toggle and the
// fleet kill switch; the worker's authority closure then ANDs that combined gate with the
// authority-write default. NO durable `agent_memories` row is written until BOTH allow:
//   1. `settingsManager.memoryExtractionEnabled` — the combined G0+G4 gate (user CONSENT
//      AND user toggle AND Firebase Remote Config fleet kill switch; DEFAULTS FALSE because
//      consent (G0) is off until the user opts in). The engine mirrors this into a
//      `Sendable` atomic (`MemoryExtractionKillSwitch`) the worker reads off-main. This is
//      the instant fleet kill; it gates whether the LLM round-trip runs at all.
//   2. `ControlPlaneStore.chatMemoryAuthorityWritesEnabledByDefault` (static, DEFAULTS
//      TRUE) — the production authority-write default. Threaded through `init` and AND-ed
//      into the worker's authority closure (PR-D FIX #1). Tests can still inject `false`
//      to prove an explicit authority-off lever claims nothing and spends nothing.
// This engine flips nothing dynamically; it only reflects whatever those levers currently say.
//
// WHY THE AND IS REQUIRED: even once a user grants consent + enables the toggle (so
// `memoryExtractionEnabled` becomes true to observe the loop), durable writes still route
// through the separate authority lever. Wiring the worker gate to `{ killSwitch.isAllowed() }`
// alone would make that lever untestable and remove the explicit safety override.
//
// PR-D2 must-fixes folded in:
//   #1 The pump loops on the worker's tri-state `DrainOutcome`, NOT a `Bool`, so one
//      failing job (which the worker marks failed WITHOUT re-throwing) does not halt the
//      backlog behind it.
//   #2 The kill switch is a `Sendable` `NSLock`-guarded atomic the MainActor updates and
//      the worker reads — never a synchronous off-main read of the `@MainActor` gate
//      (which would not compile), and never cached.
//   #3 `failedThisSession`/`lastError` are reachable: errors do NOT propagate through the
//      drain (the worker swallows them), so the engine reads `memoryExtractionJobStatus`
//      after each tick to learn a job failed.
//   #4 The kill switch is re-established at the WORKER boundary (the engine path bypasses
//      the controller's `memoryServiceForExtraction == nil` gate).
//   #6 Per-pump `maxJobsPerPump` ceiling AND a wall-clock deadline bound a large backlog
//      so one foreground drain cannot fire an unbounded serial chain of (paid) calls.
//   #7 Provider order is forced local-only as a HARD default; transcript cloud egress
//      needs a separate explicit consent gate.

/// Snapshot of the outcome of one pump, surfaced for observation/tests.
struct MemoryExtractionPumpReport: Equatable, Sendable {
    var processed: Int = 0
    var failed: Int = 0
    /// Total candidates silently dropped by the G7 gate across all jobs in this pump.
    /// A candidate is dropped when `MemorySecretPIIGate.evaluate` returns `.reject` or
    /// `.redact`; a `memory.candidate_dropped` audit event is emitted for each.
    var dropped: Int = 0
    var stoppedReason: StopReason = .idle

    enum StopReason: Equatable, Sendable {
        /// No more claimable jobs (the normal completion).
        case idle
        /// Hit the per-pump job ceiling; remainder deferred to the next drain.
        case reachedJobCeiling
        /// Hit the per-pump wall-clock deadline; remainder deferred.
        case reachedDeadline
        /// The kill switch was off when the pump started (or flipped off mid-loop).
        case killSwitchOff
        /// The task was cancelled (app teardown).
        case cancelled
        /// A transient infrastructure fault aborted this pump before backlog exhaustion.
        case transientFailure
    }
}

@Observable
@MainActor
final class MemoryExtractionEngine {
    // MARK: - Dependencies

    private let chatMemoryStore: ControlPlaneStore
    private let settingsManager: SettingsManager

    /// The single live source of truth for the combined extraction gate. The MainActor
    /// writes it (`refreshKillSwitch()` / construction); the worker reads it off-main.
    private let killSwitch: MemoryExtractionKillSwitch

    /// PR6: the USAGE lane's extraction gate box (usage consent AND the usage
    /// fleet switch), registered on `UsageMemoryKillSwitchRegistry`'s extraction
    /// lane so `MemorySettings.propagateUsageGates()` pushes every change in.
    /// Exposed (read-only via `isAllowed()`) because the session miner and the
    /// Stage-1 cadence share this exact box as their dormancy gate.
    let usageExtractionKillSwitch: MemoryExtractionKillSwitch

    /// PR6: the USAGE authority-writes fleet switch box, registered on the
    /// registry's authorityWrites lane. ANDed with the extraction box and the
    /// production write default inside the worker's usage authority closure.
    private let usageAuthorityWritesKillSwitch: MemoryExtractionKillSwitch

    /// The live settings snapshot the extractor reads off-main. The MainActor refreshes
    /// it before each drain; the extractor's `@Sendable` provider pulls from it. This is
    /// what lets per-drain settings stay fresh WITHOUT reading the `@MainActor`
    /// `SettingsManager` across an isolation boundary (which would crash).
    private let settingsBox: MemoryExtractionSettingsBox

    /// PR6: the live router snapshot the usage batch extractor reads off-main.
    /// Rebuilt on the MainActor alongside `settingsBox` on every refresh.
    private let usageRouterSnapshotBox: UsageMemoryRouterSnapshotBox

    /// PR6: client-side daily USD belt for the usage cloud lane; feeds the
    /// router snapshot's `cloudBudgetOK`.
    private let usageBudgetLedger: UsageMemoryBudgetLedger

    /// PR9: the Stage-2 embedding service, retained so the consolidation
    /// worker shares the SAME instance (one cached registration) as the
    /// extraction worker's Stage-2 funnel.
    let usageStage2Service: UsageMemoryEmbeddingService?

    /// PR9: the bounded promote/self-heal model client for the consolidation
    /// worker — the SAME LLM/cloud/telemetry/ledger seams as the Stage-1
    /// batch extractor, text lane only.
    let usageConsolidationModelClient: UsageMemoryConsolidationLLMClient

    /// PR9: off-main reader over the SAME router snapshot box the Stage-1
    /// extractor routes on.
    let usageConsolidationRouterSnapshotProvider: @Sendable () -> UsageMemoryModelRouter.Snapshot

    /// PR6/PR9: the usage lane's combined authority-writes gate (extraction
    /// box AND authority box AND the production write default). The extraction
    /// worker's usage closure and the consolidation worker's canonical-note
    /// insert read the SAME composition.
    let usageAuthorityWritesGate: @Sendable () -> Bool

    /// The worker that actually claims + processes jobs. Constructed once with the
    /// extractor closure and the kill-switch-backed authority gate.
    private let worker: MemoryExtractionWorker

    // MARK: - Observable State

    private(set) var isExtracting = false
    private(set) var extractedThisSession: Int = 0
    /// Reachable because the engine reads job status after each tick (must-fix #3).
    private(set) var failedThisSession: Int = 0
    private(set) var lastError: String?
    private(set) var lastPumpReport: MemoryExtractionPumpReport?

    // MARK: - Init

    /// - Parameters:
    ///   - chatMemoryStore: the SHARED `ControlPlaneStore` (PR-D3 passes the SAME instance
    ///     used by `OpenBurnBarMemoryService`, so extraction reads the transcript from and
    ///     writes memories to the one store — the basis for the worker being the sole
    ///     provenance authority without a second store).
    ///   - dataStore: reserved spend source for a future explicit cloud-egress gate.
    ///   - authorityWritesGoLiveEnabled: the second authority lever. Defaults to the
    ///     static `chatMemoryAuthorityWritesEnabledByDefault`; production writes are now
    ///     allowed whenever the consent/toggle/Remote Config gate is open. It remains
    ///     injectable so the gate matrix (extraction on + authority off => zero writes) is
    ///     representable and testable.
    init(
        chatMemoryStore: ControlPlaneStore,
        dataStore: DataStore,
        settingsManager: SettingsManager,
        providerAPIKeyStore: ProviderAPIKeyStore = .shared,
        llmClient: MemoryExtractionLLMClient = MemoryExtractionLLMClient(),
        authorityWritesGoLiveEnabled: Bool = ControlPlaneStore.chatMemoryAuthorityWritesEnabledByDefault,
        usageCloudClient: any UsageCurationCloudClientProtocol = UsageCurationCloudClient(),
        usageTelemetry: UsageCurationTelemetry = UsageCurationTelemetry(),
        usageBudgetLedger: UsageMemoryBudgetLedger = UsageMemoryBudgetLedger(),
        usageExtractionPolicy: UsageMemoryExtractionPolicy = .default,
        // PR7: the Stage-2 semantic write funnel for the usage lane. The
        // production default embeds with Apple NLEmbedding under the pinned
        // usage descriptor; a nil provider (NLEmbedding unavailable) degrades
        // to salience-seeding-only, and explicit nil restores the exact PR6
        // write path. Tests inject a deterministic provider through here.
        usageStage2: UsageMemoryEmbeddingService? = UsageMemoryEmbeddingService(
            provider: NLUsageMemoryEmbeddingProvider(),
            policy: .defaults
        )
    ) {
        self.chatMemoryStore = chatMemoryStore
        self.settingsManager = settingsManager

        // Seed the atomic from the live gate on the MainActor. Starts CLOSED and only
        // opens if the combined gate currently allows — fail-safe on construction.
        let killSwitch = MemoryExtractionKillSwitch(
            initiallyAllowed: settingsManager.memoryExtractionEnabled
        )
        MemoryExtractionKillSwitchRegistry.register(
            killSwitch,
            initiallyAllowed: settingsManager.memoryExtractionEnabled
        )
        self.killSwitch = killSwitch

        // PR6: the usage lane's two gate boxes, seeded from the live gates and
        // registered on the U1 registry lanes so `propagateUsageGates()` keeps
        // them current. Both start from the current (default-dormant) values.
        let usageExtractionKillSwitch = MemoryExtractionKillSwitch(
            initiallyAllowed: settingsManager.usageMemoryExtractionEnabled
        )
        UsageMemoryKillSwitchRegistry.registerExtraction(
            usageExtractionKillSwitch,
            initiallyAllowed: settingsManager.usageMemoryExtractionEnabled
        )
        self.usageExtractionKillSwitch = usageExtractionKillSwitch
        let usageAuthorityWritesKillSwitch = MemoryExtractionKillSwitch(
            initiallyAllowed: settingsManager.usageMemoryAuthorityWritesRemoteConfigEnabled
        )
        UsageMemoryKillSwitchRegistry.registerAuthorityWrites(
            usageAuthorityWritesKillSwitch,
            initiallyAllowed: settingsManager.usageMemoryAuthorityWritesRemoteConfigEnabled
        )
        self.usageAuthorityWritesKillSwitch = usageAuthorityWritesKillSwitch
        self.usageBudgetLedger = usageBudgetLedger

        // Seed the settings box on the MainActor (legal here). The off-main extractor
        // provider reads THIS box, never the `@MainActor` SettingsManager directly.
        let settingsBox = MemoryExtractionSettingsBox(
            Self.makeSettingsSnapshot(settingsManager: settingsManager)
        )
        self.settingsBox = settingsBox

        // PR6: seed the router snapshot box the usage extractor reads off-main.
        let usageRouterSnapshotBox = UsageMemoryRouterSnapshotBox(
            Self.makeUsageRouterSnapshot(settingsManager: settingsManager, ledger: usageBudgetLedger)
        )
        self.usageRouterSnapshotBox = usageRouterSnapshotBox
        self.usageConsolidationRouterSnapshotProvider = { usageRouterSnapshotBox.current() }

        // PR9: retain the Stage-2 embedding service and compose the usage
        // authority gate ONCE, shared by the extraction worker's usage closure
        // and the consolidation worker's canonical-note insert.
        self.usageStage2Service = usageStage2
        let usageAuthorityGate: @Sendable () -> Bool = {
            usageExtractionKillSwitch.isAllowed()
                && usageAuthorityWritesKillSwitch.isAllowed()
                && authorityWritesGoLiveEnabled
        }
        self.usageAuthorityWritesGate = usageAuthorityGate

        // Build the extractor closure (run off-main per drain). The spend source is
        // injected for the future cloud-egress path; local-only v1 never reads it.
        let resolver = MemoryExtractionAPIKeyResolver(providerAPIKeyStore: providerAPIKeyStore)
        let extractor = ChatTranscriptExtractor(
            transcriptReader: chatMemoryStore,
            spendReader: DataStoreSummaryPersistenceStore(dataStore: dataStore),
            llmClient: llmClient,
            keyResolver: resolver,
            settingsProvider: { settingsBox.current() }
        )

        // PR9: the consolidation worker's bounded promote/self-heal client,
        // over the SAME transport seams and settings box as the extractor.
        self.usageConsolidationModelClient = UsageMemoryConsolidationLLMClient(
            llmClient: llmClient,
            cloudClient: usageCloudClient,
            telemetry: usageTelemetry,
            budgetLedger: usageBudgetLedger,
            policy: usageExtractionPolicy,
            settingsProvider: { settingsBox.current() }
        )

        // PR6: the usage batch extractor over the SAME store, sharing the chat
        // lane's LLM client and settings box (its `.local` endpoint config).
        let usageExtractor = UsageMemoryBatchExtractor(
            candidateReader: chatMemoryStore,
            llmClient: llmClient,
            cloudClient: usageCloudClient,
            telemetry: usageTelemetry,
            budgetLedger: usageBudgetLedger,
            policy: usageExtractionPolicy,
            settingsProvider: { settingsBox.current() },
            routerSnapshotProvider: { usageRouterSnapshotBox.current() }
        )

        // The single worker extractor seam ROUTES on the job's source kind:
        // chat jobs take the existing transcript path byte-identically; usage
        // batch jobs take the Stage-1 batch extractor. The worker's discipline
        // (admission, lease, G7, provenance recompute, idempotent ids) is
        // shared — that is the whole point of not forking the worker.
        let chatExtractorClosure = extractor.makeExtractor()
        let usageExtractorClosure = usageExtractor.makeExtractor()

        self.worker = MemoryExtractionWorker(
            store: chatMemoryStore,
            // Re-establish the kill switch at the WORKER boundary (PR-D2 must-fix #4): the
            // worker reads the LIVE atomic, never a cached or main-isolated value. AND it
            // with the authority-write lever (PR-D FIX #1) so durable writes require BOTH
            // the extraction gate (consent+toggle+RC; default-false until the user opts in)
            // AND the production write default / explicit test override.
            // `authorityWritesGoLiveEnabled` is captured by value: it is a static runtime
            // default or test override, not a per-tick toggle, so it does not need the
            // live-atomic treatment the fleet kill needs.
            authorityWritesEnabled: { killSwitch.isAllowed() && authorityWritesGoLiveEnabled },
            // PR6: the USAGE lane's gate — the same shape as chat's (live
            // extraction atomic AND live authority atomic AND the write
            // default), built from the usage boxes. Fail-closed by default:
            // usage consent is OFF out of the box, so this evaluates false and
            // the worker never claims a usage batch. PR9: the SAME composed
            // gate (`usageAuthorityWritesGate`) guards consolidation's
            // canonical-note inserts.
            usageAuthorityWritesEnabled: usageAuthorityGate,
            // PR7: Stage-2 semantic dedup/corroboration on the usage write
            // path. Registration happens lazily on the first usage drain.
            usageStage2: usageStage2,
            extractor: { job in
                if MemorySourceKind.usageKinds.contains(job.sourceKind) {
                    return try await usageExtractorClosure(job)
                }
                return try await chatExtractorClosure(job)
            }
        )
        // If consent, the user toggle, or Remote Config opens the combined gate after app
        // startup, immediately kick any persisted backlog instead of waiting for a future
        // terminal chat commit.
        MemoryExtractionKillSwitchRegistry.registerDrainLauncher(self)
    }

    // MARK: - Kill switch + settings propagation

    /// Push the current combined gates AND the latest settings snapshot into the
    /// worker-visible boxes. Call this on the MainActor whenever the user toggle, the
    /// Remote Config fleet switch, or any extraction setting changes, so the next drain
    /// tick sees the new values (nothing is cached — must-fix #2). PR6 refreshes the
    /// usage lane's boxes and the router snapshot on the same cadence.
    func refreshKillSwitch() {
        killSwitch.set(settingsManager.memoryExtractionEnabled)
        usageExtractionKillSwitch.set(settingsManager.usageMemoryExtractionEnabled)
        usageAuthorityWritesKillSwitch.set(settingsManager.usageMemoryAuthorityWritesRemoteConfigEnabled)
        settingsBox.set(Self.makeSettingsSnapshot(settingsManager: settingsManager))
        usageRouterSnapshotBox.set(
            Self.makeUsageRouterSnapshot(settingsManager: settingsManager, ledger: usageBudgetLedger)
        )
    }

    /// PR6: whether ANY lane may pump. Chat keeps its combined gate; the usage
    /// lane's extraction gate joins with OR so a chat-off/usage-on member still
    /// drains usage batches. The worker's per-lane pre-claim gates remain the
    /// deeper backstop — an open pump with both lanes closed claims nothing.
    private var anyExtractionLaneEnabled: Bool {
        settingsManager.memoryExtractionEnabled || settingsManager.usageMemoryExtractionEnabled
    }

    // MARK: - Launch

    /// Fire-and-forget entry point used after a chat commit / on foreground. Mirrors
    /// `AutoSummaryEngine.launchAutoSummarySweep`. No-op when the gate is off.
    func launchDrain() {
        refreshKillSwitch()
        let gateEnabled = anyExtractionLaneEnabled
        if !gateEnabled || isExtracting {
            AppLogger.dataStore.notice(
                "memory_extraction_launch_skipped",
                metadata: diagnosticGateMetadata(gateEnabled: gateEnabled)
                    .merging(["isExtracting": String(isExtracting)], uniquingKeysWith: { current, _ in current })
            )
            return
        }
        AppLogger.dataStore.notice(
            "memory_extraction_launch_started",
            metadata: diagnosticGateMetadata(gateEnabled: gateEnabled)
        )
        Task(priority: .utility) { [weak self] in
            await self?.runDrain()
        }
    }

    // MARK: - Reinforce-on-use (PR8)

    /// Fire-and-forget salience reinforcement for the memory ids that were
    /// actually injected into a committed turn's prompt (the terminal-commit
    /// hook calls this next to `launchDrain()`). Zero LLM, zero blocking: one
    /// small `memory_salience` write on a utility task, failures logged and
    /// swallowed. Not gated — recall itself already ran behind the combined
    /// kill switch, so a non-empty id list is proof the feature was on when
    /// the memories were used; recording that use is pure local bookkeeping.
    func reinforceRecalledMemories(ids: [MemoryID], now: Date = Date()) {
        guard ids.isEmpty == false else { return }
        let store = chatMemoryStore
        Task(priority: .utility) {
            do {
                try await store.reinforceMemories(ids: ids, now: now)
            } catch {
                AppLogger.dataStore.silentFailure("memory_reinforce_on_use_failed", error: error)
            }
        }
    }

    // MARK: - Pump

    /// Drain the extraction backlog, bounded by `maxJobsPerPump` AND a wall-clock
    /// deadline (must-fix #6). Loops on the worker's tri-state `DrainOutcome` (must-fix
    /// #1) so a failing job does not stop draining the good jobs behind it. Idempotent
    /// against concurrent invocation via `isExtracting`.
    @discardableResult
    func runDrain() async -> MemoryExtractionPumpReport {
        // Re-read the gates at entry on the MainActor (must-fix #2): if every lane is
        // off, do not even construct a pump. The worker's per-lane pre-claim guards are
        // the deeper backstop.
        refreshKillSwitch()
        guard anyExtractionLaneEnabled else {
            let report = MemoryExtractionPumpReport(stoppedReason: .killSwitchOff)
            lastPumpReport = report
            AppLogger.dataStore.notice(
                "memory_extraction_pump_skipped",
                metadata: diagnosticGateMetadata(gateEnabled: false)
            )
            return report
        }
        guard !isExtracting else {
            return lastPumpReport ?? MemoryExtractionPumpReport(stoppedReason: .idle)
        }

        isExtracting = true
        extractedThisSession = 0
        failedThisSession = 0
        lastError = nil
        defer { isExtracting = false }

        let deadline = Date().addingTimeInterval(MemoryExtractionPolicy.maxPumpDuration)
        let worker = self.worker
        var report = MemoryExtractionPumpReport()

        for _ in 0 ..< MemoryExtractionPolicy.maxJobsPerPump {
            if Task.isCancelled {
                report.stoppedReason = .cancelled
                break
            }
            if Date() >= deadline {
                report.stoppedReason = .reachedDeadline
                break
            }
            // Re-check the live gates every tick so a mid-drain fleet kill halts promptly.
            refreshKillSwitch()
            guard anyExtractionLaneEnabled else {
                report.stoppedReason = .killSwitchOff
                break
            }

            let outcome: MemoryExtractionWorker.DrainOutcome
            do {
                outcome = try await worker.drainNext()
            } catch {
                // Only a genuine transient infra fault (e.g. a DB read fault surfaced by
                // the extractor) propagates here; the worker swallows extraction errors.
                // Record it and stop this pump — the job stays claimable for the next one.
                recordTransientFailure(error)
                report.failed += 1
                report.stoppedReason = .transientFailure
                break
            }

            switch outcome {
            case .drained:
                report.processed += 1
                report.dropped += await worker.lastDroppedCount
                extractedThisSession += 1
            case .claimedButFailed:
                // The worker marked the job failed (no throw). Surface it by reading the
                // terminal status (must-fix #3) and KEEP DRAINING the rest of the backlog.
                report.processed += 1
                report.failed += 1
                report.dropped += await worker.lastDroppedCount
                failedThisSession += 1
                await recordMostRecentFailure()
            case .idle:
                // Kill switch off pre-claim, admission busy, or nothing claimable.
                report.stoppedReason = .idle
                lastPumpReport = report
                AppLogger.dataStore.notice(
                    "memory_extraction_pump_finished",
                    metadata: diagnosticReportMetadata(report)
                )
                return report
            }
        }

        // Fell out of the loop via the job ceiling (rather than an explicit reason).
        if report.stoppedReason == .idle, report.processed >= MemoryExtractionPolicy.maxJobsPerPump {
            report.stoppedReason = .reachedJobCeiling
        }
        lastPumpReport = report
        AppLogger.dataStore.notice(
            "memory_extraction_pump_finished",
            metadata: diagnosticReportMetadata(report)
        )
        scheduleContinuationIfNeeded(after: report)
        return report
    }

    // MARK: - Failure surfacing (errors do NOT propagate through drainNext — must-fix #3)

    private func scheduleContinuationIfNeeded(after report: MemoryExtractionPumpReport) {
        switch report.stoppedReason {
        case .reachedJobCeiling, .reachedDeadline:
            break
        case .idle, .killSwitchOff, .cancelled, .transientFailure:
            return
        }
        refreshKillSwitch()
        guard anyExtractionLaneEnabled else { return }
        AppLogger.dataStore.notice(
            "memory_extraction_continuation_scheduled",
            metadata: diagnosticReportMetadata(report)
        )
        Task(priority: .utility) { [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(MemoryExtractionPolicy.continuationDelay * 1_000_000_000)
                )
            } catch {
                return
            }
            self?.launchDrain()
        }
    }

    /// Read the most recently failed job's status to populate `lastError`. Best-effort:
    /// a failed status read must not itself crash the pump.
    private func recordMostRecentFailure() async {
        guard let failed = try? await chatMemoryStore.mostRecentFailedMemoryExtractionJob() else { // try?-ok(best-effort failure status read)
            lastError = "memory_extraction_job_failed"
            return
        }
        lastError = failed.lastError ?? "memory_extraction_job_failed"
    }

    private func recordTransientFailure(_ error: Error) {
        lastError = String(reflecting: type(of: error))
        AppLogger.dataStore.silentFailure(
            "memory_extraction_pump_transient_failure",
            error: error,
            context: [:]
        )
    }

    private func diagnosticGateMetadata(gateEnabled: Bool) -> [String: String] {
        [
            "gateEnabled": String(gateEnabled),
            "consentGranted": String(settingsManager.memoryConsentGranted),
            "automaticExtraction": String(settingsManager.memoryAutomaticExtraction),
            "remoteConfigEnabled": String(settingsManager.memoryExtractionRemoteConfigEnabled)
        ]
    }

    private func diagnosticReportMetadata(_ report: MemoryExtractionPumpReport) -> [String: String] {
        [
            "processed": String(report.processed),
            "failed": String(report.failed),
            "dropped": String(report.dropped),
            "stoppedReason": String(describing: report.stoppedReason)
        ]
    }

    // MARK: - Settings snapshot (local-only HARD default — must-fix #7)

    /// Build an immutable `Sendable` snapshot of every setting the extractor needs, read
    /// on the MainActor (where `SettingsManager` access is legal). The engine pushes the
    /// result into `settingsBox` before each drain; the extractor's `@Sendable` provider
    /// reads the box off-main.
    ///
    /// LOCAL-ONLY IS A HARD DEFAULT, not the user's configurable summary order: the input
    /// transcript is sent to the provider before any scan, and the consent copy promises
    /// local processing. Cloud fallback needs a separate explicit transcript-egress gate.
    private static func makeSettingsSnapshot(
        settingsManager: SettingsManager
    ) -> MemoryExtractionSettingsSnapshot {
        MemoryExtractionSettingsSnapshot(
            providerOrder: localFirstProviderOrder(settingsManager.summaryProviderOrder),
            localBaseURL: settingsManager.summaryLocalBaseURL,
            localModel: settingsManager.summaryLocalModel,
            mlxBaseURL: settingsManager.summaryMLXBaseURL,
            mlxModel: settingsManager.summaryMLXModel,
            minimaxModel: settingsManager.summaryMiniMaxModel,
            openRouterPrimaryModel: settingsManager.summaryOpenRouterPrimaryModel,
            openRouterFallbackModel: settingsManager.summaryOpenRouterFallbackModel,
            zaiModel: settingsManager.summaryZaiModel,
            ollamaBaseURL: settingsManager.summaryOllamaBaseURL,
            ollamaModel: settingsManager.summaryOllamaModel,
            requestTimeoutSeconds: effectiveRequestTimeout(settingsManager),
            maxPromptChars: MemoryExtractionPolicy.clampedPromptChars(settingsManager.summaryMaxPromptChars),
            maxOutputTokens: MemoryExtractionPolicy.clampedOutputTokens(settingsManager.summaryMaxOutputTokens),
            // Reserved for a future explicit cloud-egress gate.
            dailyCapUSD: effectiveDailyCapUSD(settingsManager),
            retryCount: max(settingsManager.summaryRetryCount, 0),
            maxCandidatesPerJob: MemoryExtractionPolicy.maxCandidatesPerJob,
            promptVersion: ChatSessionController.memoryPromptVersion
        )
    }

    /// PR6: build the usage-memory router snapshot on the MainActor (settings
    /// reads are legal here); the off-main usage extractor pulls it from the
    /// Sendable box. Every field degrades toward `.queueOnly`:
    ///   * gates come from the pure U1 gate lattice on `SettingsManager`;
    ///   * local text availability = the same loopback-sanitized `.local`
    ///     endpoint the chat extractor uses, with a non-empty model;
    ///   * no local VL model setting exists yet, so `localVLModelAvailable` is
    ///     false (images arrive with PR5's Safari payloads);
    ///   * `cloudBudgetOK` is the client-side daily USD belt (U5 ledger);
    ///   * server exhaustion flags stay false — a live `resource-exhausted`
    ///     answer defers the JOB itself (+6h via the worker), which is the
    ///     stronger backpressure until a persisted allowance cache exists.
    static func makeUsageRouterSnapshot(
        settingsManager: SettingsManager,
        ledger: UsageMemoryBudgetLedger
    ) -> UsageMemoryModelRouter.Snapshot {
        UsageMemoryModelRouter.Snapshot(
            placement: settingsManager.usageMemoryModelPlacement,
            extractionEnabled: settingsManager.usageMemoryExtractionEnabled,
            cloudCurationEnabled: settingsManager.usageMemoryCloudCurationEnabled,
            localTextModelAvailable:
                LocalLLMEndpointPolicy.sanitizedLoopbackBaseURL(settingsManager.summaryLocalBaseURL) != nil
                && settingsManager.summaryLocalModel.isEmpty == false,
            localVLModelAvailable: false,
            cloudBudgetOK: ledger.cloudBudgetOK(),
            serverTextExhausted: false,
            serverMultimodalExhausted: false
        )
    }

    /// Restrict memory extraction to on-device providers (`.local`, `.mlx`, `.ollama`),
    /// preserving their configured relative order and dropping cloud providers entirely.
    static func localFirstProviderOrder(_ configured: [SummaryProviderID]) -> [SummaryProviderID] {
        let onDevice: Set<SummaryProviderID> = [.local, .mlx, .ollama]
        let source = configured.isEmpty ? SummaryProviderID.allCases : configured
        var seen = Set<SummaryProviderID>()
        let deduped = source.filter { seen.insert($0).inserted }
        let local = deduped.filter { onDevice.contains($0) }
        // Guarantee at least one on-device provider leads even if the user removed them.
        var result = local.isEmpty ? [.local] : local
        // Re-dedupe in case `.local` was injected above.
        seen.removeAll()
        result = result.filter { seen.insert($0).inserted }
        return result
    }

    private static func effectiveDailyCapUSD(_ settingsManager: SettingsManager) -> Double {
        guard let summaryCap = settingsManager.summaryDailyCapUSD else {
            return MemoryExtractionPolicy.defaultDailyCapUSD
        }
        // A summary cap of exactly 0 is an explicit "no cloud spend" — respect it.
        guard summaryCap > 0 else { return 0 }
        // Otherwise memory gets its own, smaller ceiling (never larger than summary's).
        return min(summaryCap, MemoryExtractionPolicy.defaultDailyCapUSD)
    }

    private static func effectiveRequestTimeout(_ settingsManager: SettingsManager) -> Double {
        let configured = settingsManager.summaryRequestTimeoutSeconds
        return configured > 0 ? configured : MemoryExtractionPolicy.defaultRequestTimeoutSeconds
    }
}
