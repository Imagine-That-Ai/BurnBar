import Foundation
import GRDB

// MARK: - Parser Health

enum ParserHealth {
    case healthy(sessionCount: Int)
    case empty
    case failed(error: String)
    case notConfigured
}

// MARK: - Summary Queue Item

struct SummaryQueueItem: Identifiable {
    let id: String          // conversation ID
    let title: String
    enum Status { case pending, processing, done, failed }
    var status: Status = .pending
    var provider: String?   // set when done
}

// MARK: - Usage Aggregator

@Observable
@MainActor
final class UsageAggregator {
    private let dataStore: DataStore
    private let parsers: [AgentProvider: any LogParser]
    private weak var cloudSync: CloudSyncService?
    private weak var sessionMirror: ICloudSessionMirrorService?
    private let settingsManager: SettingsManager
    private let providerAPIKeyStore: ProviderAPIKeyStore
    private(set) var usageAPIService: ProviderUsageAPIService?
    private let quotaService: ProviderQuotaService
    private var hasCompletedInitialSummarySweep = false

    private(set) var isRefreshing = false
    private(set) var isSummarizing = false
    private(set) var summaryProgressDone: Int = 0
    private(set) var summaryProgressTotal: Int = 0
    private(set) var summaryCurrentTitle: String = ""
    private(set) var summaryQueue: [SummaryQueueItem] = []
    /// Seconds remaining until the time limit, nil if no limit is set.
    private(set) var summaryTimeRemaining: TimeInterval? = nil
    private(set) var lastRefresh: Date?
    private(set) var errors: [AgentProvider: String] = [:]
    private(set) var parserHealth: [AgentProvider: ParserHealth] = [:]
    /// Usage records fetched from provider billing APIs (separate from log-parsed data).
    private(set) var apiUsages: [ProviderUsageRecord] = []

    init(
        dataStore: DataStore,
        cloudSync: CloudSyncService? = nil,
        sessionMirror: ICloudSessionMirrorService? = nil,
        settingsManager: SettingsManager = .shared,
        usageAPIService: ProviderUsageAPIService? = nil,
        providerAPIKeyStore: ProviderAPIKeyStore = .shared,
        quotaService: ProviderQuotaService = .shared
    ) {
        self.dataStore = dataStore
        self.cloudSync = cloudSync
        self.sessionMirror = sessionMirror
        self.settingsManager = settingsManager
        self.usageAPIService = usageAPIService
        self.providerAPIKeyStore = providerAPIKeyStore
        self.quotaService = quotaService
        self.parsers = [
            .factory: FactoryDroidParser(),
            .claudeCode: ClaudeCodeParser(),
            .copilot: CopilotParser(),
            .aider: AiderParser(),
            .cursor: CursorParser(),
            .codex: CodexParser(),
            .zai: ModelFilterParser(modelPattern: "zai", provider: .zai),
            .minimax: ModelFilterParser(modelPattern: "minimax", provider: .minimax),
            .kimi: KimiParser(),
            .cline: ClineFormatParser(provider: .cline, storagePaths: [
                "~/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/tasks",
            ]),
            .kiloCode: ClineFormatParser(provider: .kiloCode, storagePaths: [
                "~/Library/Application Support/Code/User/globalStorage/kilocode.kilo-code/tasks",
            ]),
            .rooCode: ClineFormatParser(provider: .rooCode, storagePaths: [
                "~/Library/Application Support/Code/User/globalStorage/rooveterinaryinc.roo-cline/tasks",
                "~/Library/Application Support/Code/User/globalStorage/roo-inc.roo-code/tasks",
            ]),
            .forgeDev: ForgeDevParser(),
            .augment: AugmentParser(),
            .hermes: HermesParser(),
            .geminiCLI: GeminiCLIParser(),
            .goose: GooseParser(),
        ]
    }

    // MARK: - Refresh All

    func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        errors = [:]
        parserHealth = [:]

        var allUsages: [TokenUsage] = []

        for (provider, parser) in parsers {
            do {
                let result = try await parser.parse()
                let usages = result.usages
                if usages.isEmpty {
                    parserHealth[provider] = .empty
                } else {
                    parserHealth[provider] = .healthy(sessionCount: usages.count)
                }
                allUsages.append(contentsOf: usages)
                if settingsManager.conversationIndexingEnabled {
                    do {
                        try ConversationIndexer.shared.index(result.conversations, in: dataStore)
                    } catch {
                        print("UsageAggregator: Conversation indexing failed for \(provider.rawValue): \(error.localizedDescription)")
                    }
                }
            } catch {
                parserHealth[provider] = .failed(error: error.localizedDescription)
                errors[provider] = error.localizedDescription
            }
        }

        // Store all usages
        do {
            try dataStore.insert(allUsages)
            dataStore.replaceUsages(allUsages)
            lastRefresh = Date()
        } catch {
            print("UsageAggregator: Failed to store usages: \(error)")
        }

        // Unblock scan UI immediately after local parsing/persistence completes.
        isRefreshing = false

        launchAutoSummarySweep()

        // Fetch from provider billing APIs (complementary to log parsing)
        if let apiService = usageAPIService, !apiService.configuredProviders.isEmpty {
            let thirtyDaysAgo = Date().addingTimeInterval(-30 * 86400)
            apiUsages = await apiService.fetchAll(since: thirtyDaysAgo)
        }

        await quotaService.refreshAll(dataStore: dataStore)

        // Upload unsynced rows to Firestore (no-op if not signed in)
        await cloudSync?.uploadPending()
        await cloudSync?.uploadPendingConversations()
        await cloudSync?.uploadPendingSessionLogs()

