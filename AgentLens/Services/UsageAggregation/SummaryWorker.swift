import Foundation

// MARK: - Summary Settings Snapshot

/// A snapshot of all settings needed by `SummaryWorker` so the worker
/// can run off the main actor without holding a `@MainActor` reference.
struct SummarySettingsSnapshot: Sendable {
    let providerOrder: [SummaryProviderID]
    let localBaseURL: String
    let localModel: String
    let mlxBaseURL: String
    let mlxModel: String
    let minimaxModel: String
    let openRouterPrimaryModel: String
    let openRouterFallbackModel: String
    let zaiModel: String
    let ollamaBaseURL: String
    let ollamaModel: String
    let requestTimeoutSeconds: Double
    let maxPromptChars: Int
    let maxOutputTokens: Int
    let dailyCapUSD: Double
    let retryCount: Int
}

// MARK: - Daily Spend Read Seam

/// Narrow seam for reading today's accumulated cloud summary spend.
///
/// The read drives the cloud daily cost cap (`SummaryCostEstimator.exceedsCloudDailyCap`),
/// so a *failed* read must fail closed — never default to `0` and silently let a paid
/// cloud LLM call bypass the cap. This protocol lets tests inject a fault-injecting fake
/// through `SummaryWorker.init` without standing up a real database.
///
/// `DataStoreActor` vends the same read behind its database actor, so production
/// and tests share the same fail-closed behavior without defaulting faults to zero.
protocol SummaryDailySpendReading: Sendable {
    /// Returns USD spent on cloud summaries today, or throws on a real read fault.
    func summarySpendToday(now: Date) async throws -> Double
}

/// Narrow persistence seam for summary writes.
///
/// `SummaryWorker` runs off the main actor and should not know about the full
/// `DataStoreActor` surface. This keeps the worker coupled only to the summary
/// operations it needs while still allowing tests to inject faulting spend reads.
protocol SummaryPersistenceStore: SummaryDailySpendReading {
    func updateConversationSummary(
        id: String,
        title: String?,
        summary: String?,
        provider: String?,
        model: String?,
        updatedAt: Date,
        runCostUSD: Double
    ) async throws

    func markConversationSummaryAttempt(id: String, attemptedAt: Date) async throws
}

struct DataStoreSummaryPersistenceStore: SummaryPersistenceStore {
    private let dataStore: DataStore

    init(dataStore: DataStore) {
        self.dataStore = dataStore
    }

    func updateConversationSummary(
        id: String,
        title: String?,
        summary: String?,
        provider: String?,
        model: String?,
        updatedAt: Date,
        runCostUSD: Double
    ) async throws {
        try await dataStore.updateConversationSummary(
            id: id,
            title: title,
            summary: summary,
            provider: provider,
            model: model,
            updatedAt: updatedAt,
            runCostUSD: runCostUSD
        )
    }

    func markConversationSummaryAttempt(id: String, attemptedAt: Date) async throws {
        try await dataStore.markConversationSummaryAttempt(id: id, attemptedAt: attemptedAt)
    }

    func summarySpendToday(now: Date) async throws -> Double {
        try await dataStore.summarySpendToday(now: now)
    }
}

// MARK: - Summary Worker

