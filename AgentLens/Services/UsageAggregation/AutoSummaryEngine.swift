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
@Observable
@MainActor
final class AutoSummaryEngine {
    // MARK: - Dependencies

    private let dataStore: DataStore
    private let settingsManager: SettingsManager
    private let llmClient: SummaryLLMClient
    private let keyResolver: SummaryAPIKeyResolver

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
    private var localSummaryEndpointCooldownUntil: Date?
    private var mlxSummaryEndpointCooldownUntil: Date?
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
            // summarizeConversation already falls through the full provider list, so
            // sessions that miss local capacity naturally spill to cloud and vice versa.
            let maxConcurrent = effectiveAutoSummaryMaxConcurrency

            await withTaskGroup(of: (String, AutoSummaryResult?).self) { group in
                var inFlight = 0

                for conversation in candidates {
                    if Task.isCancelled { break }
                    if let deadline, Date() >= deadline { break }

                    await MainActor.run { markSummaryItemProcessing(conversation) }

                    if inFlight >= maxConcurrent, let (id, result) = await group.next() {
                        await MainActor.run {
                            recordParallelSummaryResult(id: id, result: result, failedIDs: &failedIDs)
                        }
                        inFlight -= 1
                    }

                    // Check deadline again after draining
                    if let deadline, Date() >= deadline { break }

                    let conv = conversation
                    group.addTask { [weak self] in
                        guard let self else { return (conv.id, nil) }
                        return (conv.id, await self.summarizeConversation(conv))
                    }
                    inFlight += 1
                }

                for await (id, result) in group {
                    await MainActor.run {
                        recordParallelSummaryResult(id: id, result: result, failedIDs: &failedIDs)
                    }
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

    /// Called from `withTaskGroup` via `MainActor.run` so queue / store updates stay on the main actor.
    func recordParallelSummaryResult(id: String, result: AutoSummaryResult?, failedIDs: inout Set<String>) {
        if let result {
            try? dataStore.updateConversationSummary(
                id: id, title: result.title, summary: result.summary,
                provider: result.provider.rawValue, model: result.model,
                runCostUSD: result.estimatedCostUSD
            )
            if let idx = summaryQueue.firstIndex(where: { $0.id == id }) {
                summaryQueue[idx].status = .done
                summaryQueue[idx].provider = result.provider.rawValue
            }
        } else {
            failedIDs.insert(id)
            if let idx = summaryQueue.firstIndex(where: { $0.id == id }) {
                summaryQueue[idx].status = .failed
            }
            try? dataStore.markConversationSummaryAttempt(id: id)
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

    // MARK: - Summarize Single Conversation

    func summarizeConversation(_ conversation: ConversationRecord) async -> AutoSummaryResult? {
        let prompt = ContextBuilder.summarizeSessionJSONPrompt(
            fullText: conversation.fullText,
            maxChars: effectiveAutoSummaryPromptChars
        )

        for provider in settingsManager.summaryProviderOrder {
            switch provider {
            case .local:
                if let cooldown = localSummaryEndpointCooldownUntil, cooldown > Date() {
                    continue
                }
                let (payload, shouldCooldown) = await llmClient.callOllama(
                    baseURL: settingsManager.summaryLocalBaseURL,
                    model: settingsManager.summaryLocalModel,
                    prompt: prompt,
                    timeout: settingsManager.summaryRequestTimeoutSeconds,
                    maxOutputTokens: effectiveAutoSummaryOutputTokens
                )
                if shouldCooldown {
                    localSummaryEndpointCooldownUntil = Date().addingTimeInterval(
                        SummaryEndpointCooldownPolicy.localEndpointFailureCooldown
                    )
                }
                if let payload {
                    let clean = llmClient.sanitizeSummaryPayload(payload, fallbackTitle: conversation.inferredTaskTitle)
                    if let clean {
                        return AutoSummaryResult(
                            title: clean.title,
                            summary: clean.summary,
                            provider: .local,
                            model: settingsManager.summaryLocalModel,
                            estimatedCostUSD: 0
                        )
                    }
                }

            case .mlx:
                if let cooldown = mlxSummaryEndpointCooldownUntil, cooldown > Date() {
                    continue
                }
                let base = settingsManager.summaryMLXBaseURL
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                guard !base.isEmpty, !settingsManager.summaryMLXModel.isEmpty else { continue }
                if let result = await summarizeWithOpenAICompatibleProvider(
                    provider: .mlx,
                    baseURL: base + "/v1",
                    apiKey: "",
                    model: settingsManager.summaryMLXModel,
                    prompt: prompt,
                    fallbackTitle: conversation.inferredTaskTitle
                ) {
                    return result
                }

            case .minimax:
                guard let key = keyResolver.resolveAPIKey(for: .minimax) else { continue }
                let model = settingsManager.summaryMiniMaxModel
                if let result = await summarizeWithOpenAICompatibleProvider(
                    provider: .minimax,
                    baseURL: "https://api.minimax.io/v1",
                    apiKey: key,
                    model: model,
                    prompt: prompt,
                    fallbackTitle: conversation.inferredTaskTitle
                ) {
                    return result
                }

            case .openrouter:
                guard let key = keyResolver.resolveAPIKey(for: .openrouter) else { continue }
                let models = [settingsManager.summaryOpenRouterPrimaryModel, settingsManager.summaryOpenRouterFallbackModel]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }

                for model in models {
                    if let result = await summarizeWithOpenAICompatibleProvider(
                        provider: .openrouter,
                        baseURL: "https://openrouter.ai/api/v1",
                        apiKey: key,
                        model: model,
                        prompt: prompt,
                        fallbackTitle: conversation.inferredTaskTitle,
                        openRouterHeaders: true
                    ) {
                        return result
                    }
                }

            case .zai:
                guard let key = keyResolver.resolveAPIKey(for: .zai) else { continue }
                let model = settingsManager.summaryZaiModel
                if let result = await summarizeWithOpenAICompatibleProvider(
                    provider: .zai,
                    baseURL: "https://api.z.ai/api/coding/paas/v4",
                    apiKey: key,
                    model: model,
                    prompt: prompt,
                    fallbackTitle: conversation.inferredTaskTitle
                ) {
                    return result
                }
            }
        }

        return nil
    }

    // MARK: - OpenAI-Compatible Provider Wrapper

    private func summarizeWithOpenAICompatibleProvider(
        provider: SummaryProviderID,
        baseURL: String,
        apiKey: String,
        model: String,
        prompt: String,
        fallbackTitle: String,
        openRouterHeaders: Bool = false
    ) async -> AutoSummaryResult? {
        let requestTimeout = settingsManager.summaryRequestTimeoutSeconds
        let outputTokens = effectiveAutoSummaryOutputTokens
        let estimatedInputTokens = max(prompt.count / 4, 1)
        let estimatedOutputTokens = max(outputTokens / 2, 100)
        let estimatedCost = SummaryCostEstimator.estimateCostUSD(
            provider: provider,
            model: model,
            inputTokens: estimatedInputTokens,
            outputTokens: estimatedOutputTokens
        )

        if provider != .local, provider != .mlx {
            let spentToday = (try? dataStore.summarySpendToday()) ?? 0
            if SummaryCostEstimator.exceedsCloudDailyCap(
                adding: estimatedCost,
                dailyCapUSD: settingsManager.summaryDailyCapUSD,
                spentTodayUSD: spentToday
            ) {
                return nil
            }
        }

        let retryCount = max(settingsManager.summaryRetryCount, 0)
        for _ in 0 ... retryCount {
            if Task.isCancelled { return nil }
            guard let body = await llmClient.callOpenAICompatibleCompletion(
                baseURL: baseURL,
                apiKey: apiKey,
                model: model,
                prompt: prompt,
                timeout: requestTimeout,
                maxOutputTokens: outputTokens,
                includeOpenRouterHeaders: openRouterHeaders
            ) else {
                if provider == .mlx {
                    mlxSummaryEndpointCooldownUntil = Date().addingTimeInterval(
                        SummaryEndpointCooldownPolicy.localEndpointFailureCooldown
                    )
                }
                continue
            }

            guard let payload = llmClient.parseSummaryPayload(from: body) else { continue }
            let clean = llmClient.sanitizeSummaryPayload(payload, fallbackTitle: fallbackTitle)
            guard let clean else { continue }

            let outputEstimate = max((clean.title.count + clean.summary.count) / 4, 60)
            let finalCost = SummaryCostEstimator.estimateCostUSD(
                provider: provider,
                model: model,
                inputTokens: estimatedInputTokens,
                outputTokens: outputEstimate
            )

            return AutoSummaryResult(
                title: clean.title,
                summary: clean.summary,
                provider: provider,
                model: model,
                estimatedCostUSD: max(finalCost, 0)
            )
        }
        return nil
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