        await sessionMirror?.syncIfNeeded()
    }

    /// Clears local usage rows so the dashboard resets immediately, then re-parses all providers.
    func recountAll() async {
        guard !isRefreshing else { return }
        do {
            try dataStore.deleteAll()
        } catch {
            print("UsageAggregator: Failed to clear usage rows before recount: \(error)")
        }
        await refreshAll()
    }

    // MARK: - Refresh Single Provider

    func refresh(provider: AgentProvider) async {
        guard let parser = parsers[provider] else { return }

        do {
            let result = try await parser.parse()
            try dataStore.insert(result.usages)
            if settingsManager.conversationIndexingEnabled {
                do {
                    try ConversationIndexer.shared.index(result.conversations, in: dataStore)
                } catch {
                    print("UsageAggregator: Conversation indexing failed for \(provider.rawValue): \(error.localizedDescription)")
                }
            }
            dataStore.refresh()
            errors.removeValue(forKey: provider)
            launchAutoSummarySweep()
            if ProviderQuotaService.supportedProviders.contains(provider) {
                await quotaService.refresh(provider: provider, dataStore: dataStore)
            }
        } catch {
            errors[provider] = error.localizedDescription
        }
    }
}

private struct SessionSummaryPayload: Decodable {
    let title: String
    let summary: String
}

private struct AutoSummaryResult {
    let title: String
    let summary: String
    let provider: SummaryProviderID
    let model: String
    let estimatedCostUSD: Double
}

