import Foundation

// MARK: - Auto Summary Result

/// Internal result type carrying the output of a successful summary LLM call.
struct AutoSummaryResult {
    let title: String
    let summary: String
    let provider: SummaryProviderID
    let model: String
    let estimatedCostUSD: Double
}

// MARK: - Auto Summary Engine

/// Orchestrates automatic session summarization: sweep scheduling, concurrency
/// management, LLM provider fallback chains, and observable progress state.
///
/// Extracted from `UsageAggregator` to isolate the ~45 % of that file devoted
/// to summarization into a focused, independently testable component.
///
/// Heavy work (LLM I/O and DB writes) is delegated to `SummaryWorker` so that
/// this type can remain `@MainActor @Observable` for SwiftUI observation.
@Observable
@MainActor
final class AutoSummaryEngine {
    // MARK: - Dependencies

    private let dataStore: DataStore
    private let settingsManager: SettingsManager
    private let llmClient: SummaryLLMClient
    private let keyResolver: SummaryAPIKeyResolver
    private let worker: SummaryWorker

    /// Closure called when the engine needs the aggregator to trigger a
    /// projection sweep (avoids a circular reference back to UsageAggregator).
    var onRequestProjectionSweep: (() -> Void)?

    // MARK: - Observable State

    private(set) var isSummarizing = false
    private(set) var summaryProgressDone: Int = 0
    private(set) var summaryProgressTotal: Int = 0
    private(set) var summaryCurrentTitle: String = ""
    private(set) var summaryQueue: [SummaryQueueItem] = []
    /// Seconds remaining until the time limit, nil if no limit is set.
    private(set) var summaryTimeRemaining: TimeInterval? = nil

    // MARK: - Internal State

    private var hasCompletedInitialSummarySweep: Bool
    static let summaryFailureRetryCooldown: TimeInterval = 60 * 60

    // MARK: - Init

    init(
        dataStore: DataStore,
        settingsManager: SettingsManager,
        providerAPIKeyStore: ProviderAPIKeyStore,
        llmClient: SummaryLLMClient = SummaryLLMClient(),
        onRequestProjectionSweep: (() -> Void)? = nil
    ) {
        self.dataStore = dataStore
        self.settingsManager = settingsManager
        self.llmClient = llmClient
        self.keyResolver = SummaryAPIKeyResolver(providerAPIKeyStore: providerAPIKeyStore)
        self.worker = SummaryWorker(
            dataStoreActor: dataStore.actor,
            llmClient: llmClient,
            keyResolver: self.keyResolver
        )
        self.hasCompletedInitialSummarySweep = settingsManager.summaryInitialSweepCompleted
        self.onRequestProjectionSweep = onRequestProjectionSweep
    }

    // MARK: - Launch

    func launchAutoSummarySweep(indexedAfter: Date) {
        guard settingsManager.conversationIndexingEnabled,
              settingsManager.autoSessionSummariesEnabled else { return }

        Task(priority: .utility) { [weak self] in
            await self?.runAutoSummarySweep(indexedAfter: indexedAfter)
        }
    }

    // MARK: - Sweep