/// Actor that performs LLM summary calls and persists results off the main thread.
///
/// `AutoSummaryEngine` stays `@MainActor @Observable` for UI state, but delegates
/// every heavy operation (network I/O + DB writes) to this actor.
actor SummaryWorker {
    private let summaryStore: any SummaryPersistenceStore
    let llmClient: SummaryLLMClient
    let keyResolver: SummaryAPIKeyResolver

    /// Source of today's cloud summary spend used for the daily cost cap.
    /// Defaults to `summaryStore`; tests inject a fault-injecting fake here.
    private let spendReader: any SummaryDailySpendReading

    private var localSummaryEndpointCooldownUntil: Date?
    private var mlxSummaryEndpointCooldownUntil: Date?

    init(
        summaryStore: any SummaryPersistenceStore,
        llmClient: SummaryLLMClient,
        keyResolver: SummaryAPIKeyResolver,
        spendReader: (any SummaryDailySpendReading)? = nil
    ) {
        self.summaryStore = summaryStore
        self.llmClient = llmClient
        self.keyResolver = keyResolver
        self.spendReader = spendReader ?? summaryStore
    }

    // MARK: - Summarize & Store

    func summarizeAndStore(
        _ conversation: ConversationRecord,
        settings: SummarySettingsSnapshot
    ) async -> AutoSummaryResult? {
        let prompt = ContextBuilder.summarizeSessionJSONPrompt(
            fullText: conversation.fullText,
            maxChars: settings.maxPromptChars
        )

        for provider in settings.providerOrder {
            switch provider {
            case .local:
                if let cooldown = localSummaryEndpointCooldownUntil, cooldown > Date() {
                    continue
                }
                let (payload, shouldCooldown) = await llmClient.callOllama(
                    baseURL: settings.localBaseURL,
                    model: settings.localModel,
                    prompt: prompt,
                    timeout: settings.requestTimeoutSeconds,
                    maxOutputTokens: settings.maxOutputTokens
                )
                if shouldCooldown {
                    localSummaryEndpointCooldownUntil = Date().addingTimeInterval(
                        SummaryEndpointCooldownPolicy.localEndpointFailureCooldown
                    )
                }
                if let payload {
                    let clean = llmClient.sanitizeSummaryPayload(payload, fallbackTitle: conversation.inferredTaskTitle)
                    if let clean {
                        let result = AutoSummaryResult(
                            title: clean.title,
                            summary: clean.summary,
                            provider: .local,
                            model: settings.localModel,
                            estimatedCostUSD: 0
                        )
                        await persist(result, for: conversation)
                        return result
                    }
                }

            case .mlx:
                if let cooldown = mlxSummaryEndpointCooldownUntil, cooldown > Date() {
                    continue
                }
                let base = settings.mlxBaseURL
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                guard !base.isEmpty, !settings.mlxModel.isEmpty else { continue }
                if let result = await summarizeWithOpenAICompatibleProvider(
                    provider: .mlx,
                    baseURL: base + "/v1",
                    apiKey: "",
                    model: settings.mlxModel,
                    prompt: prompt,
                    fallbackTitle: conversation.inferredTaskTitle,
                    settings: settings
                ) {
                    await persist(result, for: conversation)
                    return result
                }

            case .minimax:
                guard let key = await keyResolver.resolveAPIKey(for: .minimax) else { continue }
                let model = settings.minimaxModel
                if let result = await summarizeWithOpenAICompatibleProvider(
                    provider: .minimax,
                    baseURL: "https://api.minimax.io/v1",
                    apiKey: key,
                    model: model,
                    prompt: prompt,
                    fallbackTitle: conversation.inferredTaskTitle,
                    settings: settings
                ) {
                    await persist(result, for: conversation)
                    return result
                }

            case .openrouter:
                guard let key = await keyResolver.resolveAPIKey(for: .openrouter) else { continue }
                let models = [settings.openRouterPrimaryModel, settings.openRouterFallbackModel]
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
                        openRouterHeaders: true,
                        settings: settings
                    ) {
                        await persist(result, for: conversation)
                        return result
                    }
                }

            case .zai:
                guard let key = await keyResolver.resolveAPIKey(for: .zai) else { continue }
                let model = settings.zaiModel
                if let result = await summarizeWithOpenAICompatibleProvider(
                    provider: .zai,
                    baseURL: "https://api.z.ai/api/coding/paas/v4",
                    apiKey: key,
                    model: model,
                    prompt: prompt,
                    fallbackTitle: conversation.inferredTaskTitle,
                    settings: settings
                ) {
                    await persist(result, for: conversation)
                    return result
                }

            case .ollama:
                let model = settings.ollamaModel
                let baseURL = settings.ollamaBaseURL
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                guard !baseURL.isEmpty, !model.isEmpty else { continue }
                let apiKey = await keyResolver.resolveAPIKey(for: .ollama)
                if let result = await summarizeWithOpenAICompatibleProvider(
                    provider: .ollama,
                    baseURL: baseURL + "/v1",
                    apiKey: apiKey ?? "",
                    model: model,
                    prompt: prompt,
                    fallbackTitle: conversation.inferredTaskTitle,
                    settings: settings
                ) {
                    await persist(result, for: conversation)
                    return result
                }
            }
        }

        do {
            try await summaryStore.markConversationSummaryAttempt(id: conversation.id, attemptedAt: Date())
        } catch {
            AppLogger.dataStore.silentFailure("mark_summary_attempt_failed", error: error, context: ["conversationId": conversation.id])
        }
        return nil
    }

    private func persist(_ result: AutoSummaryResult, for conversation: ConversationRecord) async {
        do {
            try await summaryStore.updateConversationSummary(
                id: conversation.id,
                title: result.title,
                summary: result.summary,
                provider: result.provider.rawValue,
                model: result.model,
                updatedAt: Date(),
                runCostUSD: result.estimatedCostUSD
            )
        } catch {
            AppLogger.dataStore.silentFailure(
                "summary_worker_update_failed",
                error: error,
                context: [
                    "conversationId": conversation.id,
                    "provider": result.provider.rawValue,
                    "model": result.model
                ]
            )
        }
    }

    // MARK: - OpenAI-Compatible Provider Wrapper

    private func summarizeWithOpenAICompatibleProvider(
        provider: SummaryProviderID,
        baseURL: String,
        apiKey: String,
        model: String,
        prompt: String,
        fallbackTitle: String,
        openRouterHeaders: Bool = false,
        settings: SummarySettingsSnapshot
    ) async -> AutoSummaryResult? {
        let estimatedInputTokens = max(prompt.count / 4, 1)
        let estimatedOutputTokens = max(settings.maxOutputTokens / 2, 100)
        let estimatedCost = SummaryCostEstimator.estimateCostUSD(
            provider: provider,
            model: model,
            inputTokens: estimatedInputTokens,
            outputTokens: estimatedOutputTokens
        )

        if provider != .local, provider != .mlx {
            // The spend read gates the cloud daily cost cap. A *failed* read must
            // fail closed: skip this paid cloud call rather than defaulting to 0,
            // which would silently let an unknown amount of spend bypass the cap.
            let spentToday: Double
            do {
                spentToday = try await spendReader.summarySpendToday(now: Date())
            } catch {
                AppLogger.dataStore.silentFailure(
                    "summary_spend_read_failed_fail_closed",
                    error: error,
                    context: [
                        "provider": provider.rawValue,
                        "model": model
                    ]
                )
                return nil
            }
            if SummaryCostEstimator.exceedsCloudDailyCap(
                adding: estimatedCost,
                dailyCapUSD: settings.dailyCapUSD,
                spentTodayUSD: spentToday
            ) {
                return nil
            }
        }

        let retryCount = max(settings.retryCount, 0)
        for _ in 0 ... retryCount {
            if Task.isCancelled { return nil }
            guard let body = await llmClient.callOpenAICompatibleCompletion(
                baseURL: baseURL,
                apiKey: apiKey,
                model: model,
                prompt: prompt,
                timeout: settings.requestTimeoutSeconds,
                maxOutputTokens: settings.maxOutputTokens,
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
}