private extension UsageAggregator {
    func launchAutoSummarySweep() {
        guard settingsManager.conversationIndexingEnabled,
              settingsManager.autoSessionSummariesEnabled else { return }

        Task(priority: .utility) { [weak self] in
            await self?.runAutoSummarySweep()
        }
    }

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
        }
        summaryProgressDone += 1
    }

    func markSummaryItemProcessing(_ conversation: ConversationRecord) {
        if let idx = summaryQueue.firstIndex(where: { $0.id == conversation.id }) {
            summaryQueue[idx].status = .processing
        }
        summaryCurrentTitle = conversation.inferredTaskTitle.isEmpty
            ? conversation.sessionId : conversation.inferredTaskTitle
    }

    func runAutoSummarySweep() async {
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
        let batchLimit = isInitialSweep
            ? max(settingsManager.summaryFirstLoadBatchSize, 1)
            : max(settingsManager.summaryBatchSize, 1)

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

        // Get real total up-front
        let allPending = (try? dataStore.fetchConversationsNeedingSummary(limit: 10_000)) ?? []
        summaryProgressTotal = allPending.count
        summaryQueue = allPending.map {
            SummaryQueueItem(
                id: $0.id,
                title: $0.inferredTaskTitle.isEmpty ? $0.sessionId : $0.inferredTaskTitle
            )
        }

        var failedIDs = Set<String>()
        var loopsRemaining = isInitialSweep ? 12 : 1

        while loopsRemaining > 0, !Task.isCancelled {
            // Respect time limit
            if let deadline, Date() >= deadline { break }

            guard var candidates = try? dataStore.fetchConversationsNeedingSummary(limit: batchLimit),
                  !candidates.isEmpty else { break }
            candidates.removeAll { failedIDs.contains($0.id) }
            if candidates.isEmpty { break }

            // Unified parallel pool — local and cloud compete for the same slots.
            // summarizeConversation already falls through the full provider list, so
            // sessions that miss local capacity naturally spill to cloud and vice versa.
            let maxConcurrent = max(settingsManager.summaryMaxConcurrency, 1)

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
            if !isInitialSweep || candidates.count < batchLimit { break }
        }

        hasCompletedInitialSummarySweep = true
    }

    func summarizeConversation(_ conversation: ConversationRecord) async -> AutoSummaryResult? {
        let prompt = ContextBuilder.summarizeSessionJSONPrompt(
            fullText: conversation.fullText,
            maxChars: settingsManager.summaryMaxPromptChars
        )

        for provider in settingsManager.summaryProviderOrder {
            switch provider {
            case .local:
                if let payload = await summarizeWithOllama(prompt: prompt) {
                    let clean = sanitizeSummaryPayload(payload, fallbackTitle: conversation.inferredTaskTitle)
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
                guard let key = resolveAPIKey(for: .minimax) else { continue }
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
                guard let key = resolveAPIKey(for: .openrouter) else { continue }
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
                guard let key = resolveAPIKey(for: .zai) else { continue }
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

    func summarizeWithOpenAICompatibleProvider(
        provider: SummaryProviderID,
        baseURL: String,
        apiKey: String,
        model: String,
        prompt: String,
        fallbackTitle: String,
        openRouterHeaders: Bool = false
    ) async -> AutoSummaryResult? {
        let requestTimeout = settingsManager.summaryRequestTimeoutSeconds
        let outputTokens = settingsManager.summaryMaxOutputTokens
        let estimatedInputTokens = max(prompt.count / 4, 1)
        let estimatedOutputTokens = max(outputTokens / 2, 100)
        let estimatedCost = estimateCostUSD(
            provider: provider,
            model: model,
            inputTokens: estimatedInputTokens,
            outputTokens: estimatedOutputTokens
        )

        if provider != .local, provider != .mlx, exceedsCloudDailyCap(adding: estimatedCost) {
            return nil
        }

        let retryCount = max(settingsManager.summaryRetryCount, 0)
        for _ in 0...retryCount {
            if Task.isCancelled { return nil }
            guard let body = await callOpenAICompatibleCompletion(
                baseURL: baseURL,
                apiKey: apiKey,
                model: model,
                prompt: prompt,
                timeout: requestTimeout,
                maxOutputTokens: outputTokens,
                includeOpenRouterHeaders: openRouterHeaders
            ) else {
                continue
            }

            guard let payload = parseSummaryPayload(from: body) else { continue }
            let clean = sanitizeSummaryPayload(payload, fallbackTitle: fallbackTitle)
            guard let clean else { continue }

            let outputEstimate = max((clean.title.count + clean.summary.count) / 4, 60)
            let finalCost = estimateCostUSD(
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

    func summarizeWithOllama(prompt: String) async -> SessionSummaryPayload? {
        let base = settingsManager.summaryLocalBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = URL(string: base), !settingsManager.summaryLocalModel.isEmpty else { return nil }
        let endpoint = baseURL.appendingPathComponent("api/generate")

        var request = URLRequest(url: endpoint)
        request.timeoutInterval = settingsManager.summaryRequestTimeoutSeconds
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "model": settingsManager.summaryLocalModel,
            "prompt": prompt,
            "stream": false,
            "options": [
                "temperature": 0.1,
                "num_predict": settingsManager.summaryMaxOutputTokens
            ]
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        request.httpBody = body

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["response"] as? String else {
            return nil
        }

        return parseSummaryPayload(from: text)
    }

    func callOpenAICompatibleCompletion(
        baseURL: String,
        apiKey: String,
        model: String,
        prompt: String,
        timeout: Double,
        maxOutputTokens: Int,
        includeOpenRouterHeaders: Bool
    ) async -> String? {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines) + "/chat/completions") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if includeOpenRouterHeaders {
            request.setValue("https://burnbar.app", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("BurnBar", forHTTPHeaderField: "X-Title")
        }

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": "Return strict JSON with keys title and summary."],
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.1,
            "max_tokens": maxOutputTokens
        ]

        guard let requestBody = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = requestBody

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any] else {
            return nil
        }

        if let content = message["content"] as? String {
            return content
        }
        if let blocks = message["content"] as? [[String: Any]] {
            let joined = blocks.compactMap { block -> String? in
                if let text = block["text"] as? String { return text }
                return nil
            }.joined()
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    func parseSummaryPayload(from text: String) -> SessionSummaryPayload? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let data = trimmed.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(SessionSummaryPayload.self, from: data) {
            return decoded
        }

        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}") else {
            return nil
        }
        let candidate = String(trimmed[start...end])
        guard let data = candidate.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SessionSummaryPayload.self, from: data)
    }

    func sanitizeSummaryPayload(_ payload: SessionSummaryPayload, fallbackTitle: String) -> SessionSummaryPayload? {
        let cleanedSummary = payload.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedSummary.isEmpty else { return nil }

        let cleanedTitleRaw = payload.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedTitle = cleanedTitleRaw.isEmpty ? fallbackTitle : cleanedTitleRaw
        let normalizedTitle = cleanedTitle
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let finalTitle = String(normalizedTitle.prefix(100))
        let finalSummary = String(cleanedSummary.prefix(2_000))
        guard !finalTitle.isEmpty else { return nil }
        return SessionSummaryPayload(title: finalTitle, summary: finalSummary)
    }

    func resolveAPIKey(for provider: SummaryProviderID) -> String? {
        func nonEmpty(_ value: String?) -> String? {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
                return nil
            }
            return trimmed
        }

        func cursorConnectorKey(for account: String) -> String? {
            let keychain = KeychainStore()
            let raw = try? keychain.string(for: account)
            return nonEmpty(raw ?? nil)
        }

        let env = ProcessInfo.processInfo.environment
        switch provider {
        case .local, .mlx:
            return nil
        case .openrouter:
            return nonEmpty(providerAPIKeyStore.apiKey(for: "openrouter"))
                ?? nonEmpty(env["OPENROUTER_API_KEY"])
        case .minimax:
            return nonEmpty(providerAPIKeyStore.apiKey(for: "minimax"))
                ?? cursorConnectorKey(for: "provider.minimax.apiKey")
                ?? nonEmpty(env["MINIMAX_API_KEY"])
        case .zai:
            return nonEmpty(providerAPIKeyStore.apiKey(for: "zai"))
                ?? cursorConnectorKey(for: "provider.zai.apiKey")
                ?? nonEmpty(env["ZAI_API_KEY"])
        }
    }

    func exceedsCloudDailyCap(adding estimatedCost: Double) -> Bool {
        guard let cap = settingsManager.summaryDailyCapUSD else { return false }
        let spentToday = (try? dataStore.summarySpendToday()) ?? 0
        return spentToday + max(estimatedCost, 0) > cap
    }

    func estimateCostUSD(
        provider: SummaryProviderID,
        model: String,
        inputTokens: Int,
        outputTokens: Int
    ) -> Double {
        let normalized = model.lowercased()
        let inputPerM: Double
        let outputPerM: Double

        switch provider {
        case .local, .mlx:
            return 0
        case .minimax:
            inputPerM = 0.69
            outputPerM = 0.69
        case .zai:
            inputPerM = 0.07
            outputPerM = 0.07
        case .openrouter:
            if normalized.contains("gpt-5-nano") {
                inputPerM = 0.05
                outputPerM = 0.40
            } else if normalized.contains("qwen3.5-9b") {
                inputPerM = 0.05
                outputPerM = 0.15
            } else if normalized.contains("qwen") {
                inputPerM = 0.08
                outputPerM = 0.24
            } else {
                inputPerM = 0.10
                outputPerM = 0.40
            }
        }

        return (Double(inputTokens) * inputPerM / 1_000_000)
            + (Double(outputTokens) * outputPerM / 1_000_000)
    }
}

// MARK: - Copilot Parser

/// Parses Copilot CLI sessions from ~/.copilot/session-state/*/events.jsonl.
/// Post-Feb 2026 Copilot CLI persists assistant.usage and session.shutdown events with exact token counts.
/// Falls back to CompactionProcessor log deltas for older CLI versions.
final class CopilotParser: LogParser, @unchecked Sendable {
    let provider: AgentProvider = .copilot

    func parse() async throws -> ParseResult {
        let fm = FileManager.default
        let sessionStatePath = ("~/.copilot/session-state" as NSString).expandingTildeInPath
        let logsPath = ("~/.copilot/logs" as NSString).expandingTildeInPath

        guard fm.fileExists(atPath: sessionStatePath) else {
            return ParseResult(usages: [], conversations: [])
        }

        // Parse CompactionProcessor token data from process logs (fallback for old CLI)
        let tokensBySession = parseProcessLogs(logsPath: logsPath)

        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []

        let sessionDirs = (try? fm.contentsOfDirectory(
            at: URL(fileURLWithPath: sessionStatePath),
            includingPropertiesForKeys: [.isDirectoryKey]
        ))?.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true } ?? []

