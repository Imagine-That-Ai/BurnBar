import Foundation

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

    /// The live settings snapshot the extractor reads off-main. The MainActor refreshes
    /// it before each drain; the extractor's `@Sendable` provider pulls from it. This is
    /// what lets per-drain settings stay fresh WITHOUT reading the `@MainActor`
    /// `SettingsManager` across an isolation boundary (which would crash).
    private let settingsBox: MemoryExtractionSettingsBox

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
        authorityWritesGoLiveEnabled: Bool = ControlPlaneStore.chatMemoryAuthorityWritesEnabledByDefault
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

        // Seed the settings box on the MainActor (legal here). The off-main extractor
        // provider reads THIS box, never the `@MainActor` SettingsManager directly.
        let settingsBox = MemoryExtractionSettingsBox(
            Self.makeSettingsSnapshot(settingsManager: settingsManager)
        )
        self.settingsBox = settingsBox

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
            extractor: extractor.makeExtractor()
        )
        // If consent, the user toggle, or Remote Config opens the combined gate after app
        // startup, immediately kick any persisted backlog instead of waiting for a future
        // terminal chat commit.
        MemoryExtractionKillSwitchRegistry.registerDrainLauncher(self)
    }

    // MARK: - Kill switch + settings propagation

    /// Push the current combined gate AND the latest settings snapshot into the
    /// worker-visible boxes. Call this on the MainActor whenever the user toggle, the
    /// Remote Config fleet switch, or any extraction setting changes, so the next drain
    /// tick sees the new values (nothing is cached — must-fix #2).
    func refreshKillSwitch() {
        killSwitch.set(settingsManager.memoryExtractionEnabled)
        settingsBox.set(Self.makeSettingsSnapshot(settingsManager: settingsManager))
    }

    // MARK: - Launch

    /// Fire-and-forget entry point used after a chat commit / on foreground. Mirrors
    /// `AutoSummaryEngine.launchAutoSummarySweep`. No-op when the gate is off.
    func launchDrain() {
        refreshKillSwitch()
        let gateEnabled = settingsManager.memoryExtractionEnabled
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

    // MARK: - Pump

    /// Drain the extraction backlog, bounded by `maxJobsPerPump` AND a wall-clock
    /// deadline (must-fix #6). Loops on the worker's tri-state `DrainOutcome` (must-fix
    /// #1) so a failing job does not stop draining the good jobs behind it. Idempotent
    /// against concurrent invocation via `isExtracting`.
    @discardableResult
    func runDrain() async -> MemoryExtractionPumpReport {
        // Re-read the gate at entry on the MainActor (must-fix #2): if it is off, do not
        // even construct a pump. The worker's pre-claim guard is the deeper backstop.
        refreshKillSwitch()
        guard settingsManager.memoryExtractionEnabled else {
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

        // Harvest the agent corpus before draining: quiet indexed conversations
        // become extraction jobs here. The enqueue is idempotency-keyed on the
        // conversation's content state, so an unchanged session never re-runs
        // and a grown one re-extracts exactly once — the jobs table is its own
        // watermark. A harvest fault is non-fatal: the chat backlog still drains
        // and the next pump retries the sweep.
        do {
            _ = try await chatMemoryStore.harvestAgentConversationExtractions(now: Date())
        } catch {
            AppLogger.dataStore.silentFailure(
                "memory_extraction_conversation_harvest_failed",
                error: error,
                context: [:]
            )
        }

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
            // Re-check the live gate every tick so a mid-drain fleet kill halts promptly.
            refreshKillSwitch()
            guard settingsManager.memoryExtractionEnabled else {
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
        guard settingsManager.memoryExtractionEnabled else { return }
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