    func runAutoSummarySweep(indexedAfter: Date) async {
        guard settingsManager.conversationIndexingEnabled,
              settingsManager.autoSessionSummariesEnabled,
              !isSummarizing else { return }

        isSummarizing = true
        summaryProgressDone = 0
        summaryProgressTotal = 0
        summaryCurrentTitle = ""
        summaryQueue = []
        summaryTimeRemaining = nil
        defer {
            isSummarizing = false
            summaryCurrentTitle = ""
            summaryTimeRemaining = nil
        }

        let isInitialSweep = !hasCompletedInitialSummarySweep
        let batchLimit = effectiveAutoSummaryBatchLimit(isInitialSweep: isInitialSweep)

        // Compute optional wall-clock deadline
        let limitMinutes = settingsManager.summaryTimeLimitMinutes
        let deadline: Date? = limitMinutes > 0
            ? Date().addingTimeInterval(Double(limitMinutes) * 60)
            : nil

        // Start a 1-second ticker that publishes remaining time
        if let deadline {
            Task { @MainActor [weak self] in
                while self?.isSummarizing == true {
                    let remaining = deadline.timeIntervalSinceNow
                    self?.summaryTimeRemaining = max(remaining, 0)
                    if remaining <= 0 { break }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }

        // Get total count without loading full transcript payloads.
        summaryProgressTotal = (try? dataStore.countConversationsNeedingSummary(
            now: Date(),
            retryCooldown: Self.summaryFailureRetryCooldown,
            indexedAfter: indexedAfter
        )) ?? 0
        summaryQueue = []

        let settingsSnapshot = makeSettingsSnapshot()
        let worker = self.worker
        var failedIDs = Set<String>()
        var loopsRemaining = 1

        while loopsRemaining > 0, !Task.isCancelled {
            // Respect time limit
            if let deadline, Date() >= deadline { break }

            guard var candidates = try? dataStore.fetchConversationsNeedingSummary(
                limit: batchLimit,
                now: Date(),
                retryCooldown: Self.summaryFailureRetryCooldown,
                indexedAfter: indexedAfter
            ),
                  !candidates.isEmpty else { break }
            candidates.removeAll { failedIDs.contains($0.id) }
            if candidates.isEmpty { break }

            // Unified parallel pool -- local and cloud compete for the same slots.
            // The worker already falls through the full provider list, so
            // sessions that miss local capacity naturally spill to cloud and vice versa.
            let maxConcurrent = effectiveAutoSummaryMaxConcurrency

            await withTaskGroup(of: (String, AutoSummaryResult?).self) { group in
                var inFlight = 0

                for conversation in candidates {
                    if Task.isCancelled { break }
                    if let deadline, Date() >= deadline { break }

                    markSummaryItemProcessing(conversation)

                    if inFlight >= maxConcurrent, let (id, result) = await group.next() {
                        if result == nil { failedIDs.insert(id) }
                        recordParallelSummaryResult(id: id, result: result)
                        inFlight -= 1
                    }

                    // Check deadline again after draining
                    if let deadline, Date() >= deadline { break }

                    let conv = conversation
                    group.addTask {
                        return (conv.id, await worker.summarizeAndStore(conv, settings: settingsSnapshot))
                    }
                    inFlight += 1
                }

                for await (id, result) in group {
                    if result == nil { failedIDs.insert(id) }
                    recordParallelSummaryResult(id: id, result: result)
                }
            }

            loopsRemaining -= 1
            if candidates.count < batchLimit { break }
        }

        hasCompletedInitialSummarySweep = true
        settingsManager.summaryInitialSweepCompleted = true
        onRequestProjectionSweep?()
    }

    // MARK: - Progress Tracking

    /// Updates observable queue state when a summary task finishes.
    /// DB writes happen inside `SummaryWorker`; this method is lightweight UI-only.
    func recordParallelSummaryResult(id: String, result: AutoSummaryResult?) {
        if let result {
            if let idx = summaryQueue.firstIndex(where: { $0.id == id }) {
                summaryQueue[idx].status = .done
                summaryQueue[idx].provider = result.provider.rawValue
            }
        } else {
            if let idx = summaryQueue.firstIndex(where: { $0.id == id }) {
                summaryQueue[idx].status = .failed
            }
        }
        summaryProgressDone += 1
    }

    func markSummaryItemProcessing(_ conversation: ConversationRecord) {
        if let idx = summaryQueue.firstIndex(where: { $0.id == conversation.id }) {
            summaryQueue[idx].status = .processing
        } else {
            summaryQueue.append(
                SummaryQueueItem(
                    id: conversation.id,
                    title: conversation.inferredTaskTitle.isEmpty ? conversation.sessionId : conversation.inferredTaskTitle,
                    status: .processing,
                    provider: nil
                )
            )
        }
        summaryCurrentTitle = conversation.inferredTaskTitle.isEmpty
            ? conversation.sessionId : conversation.inferredTaskTitle
    }

    // MARK: - Settings Snapshot

    private func makeSettingsSnapshot() -> SummarySettingsSnapshot {
        SummarySettingsSnapshot(
            providerOrder: settingsManager.summaryProviderOrder,
            localBaseURL: settingsManager.summaryLocalBaseURL,
            localModel: settingsManager.summaryLocalModel,
            mlxBaseURL: settingsManager.summaryMLXBaseURL,
            mlxModel: settingsManager.summaryMLXModel,
            minimaxModel: settingsManager.summaryMiniMaxModel,
            openRouterPrimaryModel: settingsManager.summaryOpenRouterPrimaryModel,
            openRouterFallbackModel: settingsManager.summaryOpenRouterFallbackModel,
            zaiModel: settingsManager.summaryZaiModel,
            requestTimeoutSeconds: settingsManager.summaryRequestTimeoutSeconds,
            maxPromptChars: effectiveAutoSummaryPromptChars,
            maxOutputTokens: effectiveAutoSummaryOutputTokens,
            dailyCapUSD: settingsManager.summaryDailyCapUSD ?? 0,
            retryCount: settingsManager.summaryRetryCount
        )
    }

    // MARK: - Effective Settings

    private func effectiveAutoSummaryBatchLimit(isInitialSweep: Bool) -> Int {
        let configured = isInitialSweep
            ? max(settingsManager.summaryFirstLoadBatchSize, 1)
            : max(settingsManager.summaryBatchSize, 1)
        let ceiling = isInitialSweep
            ? AutoSummaryPolicy.maxFirstLoadBatchSize
            : AutoSummaryPolicy.maxBatchSize
        return min(configured, ceiling)
    }

    private var effectiveAutoSummaryMaxConcurrency: Int {
        min(max(settingsManager.summaryMaxConcurrency, 1), AutoSummaryPolicy.maxConcurrency)
    }

    private var effectiveAutoSummaryPromptChars: Int {
        min(max(settingsManager.summaryMaxPromptChars, 4_000), AutoSummaryPolicy.maxPromptChars)
    }

    private var effectiveAutoSummaryOutputTokens: Int {
        min(max(settingsManager.summaryMaxOutputTokens, 120), AutoSummaryPolicy.maxOutputTokens)
    }
}