        for sessionDir in sessionDirs {
            let sessionId = sessionDir.lastPathComponent
            let eventsFile = sessionDir.appendingPathComponent("events.jsonl")
            let metadataFile = sessionDir.appendingPathComponent("metadata.json")

            guard fm.fileExists(atPath: eventsFile.path) else { continue }

            // Try metadata.json for session-level summary first
            let metadataSummary = parseMetadata(metadataFile)

            if let pair = parseSession(
                eventsFile: eventsFile,
                sessionId: sessionId,
                metadataSummary: metadataSummary,
                processLogData: tokensBySession[sessionId]
            ) {
                if let usage = pair.usage { usages.append(usage) }
                if let conv = pair.conversation { conversations.append(conv) }
            }
        }

        return ParseResult(usages: usages, conversations: conversations)
    }

    private func parseMetadata(_ file: URL) -> CopilotMetadataSummary? {
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let model = json["model"] as? String
        let usage = json["usage"] as? [String: Any] ?? json["tokenUsage"] as? [String: Any]
        var input = 0
        var output = 0
        var cached = 0

        if let usage {
            let extracted = TokenExtractionUtility.extractUsageTokens(usage)
            input = extracted.input
            output = extracted.output
            cached = extracted.cacheRead
        }

        guard input > 0 || output > 0 else { return nil }
        return CopilotMetadataSummary(model: model, input: input, output: output, cached: cached)
    }

    private func parseSession(
        eventsFile: URL,
        sessionId: String,
        metadataSummary: CopilotMetadataSummary?,
        processLogData: (input: Int, output: Int)?
    ) -> (usage: TokenUsage?, conversation: ConversationRecord?)? {
        guard let handle = try? FileHandle(forReadingFrom: eventsFile) else { return nil }
        defer { try? handle.close() }

        let mtime = (try? FileManager.default.attributesOfItem(atPath: eventsFile.path)[.modificationDate]) as? Date

        var exactInputTokens = 0
        var exactOutputTokens = 0
        var exactCachedTokens = 0
        var foundExactUsage = false
        var userChars = 0
        var assistantChars = 0
        var startTime: Date?
        var endTime: Date?
        var model = metadataSummary?.model ?? "copilot"
        var fullText = ""
        var firstUser: String?
        var lastAssistant = ""
        var userWords = 0
        var assistantWords = 0
        var messageCount = 0

        for line in handle.readAllUTF8Lines() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            let eventType = json["type"] as? String ?? json["event"] as? String ?? ""
            let role = json["role"] as? String ?? ""

            // Timestamps
            if let ts = json["timestamp"] as? String {
                let date = ISO8601DateFormatter().date(from: ts)
                if startTime == nil { startTime = date }
                endTime = date
            } else if let ts = json["timestamp"] as? Double {
                let date = Date(timeIntervalSince1970: ts)
                if startTime == nil { startTime = date }
                endTime = date
            }

            // Model
            if let m = json["model"] as? String, !m.isEmpty { model = m }

            // Exact usage data (post-Feb 2026 Copilot CLI)
            // assistant.usage events and session.shutdown events contain token counts
            if eventType == "assistant.usage" || eventType == "session.shutdown" {
                if let usage = json["usage"] as? [String: Any] {
                    let extracted = TokenExtractionUtility.extractUsageTokens(usage)
                    exactInputTokens += extracted.input
                    exactOutputTokens += extracted.output
                    exactCachedTokens += extracted.cacheRead
                    foundExactUsage = true
                }
                if let usage = json["token_usage"] as? [String: Any] {
                    let extracted = TokenExtractionUtility.extractUsageTokens(usage)
                    exactInputTokens += extracted.input
                    exactOutputTokens += extracted.output
                    exactCachedTokens += extracted.cacheRead
                    foundExactUsage = true
                }
            }

            // Also check for inline usage on any message
            if let usage = json["usage"] as? [String: Any], eventType != "assistant.usage" && eventType != "session.shutdown" {
                let extracted = TokenExtractionUtility.extractUsageTokens(usage)
                if extracted.input > 0 || extracted.output > 0 {
                    exactInputTokens += extracted.input
                    exactOutputTokens += extracted.output
                    exactCachedTokens += extracted.cacheRead
                    foundExactUsage = true
                }
            }

            // Content for conversation record
            let content = json["content"] as? String ?? json["text"] as? String ?? ""
            if role == "user" || eventType == "user_message" {
                userChars += content.count
                if !content.isEmpty {
                    userWords += wordCount(content)
                    if firstUser == nil {
                        firstUser = String(content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
                    }
                    appendText(&fullText, content)
                    messageCount += 1
                }
            } else if role == "assistant" || eventType == "assistant_message" {
                assistantChars += content.count
                if !content.isEmpty {
                    assistantWords += wordCount(content)
                    lastAssistant = content
                    appendText(&fullText, content)
                    messageCount += 1
                }
            }
        }

        // Determine best token data source: exact events > metadata > process logs > char estimation
        let inputTokens: Int
        let outputTokens: Int
        let cacheReadTokens: Int

        if foundExactUsage {
            inputTokens = exactInputTokens
            outputTokens = exactOutputTokens
            cacheReadTokens = exactCachedTokens
        } else if let meta = metadataSummary {
            inputTokens = meta.input
            outputTokens = meta.output
            cacheReadTokens = meta.cached
        } else if let pd = processLogData {
            inputTokens = pd.input
            outputTokens = pd.output
            cacheReadTokens = 0
        } else {
            inputTokens = TokenExtractionUtility.estimatedTokenCount(for: userChars, charsPerToken: 3.5)
            outputTokens = TokenExtractionUtility.estimatedTokenCount(for: assistantChars, charsPerToken: 3.5)
            cacheReadTokens = 0
        }

        guard inputTokens > 0 || outputTokens > 0 else { return nil }

        let pricing = ModelPricing.lookup(model: model)
        let cost = pricing.cost(inputTokens: inputTokens, outputTokens: outputTokens, cacheReadTokens: cacheReadTokens)

        let usage = TokenUsage(
            provider: .copilot,
            sessionId: sessionId,
            projectName: "Copilot",
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: 0,
            cacheReadTokens: cacheReadTokens,
            costUSD: cost,
            startTime: startTime ?? Date(),
            endTime: endTime ?? Date()
        )

        let conversation = ConversationRecord(
            id: ConversationRecord.stableId(provider: .copilot, sessionId: sessionId),
            provider: .copilot,
            sessionId: sessionId,
            projectName: "Copilot",
            startTime: startTime ?? usage.startTime,
            endTime: endTime ?? usage.endTime,
            messageCount: messageCount,
            userWordCount: userWords,
            assistantWordCount: assistantWords,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: firstUser ?? "Copilot Session",
            lastAssistantMessage: lastAssistant,
            fullText: fullText,
            indexedAt: Date(),
            fileModifiedAt: mtime,
            summary: nil
        )

        return (usage, conversation)
    }

    /// Parse process logs for CompactionProcessor entries (fallback for pre-Feb 2026 CLI).
    private func parseProcessLogs(logsPath: String) -> [String: (input: Int, output: Int)] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: logsPath) else { return [:] }

        var result: [String: (input: Int, output: Int)] = [:]

        guard let logFiles = try? fm.contentsOfDirectory(atPath: logsPath)
            .filter({ $0.hasPrefix("process-") && $0.hasSuffix(".log") }) else {
            return [:]
        }

        for logFile in logFiles {
            let fullPath = (logsPath as NSString).appendingPathComponent(logFile)
            guard let data = fm.contents(atPath: fullPath),
                  let content = String(data: data, encoding: .utf8) else { continue }

            var lastTokensBySession: [String: Int] = [:]
            var prevTokensBySession: [String: Int] = [:]

            for line in content.components(separatedBy: .newlines) {
                guard line.contains("CompactionProcessor") || line.contains("context_tokens") else { continue }

                var sessionId: String?
                var tokens: Int?

                let parts = line.components(separatedBy: .whitespaces)
                for part in parts {
                    if part.hasPrefix("session=") {
                        sessionId = String(part.dropFirst(8))
                    } else if part.hasPrefix("context_tokens=") {
                        tokens = Int(String(part.dropFirst(15)))
                    }
                }

                if let sid = sessionId, let t = tokens {
                    prevTokensBySession[sid] = lastTokensBySession[sid] ?? 0
                    lastTokensBySession[sid] = t
                }
            }

            for (sid, lastTokens) in lastTokensBySession {
                let prevTokens = prevTokensBySession[sid] ?? 0
                let outputEstimate = max(lastTokens - prevTokens, lastTokens / 20)
                let inputEstimate = max(lastTokens - outputEstimate, 0)
                result[sid] = (input: inputEstimate, output: outputEstimate)
            }
        }

        return result
    }

    private func appendText(_ full: inout String, _ chunk: String) {
        if !full.isEmpty { full += "\n\n" }
        full += chunk
    }

    private func wordCount(_ s: String) -> Int {
        s.split { $0.isWhitespace || $0.isNewline }.filter { !$0.isEmpty }.count
    }
}

private struct CopilotMetadataSummary {
    let model: String?
    let input: Int
    let output: Int
    let cached: Int
}

// MARK: - Aider Parser

/// Parses Aider analytics JSONL logs for exact per-message token usage.
/// Requires user to configure: `analytics-log: ~/.aider/analytics.jsonl` in .aider.conf.yml
final class AiderParser: LogParser, @unchecked Sendable {
    let provider: AgentProvider = .aider

    func parse() async throws -> ParseResult {
        let fm = FileManager.default

        // Check common analytics log locations
        let candidatePaths = [
            ("~/.aider/analytics.jsonl" as NSString).expandingTildeInPath,
            ("~/.aider/analytics.json" as NSString).expandingTildeInPath
        ]

        // Also check for per-project .aider.analytics.jsonl in recent git repos
        var analyticsFiles: [URL] = []
        for path in candidatePaths {
            if fm.fileExists(atPath: path) {
                analyticsFiles.append(URL(fileURLWithPath: path))
            }
        }

        guard !analyticsFiles.isEmpty else {
            return ParseResult(usages: [], conversations: [])
        }

        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []

        for file in analyticsFiles {
            let (fileUsages, fileConvs) = parseAnalyticsLog(file: file)
            usages.append(contentsOf: fileUsages)
            conversations.append(contentsOf: fileConvs)
        }

        return ParseResult(usages: usages, conversations: conversations)
    }

    private func parseAnalyticsLog(file: URL) -> ([TokenUsage], [ConversationRecord]) {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return ([], []) }
        defer { try? handle.close() }

        // Group message_send events into sessions bounded by cli_session/exit events
        var sessions: [AiderSession] = []
        var current = AiderSession()

        for line in handle.readAllUTF8Lines() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            let event = json["event"] as? String ?? ""
            let props = json["properties"] as? [String: Any] ?? [:]
            let time = json["time"] as? Double

            switch event {
            case "launched", "cli session":
                // Start a new session
                if current.hasData {
                    sessions.append(current)
                }
                current = AiderSession()
                if let t = time { current.startTime = Date(timeIntervalSince1970: t) }
                if let m = props["main_model"] as? String { current.model = m }

            case "message_send":
                let promptTokens = props["prompt_tokens"] as? Int ?? 0
                let completionTokens = props["completion_tokens"] as? Int ?? 0
                let cost = props["cost"] as? Double ?? 0
                current.inputTokens += promptTokens
                current.outputTokens += completionTokens
                current.totalCost += cost
                current.messageCount += 1
                if let t = time { current.endTime = Date(timeIntervalSince1970: t) }
                if current.startTime == nil, let t = time {
                    current.startTime = Date(timeIntervalSince1970: t)
                }
                if let m = props["main_model"] as? String, !m.isEmpty {
                    current.model = m
                }

            case "exit":
                if let t = time { current.endTime = Date(timeIntervalSince1970: t) }
                if current.hasData {
                    sessions.append(current)
                }
                current = AiderSession()

            default:
                break
            }
        }

        // Don't lose the last session if no exit event
        if current.hasData {
            sessions.append(current)
        }

        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []

        for (index, session) in sessions.enumerated() {
            let sessionId = "aider-\(index)-\(Int(session.startTime?.timeIntervalSince1970 ?? 0))"
            let model = session.model ?? "unknown"

            // Use cost from Aider if available, otherwise compute from pricing
            let cost: Double
            if session.totalCost > 0 {
                cost = session.totalCost
            } else {
                let pricing = ModelPricing.lookup(model: model)
                cost = pricing.cost(inputTokens: session.inputTokens, outputTokens: session.outputTokens)
            }

            let usage = TokenUsage(
                provider: .aider,
                sessionId: sessionId,
                projectName: "Aider",
                model: model,
                inputTokens: session.inputTokens,
                outputTokens: session.outputTokens,
                costUSD: cost,
                startTime: session.startTime ?? Date(),
                endTime: session.endTime ?? Date()
            )
            usages.append(usage)

            let conversation = ConversationRecord(
                id: ConversationRecord.stableId(provider: .aider, sessionId: sessionId),
                provider: .aider,
                sessionId: sessionId,
                projectName: "Aider",
                startTime: session.startTime,
                endTime: session.endTime,
                messageCount: session.messageCount,
                userWordCount: 0,
                assistantWordCount: 0,
                keyFiles: [],
                keyCommands: [],
                keyTools: [],
                inferredTaskTitle: "Aider Session",
                lastAssistantMessage: "",
                fullText: "",
                indexedAt: Date(),
                fileModifiedAt: nil,
                summary: nil
            )
            conversations.append(conversation)
        }

        return (usages, conversations)
    }
}

private struct AiderSession {
    var startTime: Date?
    var endTime: Date?
    var model: String?
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var totalCost: Double = 0
    var messageCount: Int = 0

    var hasData: Bool { inputTokens > 0 || outputTokens > 0 }
}

// MARK: - Cursor Parser

/// Parses Cursor's ai-code-tracking.db for code provenance data and model usage distribution.
/// Token-level tracking requires the CursorConnector BYOK proxy.
final class CursorParser: LogParser, @unchecked Sendable {
    let provider: AgentProvider = .cursor

    func parse() async throws -> ParseResult {
        let dbPath = ("~/.cursor/ai-tracking/ai-code-tracking.db" as NSString).expandingTildeInPath

        guard FileManager.default.fileExists(atPath: dbPath) else {
            return ParseResult(usages: [], conversations: [])
        }

        let usages = try parseCursorDatabase(dbPath: dbPath)
        return ParseResult(usages: usages, conversations: [])
    }

    private func parseCursorDatabase(dbPath: String) throws -> [TokenUsage] {
        var usages: [TokenUsage] = []

        var config = Configuration()
        config.readonly = true
        let db = try DatabaseQueue(path: dbPath, configuration: config)

        try db.read { db in
            // Check if ai_code_hashes table exists
            let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'")
            guard tables.contains("ai_code_hashes") else { return }

            // Aggregate by conversationId + model to create usage records
            let rows = try Row.fetchAll(db, sql: """
                SELECT
                    conversationId,
                    model,
                    COUNT(*) as hash_count,
                    MIN(createdAt) as first_seen,
                    MAX(createdAt) as last_seen
                FROM ai_code_hashes
                WHERE conversationId IS NOT NULL AND conversationId != ''
                GROUP BY conversationId, model
                ORDER BY last_seen DESC
                LIMIT 500
            """)

            for row in rows {
                guard let conversationId: String = row["conversationId"],
                      let hashCount: Int = row["hash_count"] else {
                    continue
                }

                let model: String = row["model"] ?? "cursor"
                let firstSeen: Double = row["first_seen"] ?? Date().timeIntervalSince1970
                let lastSeen: Double = row["last_seen"] ?? firstSeen

                // Estimate tokens from code hash count — each hash represents a generated code block.
                // Average code block ~150 tokens output, ~500 tokens input context.
                let estimatedOutput = hashCount * 150
                let estimatedInput = hashCount * 500

                let pricing = ModelPricing.lookup(model: model)
                let cost = pricing.cost(inputTokens: estimatedInput, outputTokens: estimatedOutput)

                let usage = TokenUsage(
                    provider: .cursor,
                    sessionId: conversationId,
                    projectName: "Cursor",
                    model: model,
                    inputTokens: estimatedInput,
                    outputTokens: estimatedOutput,
                    costUSD: cost,
                    startTime: Date(timeIntervalSince1970: firstSeen),
                    endTime: Date(timeIntervalSince1970: lastSeen)
                )
                usages.append(usage)
            }
        }

        return usages
    }
}

// MARK: - Codex Parser

/// Reads token usage from Codex's SQLite store and JSONL session files.
/// Prefers exact token breakdowns from JSONL `token_count` events over the aggregate `tokens_used` in SQLite.
final class CodexParser: LogParser, @unchecked Sendable {
    let provider: AgentProvider = .codex

    func parse() async throws -> ParseResult {
        let basePath = (provider.logDirectory as NSString).expandingTildeInPath
        let dbPath = (basePath as NSString).appendingPathComponent("state_5.sqlite")

        guard FileManager.default.fileExists(atPath: dbPath) else {
            return ParseResult(usages: [], conversations: [])
        }

        let usages = try parseCodexDatabase(dbPath: dbPath)
        return ParseResult(usages: usages, conversations: [])
    }

    private func parseCodexDatabase(dbPath: String) throws -> [TokenUsage] {
        var usages: [TokenUsage] = []

        var config = Configuration()
        config.readonly = true
        let db = try DatabaseQueue(path: dbPath, configuration: config)

        try db.read { db in
            // Check if rollout_path column exists
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(threads)")
            let columnNames = Set(columns.compactMap { $0["name"] as? String })
            let hasRolloutPath = columnNames.contains("rollout_path")

            let sql: String
            if hasRolloutPath {
                sql = """
                    SELECT
                        id, title, model, model_provider, tokens_used,
                        created_at, updated_at, cwd, rollout_path
                    FROM threads
                    WHERE archived = 0
                    ORDER BY created_at DESC
                    LIMIT 500
                """
            } else {
                sql = """
                    SELECT
                        id, title, model, model_provider, tokens_used,
                        created_at, updated_at, cwd
                    FROM threads
                    WHERE archived = 0
                    ORDER BY created_at DESC
                    LIMIT 500
                """
            }

            let rows = try Row.fetchAll(db, sql: sql)

            for row in rows {
                guard let threadId: String = row["id"],
                      let createdAt: Int64 = row["created_at"],
                      let updatedAt: Int64 = row["updated_at"] else {
                    continue
                }

                let model: String = row["model"] ?? "unknown"
                let cwd: String = row["cwd"] ?? "~"
                let projectName = (cwd as NSString).lastPathComponent
                let startTime = Date(timeIntervalSince1970: Double(createdAt))
                let endTime = Date(timeIntervalSince1970: Double(updatedAt))

                // Try to get exact token breakdown from JSONL session file
                var inputTokens: Int = 0
                var outputTokens: Int = 0
                var cacheReadTokens: Int = 0
                var foundExact = false

                if hasRolloutPath, let rolloutPath: String = row["rollout_path"] {
                    let expandedPath = (rolloutPath as NSString).expandingTildeInPath
                    if let tokenUsage = parseCodexSessionJSONL(path: expandedPath) {
                        inputTokens = tokenUsage.input
                        outputTokens = tokenUsage.output
                        cacheReadTokens = tokenUsage.cacheRead
                        foundExact = true
                    }
                }

                if !foundExact {
                    let tokensUsed: Int = row["tokens_used"] ?? 0
                    // Better than 50/50: Codex sessions are heavily input-weighted (~95/5)
                    inputTokens = Int(Double(tokensUsed) * 0.95)
                    outputTokens = max(tokensUsed - inputTokens, 0)
                }

                guard inputTokens > 0 || outputTokens > 0 else { continue }

                let pricing = ModelPricing.lookup(model: model)
                let cost = pricing.cost(
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    cacheReadTokens: cacheReadTokens
                )

                let usage = TokenUsage(
                    provider: .codex,
                    sessionId: threadId,
                    projectName: projectName,
                    model: model,
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    cacheCreationTokens: 0,
                    cacheReadTokens: cacheReadTokens,
                    costUSD: cost,
                    startTime: startTime,
                    endTime: endTime
                )
                usages.append(usage)
            }
        }

        return usages
    }

    /// Parse a Codex session JSONL file to extract the last `token_count` event with exact breakdowns.
    private func parseCodexSessionJSONL(path: String) -> (input: Int, output: Int, cacheRead: Int)? {
        guard FileManager.default.fileExists(atPath: path),
              let handle = FileHandle(forReadingAtPath: path) else {
            return nil
        }
        defer { try? handle.close() }

        var lastInput = 0
        var lastOutput = 0
        var lastCacheRead = 0
        var found = false

        for line in handle.readAllUTF8Lines() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            guard json["type"] as? String == "token_count",
                  let info = json["info"] as? [String: Any],
                  let totalUsage = info["total_token_usage"] as? [String: Any] else {
                continue
            }

            lastInput = totalUsage["input_tokens"] as? Int ?? 0
            lastOutput = totalUsage["output_tokens"] as? Int ?? 0
            lastCacheRead = totalUsage["cached_input_tokens"] as? Int ?? 0
            found = true
        }

        return found ? (input: lastInput, output: lastOutput, cacheRead: lastCacheRead) : nil
    }
}

// MARK: - Model Filter Parser (for Zai/MiniMax which use Factory sessions)

final class ModelFilterParser: LogParser, @unchecked Sendable {
    let provider: AgentProvider
    private let modelPattern: String

    init(modelPattern: String, provider: AgentProvider) {
        self.modelPattern = modelPattern.lowercased()
        self.provider = provider
    }

    func parse() async throws -> ParseResult {
        let sessionsPath = "~/.factory/sessions"
        let sessionsURL = URL(fileURLWithPath: (sessionsPath as NSString).expandingTildeInPath)

        guard FileManager.default.fileExists(atPath: sessionsURL.path) else {
            return ParseResult(usages: [], conversations: [])
        }

        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []

        let projectDirs = try FileManager.default.contentsOfDirectory(at: sessionsURL, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }

        for projectDir in projectDirs {
            let projectName = decodeProjectName(projectDir.lastPathComponent)

            let files = try FileManager.default.contentsOfDirectory(at: projectDir, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "jsonl" }

            for jsonlFile in files {
                if let pair = try? parseSession(file: jsonlFile, projectName: projectName),
                   let usage = pair.usage {
                    usages.append(usage)
                    if let conv = pair.conversation {
                        conversations.append(conv)
                    }
                }
            }
        }

        return ParseResult(usages: usages, conversations: conversations)
    }

    private func decodeProjectName(_ encoded: String) -> String {
        var decoded = encoded
            .replacingOccurrences(of: "-Users-", with: "~/")
            .replacingOccurrences(of: "-", with: "/")
        while decoded.contains("//") {
            decoded = decoded.replacingOccurrences(of: "//", with: "/")
        }
        return decoded
    }

    private func parseSession(file: URL, projectName: String) throws -> (usage: TokenUsage?, conversation: ConversationRecord?)? {
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            return nil
        }
        defer { try? handle.close() }

        let mtime = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]) as? Date
        let conv = ClaudeConversationAccumulator()

        let baseName = file.deletingPathExtension().lastPathComponent
        let settingsURL = file.deletingLastPathComponent().appendingPathComponent("\(baseName).settings.json")

        var inlineModel: String?
        var inputTokens = 0
        var outputTokens = 0
        var cacheCreationTokens = 0
        var cacheReadTokens = 0
        var usedSettingsTotals = false
        var settingsModel: String?

        if let data = try? Data(contentsOf: settingsURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let m = json["model"] as? String {
                settingsModel = TokenExtractionUtility.normalizeModelName(m)
            }
            if let tokenUsage = json["tokenUsage"] as? [String: Any] {
                let extracted = TokenExtractionUtility.extractUsageTokens(tokenUsage)
                if extracted.input > 0 || extracted.output > 0 || extracted.cacheCreation > 0 || extracted.cacheRead > 0 {
                    inputTokens = extracted.input
                    outputTokens = extracted.output
                    cacheCreationTokens = extracted.cacheCreation
                    cacheReadTokens = extracted.cacheRead
                    usedSettingsTotals = true
                }
            }
        }

        var startTime: Date?
        var endTime: Date?
        var userCharCount = 0
        var assistantCharCount = 0
        var assistantReasoningCharCount = 0
        var userMessageCount = 0
        var assistantMessageCount = 0

        for line in handle.readAllUTF8Lines() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            conv.ingest(jsonLine: json)

            if let message = json["message"] as? [String: Any] {
                let role = (message["role"] as? String)?.lowercased()
                if let content = message["content"] {
                    let metrics = TokenExtractionUtility.contentMetrics(from: content)
                    if role == "user" {
                        let chars = metrics.visibleChars + metrics.reasoningChars
                        if chars > 0 {
                            userCharCount += chars
                            userMessageCount += 1
                        }
                    } else if role == "assistant" {
                        let chars = metrics.visibleChars + metrics.reasoningChars
                        if chars > 0 {
                            assistantMessageCount += 1
                        }
                        assistantCharCount += metrics.visibleChars
                        assistantReasoningCharCount += metrics.reasoningChars
                    }

                    if inlineModel == nil, let detectedModel = TokenExtractionUtility.detectModelHint(from: content) {
                        inlineModel = TokenExtractionUtility.normalizeModelName(detectedModel)
                    }
                }
            }

            if usedSettingsTotals {
                if let message = json["message"] as? [String: Any],
                   message["role"] as? String == "assistant",
                   let ts = json["timestamp"] as? String {
                    let date = ISO8601DateFormatter().date(from: ts)
                    if startTime == nil { startTime = date }
                    endTime = date
                }
                continue
            }

            if let message = json["message"] as? [String: Any],
               (message["role"] as? String)?.lowercased() == "assistant",
               let usage = message["usage"] as? [String: Any] {
                let extracted = TokenExtractionUtility.extractUsageTokens(
                    usage,
                    inputHint: userCharCount,
                    outputHint: assistantCharCount + assistantReasoningCharCount
                )
                inputTokens += extracted.input
                outputTokens += extracted.output
                cacheCreationTokens += extracted.cacheCreation
                cacheReadTokens += extracted.cacheRead

                if let ts = json["timestamp"] as? String {
                    let date = ISO8601DateFormatter().date(from: ts)
                    if startTime == nil { startTime = date }
                    endTime = date
                }
            }
        }

        conv.finalizeArrays()

        if inputTokens == 0 && outputTokens == 0 && cacheCreationTokens == 0 && cacheReadTokens == 0 {
            guard userCharCount + assistantCharCount + assistantReasoningCharCount > 0 else { return nil }
            let estimated = TokenExtractionUtility.estimateFallbackTokens(
                userVisibleChars: userCharCount,
                assistantVisibleChars: assistantCharCount,
                assistantReasoningChars: assistantReasoningCharCount,
                userMessageCount: userMessageCount,
                assistantMessageCount: assistantMessageCount
            )
            inputTokens = estimated.input
            outputTokens = estimated.output
        }

        let modelFromSettings = settingsModel.flatMap { m in
            m.lowercased().contains(modelPattern) ? m : nil
        }
        let resolvedModel = modelFromSettings ?? inlineModel
        guard let model = resolvedModel, model.lowercased().contains(modelPattern) else {
            return nil
        }

        guard inputTokens > 0 || outputTokens > 0 || cacheCreationTokens > 0 || cacheReadTokens > 0 else {
            return nil
        }

        let resolvedStart = startTime ?? conv.startTime ?? Date()
        let resolvedEnd = endTime ?? conv.endTime ?? resolvedStart

        let cost = ModelPricing.lookup(model: model).cost(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens
        )
        let sessionId = baseName

        let usage = TokenUsage(
            provider: provider,
            sessionId: sessionId,
            projectName: projectName,
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens,
            costUSD: cost,
            startTime: resolvedStart,
            endTime: resolvedEnd
        )

        let conversation = ConversationRecord(
            id: ConversationRecord.stableId(provider: provider, sessionId: sessionId),
            provider: provider,
            sessionId: sessionId,
            projectName: projectName,
            startTime: conv.startTime ?? usage.startTime,
            endTime: conv.endTime ?? usage.endTime,
            messageCount: conv.messageCount,
            userWordCount: conv.userWordCount,
            assistantWordCount: conv.assistantWordCount,
            keyFiles: conv.keyFiles,
            keyCommands: conv.keyCommands,
            keyTools: conv.keyTools,
            inferredTaskTitle: conv.firstUserText ?? projectName,
            lastAssistantMessage: conv.lastAssistantText,
            fullText: conv.fullText,
            indexedAt: Date(),
            fileModifiedAt: mtime,
            summary: nil
        )

        return (usage, conversation)
    }
}
