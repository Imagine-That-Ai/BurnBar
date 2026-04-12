import Foundation

private let providerQuotaZaiDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter
}()

#if false
private enum CodexQuotaScanPolicy {
    static let freshnessWindow: TimeInterval = 7 * 24 * 60 * 60
    static let tailReadBytes = 512 * 1024
    static let maxTailLines = 4000
}

private enum MiniMaxAPIKeyKind {
    case codingPlan
    case standard
    case unknown
}
#endif

// MARK: - Quota Service

@Observable
@MainActor
final class ProviderQuotaService {
    static let shared = ProviderQuotaService()

    static let supportedProviders: [AgentProvider] = [
        .codex,
        .claudeCode,
        .minimax,
        .zai,
        .factory,
        .cursor,
    ]

    private let keyStore: ProviderAPIKeyStore
    private let appPaths: OpenBurnBarAppPaths
    private let fileManager: FileManager
    private let session: URLSession
    private let environment: [String: String]
    private let homeDirectoryURL: URL
    private let miniMaxModeProvider: () -> MiniMaxQuotaMode
    private let factoryPlanProvider: () -> FactoryQuotaPlanTier

    private(set) var snapshotsByProvider: [AgentProvider: ProviderQuotaSnapshot] = [:]
    private(set) var errors: [AgentProvider: String] = [:]
    private(set) var isFetching = false
    private(set) var activeProviders: Set<AgentProvider> = []
    private(set) var lastFetch: Date?
    private(set) var claudeBridgeStatus: ClaudeQuotaBridgeStatus
    private var codexRolloutScanCache: CodexRolloutScanCache = .empty

    init(
        keyStore: ProviderAPIKeyStore = .shared,
        appPaths: OpenBurnBarAppPaths = .live(),
        fileManager: FileManager = .default,
        session: URLSession = .shared,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        miniMaxModeProvider: @escaping () -> MiniMaxQuotaMode = { SettingsManager.shared.miniMaxQuotaMode },
        factoryPlanProvider: @escaping () -> FactoryQuotaPlanTier = { SettingsManager.shared.factoryQuotaPlanTier }
    ) {
        self.keyStore = keyStore
        self.appPaths = appPaths
        self.fileManager = fileManager
        self.session = session
        self.environment = environment
        self.homeDirectoryURL = homeDirectoryURL
        self.miniMaxModeProvider = miniMaxModeProvider
        self.factoryPlanProvider = factoryPlanProvider
        self.claudeBridgeStatus = ClaudeQuotaBridgeStatus(
            state: .notInstalled,
            wrapperPath: appPaths.claudeStatuslineBridgeScriptURL.path,
            detailText: "Enable OpenBurnBar's status line bridge to capture Claude quota updates.",
            lastPayloadAt: nil
        )

        _ = try? OpenBurnBarMigration.prepareSupportDirectory(fileManager: fileManager, paths: appPaths)
        loadPersistedSnapshots()
        loadPersistedCodexRolloutScanCache()
        refreshClaudeBridgeStatus()
    }

    func snapshot(for provider: AgentProvider) -> ProviderQuotaSnapshot? {
        snapshotsByProvider[provider]
    }

    func isRefreshing(_ provider: AgentProvider) -> Bool {
        activeProviders.contains(provider)
    }

    func refreshIfNeeded(dataStore: DataStore, maxAge: TimeInterval = 5 * 60) async {
        // Always refresh if we have no useful snapshots for any supported provider
        let hasUsefulSnapshot = ProviderQuotaService.supportedProviders.contains { provider in
            let snap = snapshotsByProvider[provider]
            return snap != nil && !(snap?.buckets.isEmpty ?? true)
        }
        if !hasUsefulSnapshot {
            await refreshAll(dataStore: dataStore)
            return
        }
        if let lastFetch, Date().timeIntervalSince(lastFetch) < maxAge {
            return
        }
        await refreshAll(dataStore: dataStore)
    }

    func refreshAll(dataStore: DataStore) async {
        guard !isFetching else { return }
        isFetching = true
        defer {
            isFetching = false
            activeProviders.removeAll()
        }
        errors = [:]
        refreshClaudeBridgeStatus()

        for provider in Self.supportedProviders {
            await refresh(provider: provider, dataStore: dataStore)
        }

        lastFetch = Date()
        persistSnapshots()
    }

    func refresh(provider: AgentProvider, dataStore: DataStore) async {
        guard Self.supportedProviders.contains(provider) else { return }
        activeProviders.insert(provider)
        defer { activeProviders.remove(provider) }

        do {
            let snapshot = try await fetchSnapshot(for: provider, dataStore: dataStore)
            snapshotsByProvider[provider] = snapshot
            errors.removeValue(forKey: provider)
            lastFetch = Date()
            persistSnapshots()
            if provider == .claudeCode {
                refreshClaudeBridgeStatus()
            }
        } catch {
            errors[provider] = error.localizedDescription
            if snapshotsByProvider[provider] == nil {
                snapshotsByProvider[provider] = unavailableSnapshot(
                    for: provider,
                    source: .unavailable,
                    message: error.localizedDescription
                )
            }
        }
    }

    func fetchSnapshot(
        for provider: AgentProvider,
        apiKeyOverride: String
    ) async throws -> ProviderQuotaSnapshot {
        switch provider {
        case .minimax:
            return try await fetchMiniMaxSnapshot(apiKeyOverride: apiKeyOverride)
        case .zai:
            return try await fetchZaiSnapshot(apiKeyOverride: apiKeyOverride)
        default:
            return unavailableSnapshot(
                for: provider,
                source: .unavailable,
                message: "Per-plan quota refresh is currently available for MiniMax and Z.ai."
            )
        }
    }

    func installClaudeQuotaBridge() throws {
        let settingsURL = homeDirectoryURL
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json")

        let wrapperURL = appPaths.claudeStatuslineBridgeScriptURL
        let metadataURL = appPaths.claudeStatuslineBridgeMetadataURL
        let snapshotURL = appPaths.claudeStatuslineSnapshotURL

        try ensureParentDirectory(for: settingsURL)
        try ensureParentDirectory(for: wrapperURL)
        try ensureParentDirectory(for: metadataURL)

        var settings = try readJSONObject(from: settingsURL) ?? [:]
        let currentStatusLine = settings["statusLine"]
        let metadata = (try readJSONObject(from: metadataURL)) ?? [:]

        let wrapperCommand = wrapperURL.path
        let currentCommand = command(fromStatusLine: currentStatusLine)
        let isAlreadyBridge = currentCommand == wrapperCommand
            || currentCommand == "'\(wrapperCommand.replacingOccurrences(of: "'", with: "'\\''"))'"
        let originalStatusLine: Any
        if isAlreadyBridge, let existingOriginal = metadata["originalStatusLine"] {
            originalStatusLine = existingOriginal
        } else {
            originalStatusLine = currentStatusLine ?? NSNull()
        }

        let originalCommand = command(fromStatusLine: originalStatusLine)
        try writeClaudeBridgeWrapper(
            to: wrapperURL,
            snapshotPath: snapshotURL.path,
            metadataPath: metadataURL.path
        )

        try writeJSONObject(
            [
                "originalStatusLine": originalStatusLine,
                "originalCommand": originalCommand ?? NSNull(),
                "installedAt": Self.isoFormatter.string(from: Date()),
                "wrapperPath": wrapperURL.path,
            ],
            to: metadataURL
        )

        // Shell-escape the path in case it contains spaces (e.g. "Application Support").
        // Claude Code runs the command via sh -c, so unquoted spaces break execution.
        let shellSafeCommand = wrapperCommand.contains(" ")
            ? "'\(wrapperCommand.replacingOccurrences(of: "'", with: "'\\''"))'"
            : wrapperCommand
        settings["statusLine"] = [
            "type": "command",
            "command": shellSafeCommand,
        ]
        try writeJSONObject(settings, to: settingsURL)
        refreshClaudeBridgeStatus()
    }

    func removeClaudeQuotaBridge() throws {
        let settingsURL = homeDirectoryURL
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json")
        let metadataURL = appPaths.claudeStatuslineBridgeMetadataURL

        guard var settings = try readJSONObject(from: settingsURL) else {
            refreshClaudeBridgeStatus()
            return
        }

        let metadata = try readJSONObject(from: metadataURL)
        if let originalStatusLine = metadata?["originalStatusLine"] {
            if originalStatusLine is NSNull {
                settings.removeValue(forKey: "statusLine")
            } else {
                settings["statusLine"] = originalStatusLine
            }
        } else {
            settings.removeValue(forKey: "statusLine")
        }
        try writeJSONObject(settings, to: settingsURL)

        try? fileManager.removeItem(at: metadataURL)
        try? fileManager.removeItem(at: appPaths.claudeStatuslineBridgeScriptURL)
        refreshClaudeBridgeStatus()
    }

    func refreshClaudeBridgeStatus() {
        let wrapperPath = appPaths.claudeStatuslineBridgeScriptURL.path
        let snapshotURL = appPaths.claudeStatuslineSnapshotURL
        let settingsURL = homeDirectoryURL
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json")

        guard let settings = ((try? readJSONObject(from: settingsURL)) ?? nil) else {
            claudeBridgeStatus = ClaudeQuotaBridgeStatus(
                state: .notInstalled,
                wrapperPath: wrapperPath,
                detailText: "Claude settings were not found. OpenBurnBar can install a global status line bridge in ~/.claude/settings.json.",
                lastPayloadAt: nil
            )
            return
        }

        let disableAllHooks = (settings["disableAllHooks"] as? Bool) == true
        let configuredCommand = command(fromStatusLine: settings["statusLine"])
        let snapshotDate = modificationDate(for: snapshotURL)

        // Match both raw path and shell-escaped path (e.g. with wrapping single-quotes)
        let isBridgeInstalled = configuredCommand == wrapperPath
            || configuredCommand == "'\(wrapperPath.replacingOccurrences(of: "'", with: "'\\''"))'"
        if isBridgeInstalled {
            if disableAllHooks {
                claudeBridgeStatus = ClaudeQuotaBridgeStatus(
                    state: .disabledByHooks,
                    wrapperPath: wrapperPath,
                    detailText: "Claude has disableAllHooks=true, so status line commands will not run until hooks are re-enabled.",
                    lastPayloadAt: snapshotDate
                )
                return
            }

            if snapshotDate == nil {
                claudeBridgeStatus = ClaudeQuotaBridgeStatus(
                    state: .awaitingFirstPayload,
                    wrapperPath: wrapperPath,
                    detailText: "Bridge installed but no data yet. The status line hook is CLI-only — send a prompt via the Claude Code CLI (not VS Code extension) to capture rate-limit JSON.",
                    lastPayloadAt: nil
                )
            } else {
                claudeBridgeStatus = ClaudeQuotaBridgeStatus(
                    state: .ready,
                    wrapperPath: wrapperPath,
                    detailText: "Bridge installed and receiving Claude status line payloads.",
                    lastPayloadAt: snapshotDate
                )
            }
            return
        }

        let detail: String
        if settings["statusLine"] != nil {
            detail = "Claude already has a custom status line command. OpenBurnBar can wrap and preserve it if you enable the bridge."
        } else {
            detail = "Enable OpenBurnBar's status line bridge to capture Claude quota updates."
        }
        claudeBridgeStatus = ClaudeQuotaBridgeStatus(
            state: configuredCommand == nil ? .notInstalled : .invalidConfiguration,
            wrapperPath: wrapperPath,
            detailText: detail,
            lastPayloadAt: snapshotDate
        )
    }
}

// MARK: - Provider Adapters

private extension ProviderQuotaService {
    func fetchSnapshot(for provider: AgentProvider, dataStore: DataStore) async throws -> ProviderQuotaSnapshot {
        switch provider {
        case .codex:
            return try await fetchCodexSnapshot()
        case .claudeCode:
            return try fetchClaudeSnapshot(dataStore: dataStore)
        case .minimax:
            return try await fetchMiniMaxSnapshot()
        case .zai:
            return try await fetchZaiSnapshot()
        case .factory:
            return await fetchFactorySnapshot(dataStore: dataStore)
        case .cursor:
            return try await fetchCursorSnapshot()
        default:
            return unavailableSnapshot(
                for: provider,
                source: .unavailable,
                message: "Quota reporting is not implemented for \(provider.displayName)."
            )
        }
    }

    func fetchCodexSnapshot() async throws -> ProviderQuotaSnapshot {
        let candidateDirectories = [
            homeDirectoryURL.appendingPathComponent(".codex/sessions", isDirectory: true),
            homeDirectoryURL.appendingPathComponent(".codex/archived_sessions", isDirectory: true),
        ]

        let freshnessCutoff = Date().addingTimeInterval(-CodexQuotaScanPolicy.freshnessWindow)
        let existingCache = codexRolloutScanCache
        let scanResult = try await Task.detached(priority: .utility) {
            try Self.scanCodexRateLimitEvents(
                in: candidateDirectories,
                freshnessCutoff: freshnessCutoff,
                existingCache: existingCache
            )
        }.value
        codexRolloutScanCache = scanResult.cache
        if scanResult.didChangeCache {
            persistCodexRolloutScanCache()
        }

        if let event = scanResult.latestEvent {
            let normalizedWindows = normalizedCodexRateLimitWindows(
                primary: event.primary,
                secondary: event.secondary
            )
            var buckets: [ProviderQuotaBucket] = []
            if let primary = normalizedWindows.primary {
                buckets.append(
                    ProviderQuotaBucket(
                        key: "codex-primary",
                        label: codexBucketLabel(for: primary, fallback: "Primary quota"),
                        windowKind: codexWindowKind(for: primary),
                        usedValue: primary.usedPercent,
                        limitValue: 100,
                        remainingValue: max(0, 100 - (primary.usedPercent ?? 0)),
                        usedPercent: primary.usedPercent,
                        resetsAt: primary.resetsAt,
                        unit: .percent,
                        isEstimated: false
                    )
                )
            }
            if let secondary = normalizedWindows.secondary {
                buckets.append(
                    ProviderQuotaBucket(
                        key: "codex-secondary",
                        label: codexBucketLabel(for: secondary, fallback: "Secondary quota"),
                        windowKind: codexWindowKind(for: secondary),
                        usedValue: secondary.usedPercent,
                        limitValue: 100,
                        remainingValue: max(0, 100 - (secondary.usedPercent ?? 0)),
                        usedPercent: secondary.usedPercent,
                        resetsAt: secondary.resetsAt,
                        unit: .percent,
                        isEstimated: false
                    )
                )
            }

            if !buckets.isEmpty {
                let plan = event.planType?.capitalized ?? "Codex"
                return ProviderQuotaSnapshot(
                    provider: .codex,
                    fetchedAt: event.timestamp,
                    source: .localSession,
                    confidence: .exact,
                    managementURL: "https://help.openai.com/en/articles/11369540-using-codex-with-your-chatgpt-plan",
                    statusMessage: "\(plan) quota snapshot from the latest local Codex rollout log.",
                    buckets: buckets
                )
            }
        }

        return unavailableSnapshot(
            for: .codex,
            source: .unavailable,
            message: "No recent Codex rate-limit snapshot was found in local sessions. Run Codex and use /status to refresh local quota data."
        )
    }

    func fetchClaudeSnapshot(dataStore: DataStore) throws -> ProviderQuotaSnapshot {
        refreshClaudeBridgeStatus()

        // Try the status line bridge first (CLI-only, exact data)
        if claudeBridgeStatus.state == .ready,
           let payload = try? readJSONObject(from: appPaths.claudeStatuslineSnapshotURL),
           let rateLimits = payload["rate_limits"] as? [String: Any] {
            let buckets = claudeQuotaBuckets(from: rateLimits)
            if !buckets.isEmpty {
                let statusMessage: String
                if claudeAPIBillingOverrideDetected() {
                    statusMessage = "Quota captured from Claude Code's local status line JSON bridge while API billing is also configured for this app process."
                } else {
                    statusMessage = "Quota captured from Claude Code's local status line JSON bridge."
                }
                return ProviderQuotaSnapshot(
                    provider: .claudeCode,
                    fetchedAt: claudeBridgeStatus.lastPayloadAt ?? Date(),
                    source: .localCLI,
                    confidence: .exact,
                    managementURL: "https://code.claude.com/docs/en/statusline",
                    statusMessage: statusMessage,
                    buckets: buckets
                )
            }
        }

        if claudeAPIBillingOverrideDetected() {
            return unavailableSnapshot(
                for: .claudeCode,
                source: .unavailable,
                message: "ANTHROPIC_API_KEY is set for this app process. Claude Code may be using API billing instead of a Claude plan, so OpenBurnBar will only report exact local CLI quota snapshots."
            )
        }

        // Fallback: estimate from OpenBurnBar-tracked token usage (works for VS Code too)
        let tokenEstimate = claudeTokenEstimate(dataStore: dataStore)
        if !tokenEstimate.isEmpty {
            return ProviderQuotaSnapshot(
                provider: .claudeCode,
                fetchedAt: Date(),
                source: .localSession,
                confidence: .estimated,
                managementURL: nil,
                statusMessage: "Estimated from OpenBurnBar session token tracking. Install the CLI bridge for exact rate-limit data.",
                buckets: tokenEstimate
            )
        }

        // No data at all
        let message: String
        switch claudeBridgeStatus.state {
        case .notInstalled, .invalidConfiguration:
            message = claudeBridgeStatus.detailText
        case .disabledByHooks:
            message = claudeBridgeStatus.detailText
        case .awaitingFirstPayload:
            message = claudeBridgeStatus.detailText
        case .ready:
            message = "Bridge installed but no rate-limit payload captured yet."
        }
        return unavailableSnapshot(for: .claudeCode, source: .localCLI, message: message)
    }

    /// Estimate Claude Code quota from OpenBurnBar-tracked token usage in the 5-hour and 7-day windows.
    private func claudeTokenEstimate(dataStore: DataStore) -> [ProviderQuotaBucket] {
        let now = Date()
        let calendar = Calendar.current
        let fiveHoursAgo = calendar.date(byAdding: .hour, value: -5, to: now) ?? now
        let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: now) ?? now

        let fiveHourUsages = dataStore.usages(for: .claudeCode, in: fiveHoursAgo...now)
        let sevenDayUsages = dataStore.usages(for: .claudeCode, in: sevenDaysAgo...now)

        let fiveHourTokens = Double(fiveHourUsages.reduce(0) { $0 + $1.totalTokens })
        let sevenDayTokens = Double(sevenDayUsages.reduce(0) { $0 + $1.totalTokens })

        guard fiveHourTokens > 0 || sevenDayTokens > 0 else { return [] }

        var buckets: [ProviderQuotaBucket] = []
        if fiveHourTokens > 0 {
            buckets.append(ProviderQuotaBucket(
                key: "claude-five-hour-estimate",
                label: "5-hour window",
                windowKind: .rollingHours,
                usedValue: fiveHourTokens,
                limitValue: nil,
                remainingValue: nil,
                usedPercent: nil,
                resetsAt: calendar.date(byAdding: .hour, value: 5, to: now),
                unit: .tokens,
                isEstimated: true
            ))
        }
        if sevenDayTokens > 0 {
            buckets.append(ProviderQuotaBucket(
                key: "claude-seven-day-estimate",
                label: "7-day window",
                windowKind: .rollingDays,
                usedValue: sevenDayTokens,
                limitValue: nil,
                remainingValue: nil,
                usedPercent: nil,
                resetsAt: calendar.date(byAdding: .day, value: 7, to: now),
                unit: .tokens,
                isEstimated: true
            ))
        }
        return buckets
    }

    func fetchMiniMaxSnapshot(apiKeyOverride: String? = nil) async throws -> ProviderQuotaSnapshot {
        guard miniMaxModeProvider() == .tokenPlan else {
            return unavailableSnapshot(
                for: .minimax,
                source: .unavailable,
                message: "MiniMax quota reporting is disabled while billing mode is set to Pay-as-you-go."
            )
        }

        guard let apiKey = nonEmpty(apiKeyOverride) ?? resolveMiniMaxAPIKey() else {
            return unavailableSnapshot(
                for: .minimax,
                source: .unavailable,
                message: "Add a MiniMax Token Plan API key to report remaining quota."
            )
        }

        if miniMaxAPIKeyKind(apiKey) == .standard {
            return unavailableSnapshot(
                for: .minimax,
                source: .officialAPI,
                message: "MiniMax quota reporting requires a Coding Plan key (`sk-cp-...`), not a standard Open Platform key (`sk-api-...`)."
            )
        }

        let url = URL(string: "https://www.minimax.io/v1/api/openplatform/coding_plan/remains")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw QuotaServiceError.invalidResponse("MiniMax returned a non-HTTP response.")
        }

        if http.statusCode == 401 || http.statusCode == 403 {
            return unavailableSnapshot(
                for: .minimax,
                source: .officialAPI,
                message: "MiniMax rejected the configured key. Token Plan quota requires a Token Plan API key, not a pay-as-you-go Open Platform key."
            )
        }
        guard (200..<300).contains(http.statusCode) else {
            throw QuotaServiceError.httpStatus(provider: .minimax, code: http.statusCode)
        }

        let object = try parseJSONObject(from: data)
        if let inlineError = miniMaxInlineErrorMessage(from: object) {
            return unavailableSnapshot(
                for: .minimax,
                source: .officialAPI,
                message: inlineError
            )
        }
        let buckets = extractFlexibleBuckets(
            from: object,
            provider: .minimax,
            endpointLabel: "minimax"
        )

        guard !buckets.isEmpty else {
            return unavailableSnapshot(
                for: .minimax,
                source: .officialAPI,
                message: "MiniMax returned a Token Plan response, but no recognizable quota buckets were found."
            )
        }

        return ProviderQuotaSnapshot(
            provider: .minimax,
            fetchedAt: Date(),
            source: .officialAPI,
            confidence: .exact,
            managementURL: "https://platform.minimax.io/docs/token-plan/faq",
            statusMessage: "Quota fetched from MiniMax Token Plan.",
            buckets: buckets
        )
    }

    func fetchZaiSnapshot(apiKeyOverride: String? = nil) async throws -> ProviderQuotaSnapshot {
        guard let apiKey = nonEmpty(apiKeyOverride) ?? resolveZaiAPIKey() else {
            return unavailableSnapshot(
                for: .zai,
                source: .unavailable,
                message: "Add a Z.ai coding-plan key to report remaining quota."
            )
        }

        let candidateBaseURLs = zaiCandidateBaseURLs()
        let queryItems = zaiUsageQueryItems()
        var lastInlineError: String?

        for baseURL in candidateBaseURLs {
            do {
                let quotaObject = try await requestJSON(
                    url: baseURL.appendingPathComponent("api/monitor/usage/quota/limit"),
                    authorizationValue: "Bearer \(apiKey)"
                )

                let buckets = extractFlexibleBuckets(
                    from: quotaObject,
                    provider: .zai,
                    endpointLabel: "zai"
                )
                guard !buckets.isEmpty else { continue }

                let modelUsageObject = try? await requestJSON(
                    url: baseURL.appendingPathComponent("api/monitor/usage/model-usage"),
                    queryItems: queryItems,
                    authorizationValue: "Bearer \(apiKey)"
                )
                let toolUsageObject = try? await requestJSON(
                    url: baseURL.appendingPathComponent("api/monitor/usage/tool-usage"),
                    queryItems: queryItems,
                    authorizationValue: "Bearer \(apiKey)"
                )
                let modelRows = modelUsageObject.map(extractRecordCount(from:)) ?? 0
                let toolRows = toolUsageObject.map(extractRecordCount(from:)) ?? 0

                return ProviderQuotaSnapshot(
                    provider: .zai,
                    fetchedAt: Date(),
                    source: .officialAPI,
                    confidence: .exact,
                    managementURL: "https://bigmodel.cn/usercenter/glm-coding/usage",
                    statusMessage: "Quota fetched from Z.ai usage monitor. Model rows: \(modelRows) · tool rows: \(toolRows).",
                    buckets: buckets
                )
            } catch let error as QuotaServiceError {
                if case let .invalidResponse(message) = error {
                    lastInlineError = message
                }
                continue
            } catch {
                continue
            }
        }

        if let lastInlineError {
            return unavailableSnapshot(
                for: .zai,
                source: .officialAPI,
                message: lastInlineError
            )
        }

        return unavailableSnapshot(
            for: .zai,
            source: .officialAPI,
            message: "Z.ai did not return a recognizable coding-plan quota payload from api.z.ai or open.bigmodel.cn."
        )
    }

    func fetchFactorySnapshot(dataStore: DataStore) async -> ProviderQuotaSnapshot {
        if let exactSnapshot = try? await fetchFactoryExactSnapshot() {
            return exactSnapshot
        }
        return fetchFactoryEstimatedSnapshot(dataStore: dataStore)
    }

    func fetchFactoryEstimatedSnapshot(dataStore: DataStore) -> ProviderQuotaSnapshot {
        let tier = factoryPlanProvider()
        guard let cap = tier.monthlyTokenCap else {
            return unavailableSnapshot(
                for: .factory,
                source: .manualEstimate,
                message: "Select a Factory / Droid plan tier to estimate monthly remaining quota."
            )
        }

        let calendar = Calendar.current
        let now = Date()
        let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
        let nextMonth = calendar.date(byAdding: .month, value: 1, to: startOfMonth) ?? now
        let monthRange = startOfMonth...nextMonth
        let used = Double(dataStore.usages(for: .factory, in: monthRange).reduce(0) { $0 + $1.totalTokens })
        let remaining = max(cap - used, 0)
        let usedPercent = cap > 0 ? (used / cap) * 100 : nil

        let bucket = ProviderQuotaBucket(
            key: "factory-monthly-estimate",
            label: "Monthly token estimate",
            windowKind: .monthly,
            usedValue: used,
            limitValue: cap,
            remainingValue: remaining,
            usedPercent: usedPercent,
            resetsAt: nextMonth,
            unit: .tokens,
            isEstimated: true
        )

        return ProviderQuotaSnapshot(
            provider: .factory,
            fetchedAt: now,
            source: .manualEstimate,
            confidence: .estimated,
            managementURL: "https://www.factory.ai/pricing",
            statusMessage: "Estimated from OpenBurnBar-tracked Factory / Droid raw tokens this month, not Factory billable tokens.",
            buckets: [bucket]
        )
    }

    func fetchCursorSnapshot() async throws -> ProviderQuotaSnapshot {
        if let cookieHeader = resolveCursorCookieHeader() {
            do {
                let usageSummary = try await fetchCursorUsageSummary(cookieHeader: cookieHeader)
                let userInfo = try await fetchCursorUserInfo(cookieHeader: cookieHeader)
                let requestUsage = try? await fetchCursorLegacyRequestUsage(
                    userID: userInfo.id,
                    cookieHeader: cookieHeader
                )
                let snapshot = makeCursorSnapshot(
                    usageSummary: usageSummary,
                    requestUsage: requestUsage
                )
                if !snapshot.buckets.isEmpty {
                    return snapshot
                }
            } catch let error as QuotaServiceError {
                if case .httpStatus(_, let code) = error, code == 401 || code == 403 {
                    return fallbackCursorEstimate(
                        message: "Cursor rejected the configured cookie header. Refresh the session cookie from cursor.com and try again."
                    )
                }
                return fallbackCursorEstimate(
                    message: error.localizedDescription
                )
            } catch {
                return fallbackCursorEstimate(
                    message: "Cursor web quota fetch failed. OpenBurnBar is showing recent routed-token estimates instead."
                )
            }
        }

        return fallbackCursorEstimate(
            message: "Add a Cursor cookie header to fetch billing-cycle quota. OpenBurnBar can still estimate routed tokens from the local connector."
        )
    }

    private func fallbackCursorEstimate(message: String) -> ProviderQuotaSnapshot {
        let cursorManager = CursorConnectorManager.shared
        let isConnected = cursorManager.config.isEnabled
        let statusMessage: String
        var buckets: [ProviderQuotaBucket] = []

        if isConnected {
            statusMessage = "\(message) Connector active · \(cursorManager.config.exposedModels.count) model(s) routed."
            let events = cursorManager.recentUsageEvents
            let totalTokens = events.reduce(0) { $0 + $1.totalTokens }

            if totalTokens > 0 {
                let bucket = ProviderQuotaBucket(
                    key: "cursor-session-estimate",
                    label: "Recent routed tokens",
                    windowKind: .rollingHours,
                    usedValue: Double(totalTokens),
                    limitValue: nil,
                    remainingValue: nil,
                    usedPercent: nil,
                    resetsAt: nil,
                    unit: .tokens,
                    isEstimated: true
                )
                buckets = [bucket]
            }
        } else {
            statusMessage = message
        }

        return ProviderQuotaSnapshot(
            provider: .cursor,
            fetchedAt: Date(),
            source: isConnected ? .localSession : .unavailable,
            confidence: isConnected ? .estimated : .unavailable,
            managementURL: "https://cursor.com/pricing",
            statusMessage: statusMessage,
            buckets: buckets
        )
    }

    private func resolveCursorCookieHeader() -> String? {
        if let environmentValue = environment["CURSOR_COOKIE_HEADER"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !environmentValue.isEmpty {
            return environmentValue
        }
        if let storedValue = keyStore.apiKey(for: "cursor_cookie")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !storedValue.isEmpty {
            return storedValue
        }
        return nil
    }

    private func fetchCursorUsageSummary(cookieHeader: String) async throws -> CursorUsageSummary {
        let url = URL(string: "https://cursor.com/api/usage-summary")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw QuotaServiceError.invalidResponse("Cursor returned a non-HTTP response for usage summary.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw QuotaServiceError.httpStatus(provider: .cursor, code: http.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(CursorUsageSummary.self, from: data)
    }

    private func fetchCursorUserInfo(cookieHeader: String) async throws -> CursorUserInfo {
        let url = URL(string: "https://cursor.com/api/auth/me")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw QuotaServiceError.invalidResponse("Cursor returned a non-HTTP response for auth.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw QuotaServiceError.httpStatus(provider: .cursor, code: http.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(CursorUserInfo.self, from: data)
    }

    private func fetchCursorLegacyRequestUsage(
        userID: String,
        cookieHeader: String
    ) async throws -> CursorLegacyUsageResponse {
        guard var components = URLComponents(string: "https://cursor.com/api/usage") else {
            throw QuotaServiceError.invalidResponse("Failed to construct Cursor usage URL")
        }
        components.queryItems = [URLQueryItem(name: "user", value: userID)]
        guard let usageURL = components.url else {
            throw QuotaServiceError.invalidResponse("Failed to construct Cursor usage URL with query")
        }
        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw QuotaServiceError.invalidResponse("Cursor returned a non-HTTP response for legacy usage.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw QuotaServiceError.httpStatus(provider: .cursor, code: http.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(CursorLegacyUsageResponse.self, from: data)
    }

    private func makeCursorSnapshot(
        usageSummary: CursorUsageSummary,
        requestUsage: CursorLegacyUsageResponse?
    ) -> ProviderQuotaSnapshot {
        let billingCycleEnd = usageSummary.billingCycleEnd.flatMap(Self.parseDateValue)
        let plan = usageSummary.individualUsage?.plan
        let onDemand = usageSummary.individualUsage?.onDemand

        let normalizedAutoPercent = normalizeCursorPercent(plan?.autoPercentUsed)
        let normalizedAPIPercent = normalizeCursorPercent(plan?.apiPercentUsed)
        let planPercentUsed = normalizeCursorPercent(plan?.totalPercentUsed)
            ?? {
                switch (normalizedAutoPercent, normalizedAPIPercent) {
                case let (auto?, api?):
                    return (auto + api) / 2
                case let (auto?, nil):
                    return auto
                case let (nil, api?):
                    return api
                case (nil, nil):
                    if let used = plan?.used, let limit = plan?.limit, limit > 0 {
                        return (Double(used) / Double(limit)) * 100
                    }
                    return nil
                }
            }()

        let requestsUsed = requestUsage?.gpt4?.numRequestsTotal ?? requestUsage?.gpt4?.numRequests
        let requestsLimit = requestUsage?.gpt4?.maxRequestUsage
        let onDemandUsedUSD = Double(onDemand?.used ?? 0) / 100
        let onDemandLimitUSD = onDemand?.limit.map { Double($0) / 100 }

        var buckets: [ProviderQuotaBucket] = []

        if let requestsLimit, requestsLimit > 0 {
            let used = Double(requestsUsed ?? 0)
            let limit = Double(requestsLimit)
            buckets.append(
                ProviderQuotaBucket(
                    key: "cursor-included-requests",
                    label: "Included requests",
                    windowKind: .monthly,
                    usedValue: used,
                    limitValue: limit,
                    remainingValue: max(limit - used, 0),
                    usedPercent: limit > 0 ? (used / limit) * 100 : nil,
                    resetsAt: billingCycleEnd,
                    unit: .requests,
                    isEstimated: false
                )
            )
        } else if let planPercentUsed {
            buckets.append(
                ProviderQuotaBucket(
                    key: "cursor-included-plan",
                    label: "Included usage",
                    windowKind: .monthly,
                    usedValue: planPercentUsed,
                    limitValue: 100,
                    remainingValue: max(0, 100 - planPercentUsed),
                    usedPercent: planPercentUsed,
                    resetsAt: billingCycleEnd,
                    unit: .percent,
                    isEstimated: false
                )
            )
        }

        if let onDemandLimitUSD, onDemandLimitUSD > 0 || onDemandUsedUSD > 0 {
            let remaining = max(onDemandLimitUSD - onDemandUsedUSD, 0)
            let usedPercent = onDemandLimitUSD > 0 ? (onDemandUsedUSD / onDemandLimitUSD) * 100 : nil
            buckets.append(
                ProviderQuotaBucket(
                    key: "cursor-on-demand",
                    label: "On-demand spend",
                    windowKind: .monthly,
                    usedValue: onDemandUsedUSD,
                    limitValue: onDemandLimitUSD,
                    remainingValue: remaining,
                    usedPercent: usedPercent,
                    resetsAt: billingCycleEnd,
                    unit: .count,
                    isEstimated: false
                )
            )
        }

        return ProviderQuotaSnapshot(
            provider: .cursor,
            fetchedAt: Date(),
            source: .officialAPI,
            confidence: .exact,
            managementURL: "https://cursor.com/pricing",
            statusMessage: usageSummary.isUnlimited == true
                ? "Cursor reports an unlimited included plan for the current billing cycle."
                : "Quota fetched from Cursor web billing for the current billing cycle.",
            buckets: buckets
        )
    }

    private func normalizeCursorPercent(_ value: Double?) -> Double? {
        guard let value else { return nil }
        return min(max(value, 0), 100)
    }
}

// MARK: - Persistence + File System

private extension ProviderQuotaService {
    func loadPersistedSnapshots() {
        guard fileManager.fileExists(atPath: appPaths.providerQuotaSnapshotsURL.path) else { return }
        do {
            let data = try Data(contentsOf: appPaths.providerQuotaSnapshotsURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let snapshots = try decoder.decode([ProviderQuotaSnapshot].self, from: data)
            snapshotsByProvider = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.provider, $0) })
            lastFetch = snapshots.map(\.fetchedAt).max()
        } catch {
            snapshotsByProvider = [:]
        }
    }

    func persistSnapshots() {
        do {
            try ensureParentDirectory(for: appPaths.providerQuotaSnapshotsURL)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(
                snapshotsByProvider.values.sorted { $0.provider.displayName < $1.provider.displayName }
            )
            try data.write(to: appPaths.providerQuotaSnapshotsURL, options: .atomic)
        } catch {
            AppLogger.dataStore.silentFailure("ProviderQuotaService: Failed to persist snapshots", error: error)
        }
    }

    func loadPersistedCodexRolloutScanCache() {
        guard fileManager.fileExists(atPath: appPaths.codexRolloutScanCacheURL.path) else { return }
        do {
            let data = try Data(contentsOf: appPaths.codexRolloutScanCacheURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            codexRolloutScanCache = try decoder.decode(CodexRolloutScanCache.self, from: data)
        } catch {
            codexRolloutScanCache = .empty
        }
    }

    func persistCodexRolloutScanCache() {
        do {
            try ensureParentDirectory(for: appPaths.codexRolloutScanCacheURL)
            var cache = codexRolloutScanCache
            cache.lastUpdatedAt = Date()
            codexRolloutScanCache = cache

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(cache)
            try data.write(to: appPaths.codexRolloutScanCacheURL, options: .atomic)
        } catch {
            AppLogger.dataStore.silentFailure("ProviderQuotaService: Failed to persist codex scan cache", error: error)
        }
    }

    func ensureParentDirectory(for url: URL) throws {
        let directory = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    func readJSONObject(from url: URL) throws -> [String: Any]? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        return object as? [String: Any]
    }

    func writeJSONObject(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    func modificationDate(for url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate
    }

    nonisolated static func findRolloutFiles(in directory: URL, fileManager: FileManager = .default) -> [URL] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        var files: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.lastPathComponent.hasPrefix("rollout-"), url.pathExtension == "jsonl" else { continue }
            files.append(url)
        }
        return files
    }
}

// MARK: - Network + Parsing

private extension ProviderQuotaService {
    struct FactorySessionCredentialEnvelope {
        let cookieHeader: String?
        let bearerToken: String?
        let sourceLabel: String
    }

    struct FactoryAuthResponseEnvelope {
        let planName: String?
        let tier: String?
        let organizationName: String?
    }

    struct FactoryUsageEnvelope {
        struct Lane {
            let userTokens: Double
            let totalAllowance: Double?
            let usedPercent: Double?
        }

        let periodEnd: Date?
        let standard: Lane
        let premium: Lane
    }

    func requestJSON(
        url: URL,
        queryItems: [URLQueryItem] = [],
        authorizationValue: String
    ) async throws -> Any {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let finalURL = components?.url else {
            throw QuotaServiceError.invalidResponse("Could not build request URL for \(url.absoluteString).")
        }

        var request = URLRequest(url: finalURL)
        request.httpMethod = "GET"
        request.setValue(authorizationValue, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("en-US,en", forHTTPHeaderField: "Accept-Language")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw QuotaServiceError.invalidResponse("Non-HTTP response for \(finalURL.absoluteString).")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw QuotaServiceError.httpStatus(provider: .zai, code: http.statusCode)
        }
        let object = try JSONSerialization.jsonObject(with: data)
        if let inlineError = zaiInlineErrorMessage(from: object) {
            throw QuotaServiceError.invalidResponse(inlineError)
        }
        return object
    }

    func parseJSONObject(from data: Data) throws -> Any {
        try JSONSerialization.jsonObject(with: data)
    }

    func extractFlexibleBuckets(from object: Any, provider: AgentProvider, endpointLabel: String) -> [ProviderQuotaBucket] {
        let unwrapped = unwrapDataEnvelope(object)
        var buckets = recurseBuckets(in: unwrapped, provider: provider, path: [endpointLabel])
        buckets.sort {
            let lhsPriority = bucketSortPriority(for: provider, bucket: $0)
            let rhsPriority = bucketSortPriority(for: provider, bucket: $1)
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
            let lhsRemaining = $0.remainingPercent ?? -1
            let rhsRemaining = $1.remainingPercent ?? -1
            if lhsRemaining == rhsRemaining {
                return $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
            }
            return lhsRemaining > rhsRemaining
        }

        var seen = Set<String>()
        return buckets.filter { bucket in
            seen.insert(bucket.key).inserted
        }
    }

    func recurseBuckets(in object: Any, provider: AgentProvider, path: [String]) -> [ProviderQuotaBucket] {
        if let dictionary = object as? [String: Any] {
            if let bucket = makeBucket(from: dictionary, provider: provider, path: path) {
                return [bucket]
            }

            var buckets: [ProviderQuotaBucket] = []
            for (key, value) in dictionary {
                buckets.append(contentsOf: recurseBuckets(in: value, provider: provider, path: path + [key]))
            }
            return buckets
        }

        if let array = object as? [Any] {
            return array.enumerated().flatMap { index, value in
                recurseBuckets(in: value, provider: provider, path: path + ["item\(index)"])
            }
        }

        return []
    }

    func makeBucket(from dictionary: [String: Any], provider: AgentProvider, path: [String]) -> ProviderQuotaBucket? {
        let usageRatio = ratio(in: dictionary, keys: [
            "usage", "usageInfo", "usage_info", "quotaUsage", "quota_usage", "quotaStatus", "quota_status", "status", "summary"
        ])
        let rawUsedPercent = number(in: dictionary, keys: [
            "used_percent", "usedPercent", "used_percentage", "usage_percent", "usagePercent", "percentage", "usedRate", "usageRate"
        ])
        // If "percentage" field exceeds 100, it's actually a raw count, not a percent
        let usedPercent: Double? = (rawUsedPercent.flatMap { $0 >= 0 && $0 <= 100 ? $0 : nil })
        var usedValue = number(in: dictionary, keys: [
            "used", "used_num", "usedNum", "currentUsage", "current_usage", "currentValue", "current_value",
            "consumed", "consumed_num", "consumedNum", "current", "requestUsed", "requestsUsed",
            "current_interval_used_count", "currentIntervalUsedCount"
        ])
        var limitValue = number(in: dictionary, keys: [
            "limit", "limit_num", "limitNum", "total", "totalLimit", "total_limit",
            "max", "maxValue", "max_value", "quota", "quotaLimit", "quota_limit",
            "usageLimit", "usage_limit", "requestLimit", "requestsLimit", "totalUsage",
            "current_interval_total_count", "currentIntervalTotalCount"
        ])
        var remainingValue = number(in: dictionary, keys: [
            "remaining", "remain", "remain_num", "remainNum", "remaining_quota", "remainingQuota",
            "quota_remain", "quotaRemain", "remainingValue", "available", "available_num", "availableNum", "left",
            "current_interval_remaining_count", "currentIntervalRemainingCount",
            "current_interval_remains_count", "currentIntervalRemainsCount"
        ])
        let resetsAt = resolvedResetDate(in: dictionary)
        let intervalStart = date(in: dictionary, keys: ["start_time", "startTime"])
        let intervalHint = string(in: dictionary, keys: [
            "window", "quota_cycle", "quotaCycle", "cycle", "period", "period_name", "periodName"
        ])
        let miniMaxRemainingUsageCount = provider == .minimax
            ? number(in: dictionary, keys: [
                "current_interval_usage_count", "currentIntervalUsageCount"
            ])
            : nil

        if provider == .minimax, remainingValue == nil {
            remainingValue = miniMaxRemainingUsageCount
        }
        if provider == .minimax, usedValue == nil, let limitValue, let miniMaxRemainingUsageCount {
            usedValue = max(limitValue - miniMaxRemainingUsageCount, 0)
        }

        if usedValue == nil {
            usedValue = usageRatio?.used
        }
        if limitValue == nil {
            limitValue = usageRatio?.limit
        }
        if usedValue == nil, let remainingValue, let limitValue {
            usedValue = max(limitValue - remainingValue, 0)
        }
        if remainingValue == nil, let usedValue, let limitValue {
            remainingValue = max(limitValue - usedValue, 0)
        }

        guard usedPercent != nil || usedValue != nil || limitValue != nil || remainingValue != nil else {
            return nil
        }

        let rawLabel = string(in: dictionary, keys: [
            "label", "title", "name",
            "model", "model_name", "modelName",
            "resource", "resource_name", "resourceName",
            "quota_name", "quotaName"
        ])
            ?? string(in: dictionary, keys: ["window", "type"])
            ?? bestPathLabel(from: path)
            ?? "quota"
        // Z.ai uses unit+number fields to distinguish quota windows
        let zaiUnit = provider == .zai ? number(in: dictionary, keys: ["unit"]) : nil
        let zaiNumber = provider == .zai ? number(in: dictionary, keys: ["number"]) : nil
        let label = normalizedBucketLabel(rawLabel, provider: provider, unit: zaiUnit, number: zaiNumber)
        let windowKind = inferWindowKind(
            from: intervalHint ?? label,
            intervalStart: intervalStart,
            resetsAt: resetsAt
        )
        let unit = inferUnit(provider: provider, label: rawLabel, dictionary: dictionary, usedPercent: usedPercent, limitValue: limitValue)
        var normalizedRemaining: Double?
        if unit == .percent, let usedPercent {
            // When we have a reliable used-percent, compute remaining from it.
            // Raw "remaining" fields from APIs are often counts, not percentages.
            normalizedRemaining = max(0, 100 - usedPercent)
        } else if let usedPercent {
            normalizedRemaining = max(0, 100 - usedPercent)
        } else if let remainingValue {
            normalizedRemaining = remainingValue
        } else if let usedValue, let limitValue {
            normalizedRemaining = max(limitValue - usedValue, 0)
        } else {
            normalizedRemaining = nil
        }
        // Clamp percent-unit remaining so raw API counts never leak as "3896%"
        if unit == .percent, let nr = normalizedRemaining {
            normalizedRemaining = min(max(nr, 0), 100)
        }

        return ProviderQuotaBucket(
            key: "\(provider.rawValue.lowercased())-\(sanitizeKey(label))-\(sanitizeKey(bestPathLabel(from: path) ?? rawLabel))",
            label: label,
            windowKind: windowKind,
            usedValue: usedPercent != nil && unit == .percent ? usedPercent : usedValue,
            limitValue: unit == .percent ? 100 : limitValue,
            remainingValue: normalizedRemaining,
            usedPercent: usedPercent ?? inferPercent(usedValue: usedValue, limitValue: limitValue),
            resetsAt: resetsAt,
            unit: unit,
            isEstimated: false
        )
    }

    func fetchFactoryExactSnapshot() async throws -> ProviderQuotaSnapshot {
        guard let credentials = loadFactoryCredentials() else {
            throw QuotaServiceError.invalidResponse("No reusable Factory session was found.")
        }

        let baseURL = URL(
            string: nonEmpty(environment["FACTORY_BASE_URL"])
                ?? "https://api.factory.ai"
        ) ?? URL(string: "https://api.factory.ai")!

        let auth = try await fetchFactoryAuth(
            credentials: credentials,
            baseURL: baseURL
        )
        let usage = try await fetchFactoryUsage(
            credentials: credentials,
            baseURL: baseURL
        )

        let buckets = [
            makeFactoryBucket(
                key: "factory-standard",
                label: "Standard tokens",
                lane: usage.standard,
                resetsAt: usage.periodEnd
            ),
            makeFactoryBucket(
                key: "factory-premium",
                label: "Premium tokens",
                lane: usage.premium,
                resetsAt: usage.periodEnd
            )
        ].compactMap { $0 }

        guard !buckets.isEmpty else {
            throw QuotaServiceError.invalidResponse("Factory returned usage data without recognizable token lanes.")
        }

        let planParts = [auth.tier, auth.planName]
            .compactMap { nonEmpty($0) }
            .joined(separator: " · ")
        let authSummary = planParts.isEmpty ? credentials.sourceLabel : "\(credentials.sourceLabel) · \(planParts)"

        return ProviderQuotaSnapshot(
            provider: .factory,
            fetchedAt: Date(),
            source: .officialAPI,
            confidence: .exact,
            managementURL: "https://app.factory.ai",
            statusMessage: "Factory quota fetched from subscription usage API via \(authSummary).",
            buckets: buckets
        )
    }

    func loadFactoryCredentials() -> FactorySessionCredentialEnvelope? {
        let envCookie = nonEmpty(environment["FACTORY_COOKIE_HEADER"])
        let envBearer = nonEmpty(environment["FACTORY_BEARER_TOKEN"])
        if envCookie != nil || envBearer != nil {
            return FactorySessionCredentialEnvelope(
                cookieHeader: envCookie,
                bearerToken: envBearer ?? factoryBearerToken(fromCookieHeader: envCookie),
                sourceLabel: "environment override"
            )
        }
        return nil
    }

    func fetchFactoryAuth(
        credentials: FactorySessionCredentialEnvelope,
        baseURL: URL
    ) async throws -> FactoryAuthResponseEnvelope {
        let url = baseURL.appendingPathComponent("/api/app/auth/me")
        let data = try await performFactoryRequest(
            url: url,
            method: "GET",
            credentials: credentials
        )
        let json = try parseJSONObject(from: data)
        let object = unwrapDataEnvelope(json)
        guard let dictionary = object as? [String: Any] else {
            throw QuotaServiceError.invalidResponse("Factory auth payload was not a JSON object.")
        }

        let organization = dictionary["organization"] as? [String: Any]
        let subscription = organization?["subscription"] as? [String: Any]
        let orbSubscription = subscription?["orbSubscription"] as? [String: Any]
        let plan = orbSubscription?["plan"] as? [String: Any]

        return FactoryAuthResponseEnvelope(
            planName: nonEmpty(plan?["name"] as? String),
            tier: nonEmpty(subscription?["factoryTier"] as? String),
            organizationName: nonEmpty(organization?["name"] as? String)
        )
    }

    func fetchFactoryUsage(
        credentials: FactorySessionCredentialEnvelope,
        baseURL: URL
    ) async throws -> FactoryUsageEnvelope {
        let url = baseURL.appendingPathComponent("/api/organization/subscription/usage")
        let body = try JSONSerialization.data(withJSONObject: ["useCache": true], options: [])
        let data = try await performFactoryRequest(
            url: url,
            method: "POST",
            credentials: credentials,
            body: body
        )
        let json = try parseJSONObject(from: data)
        let object = unwrapDataEnvelope(json)
        guard let dictionary = object as? [String: Any] else {
            throw QuotaServiceError.invalidResponse("Factory usage payload was not a JSON object.")
        }

        let usage = dictionary["usage"] as? [String: Any] ?? dictionary
        let periodEnd = date(in: usage, keys: ["endDate", "end_date"])
        let standard = factoryLane(from: usage["standard"] as? [String: Any])
        let premium = factoryLane(from: usage["premium"] as? [String: Any])

        return FactoryUsageEnvelope(
            periodEnd: periodEnd,
            standard: standard,
            premium: premium
        )
    }

    func performFactoryRequest(
        url: URL,
        method: String,
        credentials: FactorySessionCredentialEnvelope,
        body: Data? = nil
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://app.factory.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://app.factory.ai/", forHTTPHeaderField: "Referer")
        request.setValue("web-app", forHTTPHeaderField: "x-factory-client")
        if let cookieHeader = credentials.cookieHeader {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        if let bearerToken = credentials.bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw QuotaServiceError.invalidResponse("Factory returned a non-HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw QuotaServiceError.httpStatus(provider: .factory, code: http.statusCode)
        }
        return data
    }

    func factoryLane(from dictionary: [String: Any]?) -> FactoryUsageEnvelope.Lane {
        let lane = dictionary ?? [:]
        let used = number(in: lane, keys: ["userTokens", "user_tokens"]) ?? 0
        let allowance = number(in: lane, keys: ["totalAllowance", "total_allowance", "allowance"])
        let ratio = number(in: lane, keys: ["usedRatio", "used_ratio", "usageRatio", "usage_ratio"])
        let usedPercent = normalizedFactoryPercent(ratio: ratio, used: used, allowance: allowance)
        return FactoryUsageEnvelope.Lane(
            userTokens: used,
            totalAllowance: allowance,
            usedPercent: usedPercent
        )
    }

    func normalizedFactoryPercent(ratio: Double?, used: Double, allowance: Double?) -> Double? {
        if let ratio, ratio.isFinite {
            if ratio >= 0, ratio <= 1.001 {
                return min(max(ratio * 100, 0), 100)
            }
            if ratio >= 0, ratio <= 100 {
                return ratio
            }
        }
        guard let allowance, allowance > 0 else {
            return nil
        }
        return min(max((used / allowance) * 100, 0), 100)
    }

    func makeFactoryBucket(
        key: String,
        label: String,
        lane: FactoryUsageEnvelope.Lane,
        resetsAt: Date?
    ) -> ProviderQuotaBucket? {
        let hasCounts = lane.userTokens > 0 || (lane.totalAllowance ?? 0) > 0
        guard hasCounts || lane.usedPercent != nil else {
            return nil
        }

        let remainingValue = lane.totalAllowance.map { max($0 - lane.userTokens, 0) }

        return ProviderQuotaBucket(
            key: key,
            label: label,
            windowKind: .monthly,
            usedValue: lane.userTokens,
            limitValue: lane.totalAllowance,
            remainingValue: remainingValue,
            usedPercent: lane.usedPercent,
            resetsAt: resetsAt,
            unit: .tokens,
            isEstimated: false
        )
    }

    func unwrapDataEnvelope(_ object: Any) -> Any {
        guard let dictionary = object as? [String: Any] else { return object }
        if let data = dictionary["data"] {
            return data
        }
        return dictionary
    }

    func extractRecordCount(from object: Any) -> Int {
        let unwrapped = unwrapDataEnvelope(object)
        if let array = unwrapped as? [Any] {
            return array.count
        }
        if let dictionary = unwrapped as? [String: Any] {
            for key in ["items", "records", "list", "rows"] {
                if let array = dictionary[key] as? [Any] {
                    return array.count
                }
            }
        }
        return 0
    }
}

// MARK: - Provider Helpers

private extension ProviderQuotaService {
    func unavailableSnapshot(
        for provider: AgentProvider,
        source: ProviderQuotaSourceKind,
        message: String
    ) -> ProviderQuotaSnapshot {
        ProviderQuotaSnapshot(
            provider: provider,
            fetchedAt: Date(),
            source: source,
            confidence: .unavailable,
            managementURL: nil,
            statusMessage: message,
            buckets: []
        )
    }

    func resolveMiniMaxAPIKey() -> String? {
        nonEmpty(keyStore.apiKey(for: "minimax"))
            ?? cursorConnectorKey(for: "provider.minimax.apiKey")
            ?? nonEmpty(environment["MINIMAX_API_KEY"])
    }

    func resolveZaiAPIKey() -> String? {
        nonEmpty(keyStore.apiKey(for: "zai"))
            ?? cursorConnectorKey(for: "provider.zai.apiKey")
            ?? nonEmpty(environment["ZAI_API_KEY"])
            ?? nonEmpty(environment["Z_AI_API_KEY"])
    }

    func miniMaxAPIKeyKind(_ apiKey: String) -> MiniMaxAPIKeyKind {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("sk-cp-") {
            return .codingPlan
        }
        if trimmed.hasPrefix("sk-api-") {
            return .standard
        }
        return .unknown
    }

    func claudeAPIBillingOverrideDetected() -> Bool {
        nonEmpty(environment["ANTHROPIC_API_KEY"]) != nil
    }

    func miniMaxInlineErrorMessage(from object: Any) -> String? {
        guard let dictionary = unwrapDataEnvelope(object) as? [String: Any] else { return nil }
        let baseResponse = (dictionary["base_resp"] as? [String: Any]) ?? dictionary

        if let statusCode = number(in: baseResponse, keys: ["status_code", "statusCode", "code"]),
           Int(statusCode.rounded()) != 0,
           Int(statusCode.rounded()) != 200 {
            let message = string(in: baseResponse, keys: ["status_msg", "statusMsg", "message", "msg", "error"])
                ?? "code \(Int(statusCode.rounded()))"
            return "MiniMax returned an API error: \(message)"
        }

        if let success = baseResponse["success"] as? Bool, !success {
            let message = string(in: baseResponse, keys: ["status_msg", "statusMsg", "message", "msg", "error"])
                ?? "request unsuccessful"
            return "MiniMax returned an API error: \(message)"
        }

        return nil
    }

    func resolvedResetDate(in dictionary: [String: Any], now: Date = Date()) -> Date? {
        if let explicitReset = date(in: dictionary, keys: [
            "resets_at", "reset_at", "resetTime", "reset_time", "nextResetAt", "next_reset_at", "next_reset_time",
            "expireAt", "expiresAt", "end_time", "endTime"
        ]) {
            return explicitReset
        }

        if let milliseconds = number(in: dictionary, keys: ["remains_time", "remainsTime"]), milliseconds > 0 {
            return now.addingTimeInterval(milliseconds / 1000)
        }

        guard let seconds = number(in: dictionary, keys: ["remaining_time", "remainingTime"]), seconds > 0 else {
            return nil
        }
        guard seconds > 0 else { return nil }
        return now.addingTimeInterval(seconds)
    }

    func inferWindowKind(
        from label: String,
        intervalStart: Date? = nil,
        resetsAt: Date? = nil
    ) -> ProviderQuotaWindowKind {
        let lowercased = label.lowercased()
        if lowercased.contains("5hour") || lowercased.contains("5-hour") || lowercased.contains("five") {
            return .rollingHours
        }
        if lowercased.contains("7day") || lowercased.contains("7-day") || lowercased.contains("seven") {
            return .rollingDays
        }
        if lowercased.contains("day") {
            return .daily
        }
        if lowercased.contains("week") {
            return .weekly
        }
        if lowercased.contains("month") {
            return .monthly
        }
        if let intervalStart, let resetsAt {
            let duration = resetsAt.timeIntervalSince(intervalStart)
            switch duration {
            case 0..<(18 * 60 * 60):
                return .rollingHours
            case 18 * 60 * 60..<(36 * 60 * 60):
                return .daily
            case 36 * 60 * 60..<(9 * 24 * 60 * 60):
                return .weekly
            case 9 * 24 * 60 * 60...(45 * 24 * 60 * 60):
                return .monthly
            default:
                break
            }
        }
        return .custom
    }

    func inferUnit(
        provider: AgentProvider,
        label: String,
        dictionary: [String: Any],
        usedPercent: Double?,
        limitValue: Double?
    ) -> ProviderQuotaUnit {
        if usedPercent != nil {
            return .percent
        }
        let lowercased = label.lowercased()
        if lowercased.contains("token") {
            return .tokens
        }
        if lowercased.contains("request") || lowercased.contains("prompt") || lowercased.contains("usage") {
            return .requests
        }
        if provider == .zai,
           let type = string(in: dictionary, keys: ["type"])?.lowercased(),
           type.contains("time_limit") {
            return .requests
        }
        if provider == .minimax,
           number(in: dictionary, keys: ["current_interval_total_count", "currentIntervalTotalCount"]) != nil {
            return .requests
        }
        if limitValue != nil {
            return .count
        }
        return .percent
    }

    func inferPercent(usedValue: Double?, limitValue: Double?) -> Double? {
        guard let usedValue, let limitValue, limitValue > 0 else { return nil }
        return min(max((usedValue / limitValue) * 100, 0), 100)
    }

    func factoryBearerToken(fromCookieHeader header: String?) -> String? {
        guard let header else { return nil }
        for pair in header.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard parts.count == 2 else { continue }
            if parts[0] == "access-token" {
                return nonEmpty(parts[1])
            }
        }
        return nil
    }

    func sanitizeKey(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
    }

    nonisolated static func parseDateValue(_ value: Any) -> Date? {
        if let date = value as? Date {
            return date
        }
        if let number = value as? NSNumber {
            let raw = number.doubleValue
            if raw > 1_000_000_000_000 {
                return Date(timeIntervalSince1970: raw / 1000)
            }
            if raw > 1_000_000_000 {
                return Date(timeIntervalSince1970: raw)
            }
        }
        if let string = value as? String {
            if let isoDate = isoFormatter.date(from: string) {
                return isoDate
            }
            if let isoDate = isoFormatterWithoutFractionalSeconds.date(from: string) {
                return isoDate
            }
            if let numeric = Double(string), numeric > 1_000_000_000_000 {
                return Date(timeIntervalSince1970: numeric / 1000)
            }
            if let numeric = Double(string), numeric > 1_000_000_000 {
                return Date(timeIntervalSince1970: numeric)
            }
            if let date = providerQuotaZaiDateFormatter.date(from: string) {
                return date
            }
        }
        return nil
    }

    func zaiCandidateBaseURLs() -> [URL] {
        var candidates: [URL] = []
        if let explicitQuotaURL = nonEmpty(environment["Z_AI_QUOTA_URL"]),
           let url = normalizedZaiHostURL(from: explicitQuotaURL) {
            candidates.append(url)
        }
        if let configuredHost = nonEmpty(environment["Z_AI_API_HOST"]),
           let url = normalizedZaiHostURL(from: configuredHost) {
            candidates.append(url)
        }
        if let configured = environment["ZAI_BASE_URL"], let url = URL(string: configured) {
            candidates.append(url)
        }
        candidates.append(URL(string: "https://api.z.ai")!)
        candidates.append(URL(string: "https://open.bigmodel.cn")!)

        var seen = Set<String>()
        return candidates.filter { url in
            seen.insert(url.absoluteString).inserted
        }.sorted { lhs, rhs in
            lhs.absoluteString.contains("api.z.ai") && !rhs.absoluteString.contains("api.z.ai")
        }
    }

    func normalizedZaiHostURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
            components.path = ""
            components.query = nil
            components.fragment = nil
            return components.url ?? url
        }
        return normalizedZaiHostURL(from: "https://\(trimmed)")
    }

    func zaiUsageQueryItems() -> [URLQueryItem] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        let calendar = Calendar.current
        let now = Date()
        let start = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        let startWindow = calendar.date(
            bySettingHour: calendar.component(.hour, from: now),
            minute: 0,
            second: 0,
            of: start
        ) ?? start
        let endWindow = calendar.date(
            bySettingHour: calendar.component(.hour, from: now),
            minute: 59,
            second: 59,
            of: now
        ) ?? now

        return [
            URLQueryItem(name: "startTime", value: formatter.string(from: startWindow)),
            URLQueryItem(name: "endTime", value: formatter.string(from: endWindow)),
        ]
    }

    func zaiInlineErrorMessage(from object: Any) -> String? {
        guard let dictionary = object as? [String: Any] else { return nil }

        if let success = dictionary["success"] as? Bool, !success {
            let message = string(in: dictionary, keys: ["msg", "message", "error"])
                ?? "Z.ai monitor returned an unsuccessful response."
            return "Z.ai monitor returned an inline error: \(message)"
        }

        if let code = number(in: dictionary, keys: ["code", "status"]),
           code != 0, code != 200 {
            let message = string(in: dictionary, keys: ["msg", "message", "error"])
                ?? "code \(Int(code.rounded()))"
            if Int(code.rounded()) == 401 || Int(code.rounded()) == 1001 {
                return "Z.ai monitor rejected the configured key: \(message)"
            }
            return "Z.ai monitor returned an inline error: \(message)"
        }

        if let code = string(in: dictionary, keys: ["code", "status"]),
           let parsed = Double(code),
           parsed != 0, parsed != 200 {
            let message = string(in: dictionary, keys: ["msg", "message", "error"]) ?? code
            if Int(parsed.rounded()) == 401 || Int(parsed.rounded()) == 1001 {
                return "Z.ai monitor rejected the configured key: \(message)"
            }
            return "Z.ai monitor returned an inline error: \(message)"
        }

        return nil
    }

    func cursorConnectorKey(for account: String) -> String? {
        let keychain = KeychainStore()
        let raw = try? keychain.string(for: account, allowUserInteraction: false)
        return nonEmpty(raw ?? nil)
    }

    func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    func command(fromStatusLine value: Any?) -> String? {
        guard let dictionary = value as? [String: Any] else { return nil }
        guard (dictionary["type"] as? String)?.lowercased() == "command" else { return nil }
        return dictionary["command"] as? String
    }

    func writeClaudeBridgeWrapper(to url: URL, snapshotPath: String, metadataPath: String) throws {
        let script = """
        #!/bin/sh
        set -eu

        SNAPSHOT_PATH='\(snapshotPath)'
        METADATA_PATH='\(metadataPath)'
        TMP_FILE="$(mktemp "${TMPDIR:-/tmp}/openburnbar-claude-statusline.XXXXXX")"
        trap 'rm -f "$TMP_FILE"' EXIT

        cat > "$TMP_FILE"
        cp "$TMP_FILE" "$SNAPSHOT_PATH"

        ORIGINAL_COMMAND=""
        if [ -f "$METADATA_PATH" ]; then
          ORIGINAL_COMMAND="$(/usr/bin/python3 - "$METADATA_PATH" <<'PY'
        import json
        import sys

        try:
            with open(sys.argv[1], 'r', encoding='utf-8') as fh:
                payload = json.load(fh)
            command = payload.get('originalCommand') or ''
            if isinstance(command, str):
                print(command)
        except Exception:
            pass
        PY
        )"
        fi

        if [ -n "$ORIGINAL_COMMAND" ]; then
          /bin/sh -lc "$ORIGINAL_COMMAND" < "$TMP_FILE"
        fi
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    nonisolated static func scanCodexRateLimitEvents(
        in candidateDirectories: [URL],
        freshnessCutoff: Date,
        existingCache: CodexRolloutScanCache
    ) throws -> CodexRateLimitScanResult {
        let fileManager = FileManager.default
        var updatedCache = existingCache
        var didChangeCache = false

        let files = candidateDirectories
            .flatMap { findRolloutFiles(in: $0, fileManager: fileManager) }
            .compactMap { file -> (URL, CodexRolloutFileSignature)? in
                guard let signature = fileSignature(for: file) else { return nil }
                return (file, signature)
            }
            .sorted { lhs, rhs in
                lhs.1.modifiedAt > rhs.1.modifiedAt
            }

        let activePaths = Set(files.map { $0.0.standardizedFileURL.path })

        for (file, signature) in files {
            let path = file.standardizedFileURL.path
            if let cachedEntry = updatedCache.fileEntries[path], cachedEntry.signature == signature {
                continue
            }

            let event = try? lastCodexRateLimitEvent(in: file)
            updatedCache.fileEntries[path] = CodexRolloutFileCacheEntry(
                signature: signature,
                latestRateLimitEvent: event
            )
            didChangeCache = true
        }

        let stalePaths = Set(updatedCache.fileEntries.keys).subtracting(activePaths)
        if !stalePaths.isEmpty {
            for stalePath in stalePaths {
                updatedCache.fileEntries.removeValue(forKey: stalePath)
            }
            didChangeCache = true
        }

        let latestEvent = updatedCache.fileEntries.values
            .compactMap(\.latestRateLimitEvent)
            .filter { $0.timestamp >= freshnessCutoff }
            .max { lhs, rhs in
                lhs.timestamp < rhs.timestamp
            }
        if updatedCache.latestRateLimitEvent != latestEvent {
            updatedCache.latestRateLimitEvent = latestEvent
            didChangeCache = true
        }

        return CodexRateLimitScanResult(
            latestEvent: latestEvent,
            cache: updatedCache,
            didChangeCache: didChangeCache
        )
    }

    nonisolated static func lastCodexRateLimitEvent(in file: URL) throws -> CodexRateLimitEvent? {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        let size = try handle.seekToEnd()
        let bytesToRead = min(UInt64(CodexQuotaScanPolicy.tailReadBytes), size)
        let startOffset = size - bytesToRead

        try handle.seek(toOffset: startOffset)
        guard let data = try handle.readToEnd(), !data.isEmpty else { return nil }
        guard let contents = String(data: data, encoding: .utf8) else { return nil }

        var lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
        if startOffset > 0, !lines.isEmpty {
            // Skip potentially truncated first line when reading from a file tail offset.
            lines.removeFirst()
        }
        if lines.count > CodexQuotaScanPolicy.maxTailLines {
            lines = Array(lines.suffix(CodexQuotaScanPolicy.maxTailLines))
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for line in lines.reversed() {
            let lineData = Data(line.utf8)
            guard let event = try? decoder.decode(CodexRolloutEnvelope.self, from: lineData) else { continue }
            guard event.type == "event_msg",
                  event.payload.type == "token_count",
                  event.payload.rateLimits.primary != nil || event.payload.rateLimits.secondary != nil else {
                continue
            }

            return CodexRateLimitEvent(
                timestamp: event.timestamp,
                planType: event.payload.rateLimits.planType,
                primary: event.payload.rateLimits.primary.map {
                    CodexRateLimitWindow(
                        usedPercent: $0.usedPercent,
                        windowMinutes: $0.windowMinutes,
                        resetsAt: $0.resetsAt
                    )
                },
                secondary: event.payload.rateLimits.secondary.map {
                    CodexRateLimitWindow(
                        usedPercent: $0.usedPercent,
                        windowMinutes: $0.windowMinutes,
                        resetsAt: $0.resetsAt
                    )
                }
            )
        }
        return nil
    }

    nonisolated static func fileSignature(for url: URL) -> CodexRolloutFileSignature? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
        guard values?.isRegularFile == true else { return nil }
        guard let modifiedAt = values?.contentModificationDate else { return nil }
        return CodexRolloutFileSignature(
            modifiedAt: modifiedAt.timeIntervalSince1970,
            sizeBytes: Int64(values?.fileSize ?? 0)
        )
    }

    func remainingPercent(from dictionary: [String: Any]) -> Double? {
        guard let used = number(in: dictionary, keys: ["used_percentage", "usedPercent", "percentage"]) else {
            return nil
        }
        return max(0, 100 - used)
    }

    func claudeQuotaBuckets(from rateLimits: [String: Any]) -> [ProviderQuotaBucket] {
        let candidates: [(String, String, ProviderQuotaWindowKind)] = [
            ("five_hour", "5-hour window", .rollingHours),
            ("seven_day", "7-day window", .rollingDays),
            ("seven_day_sonnet", "7-day Sonnet window", .rollingDays),
            ("seven_day_opus", "7-day Opus window", .rollingDays),
            ("seven_day_oauth_apps", "7-day OAuth Apps window", .rollingDays),
        ]

        return candidates.compactMap { key, label, windowKind in
            guard let payload = rateLimits[key] as? [String: Any] else { return nil }
            let usedPercent = number(in: payload, keys: ["used_percentage", "usedPercent", "percentage"])
            guard usedPercent != nil || remainingPercent(from: payload) != nil else { return nil }
            return ProviderQuotaBucket(
                key: "claude-\(sanitizeKey(key))",
                label: label,
                windowKind: windowKind,
                usedValue: usedPercent,
                limitValue: 100,
                remainingValue: remainingPercent(from: payload),
                usedPercent: usedPercent,
                resetsAt: date(in: payload, keys: ["resets_at", "reset_at", "resetTime"]),
                unit: .percent,
                isEstimated: false
            )
        }
    }

    func number(in dictionary: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = value(in: dictionary, matching: key) {
                if let number = value as? NSNumber {
                    return number.doubleValue
                }
                if let string = value as? String, let parsed = parseNumericValue(from: string) {
                    return parsed
                }
            }
        }
        return nil
    }

    func string(in dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = value(in: dictionary, matching: key) as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    func date(in dictionary: [String: Any], keys: [String]) -> Date? {
        for key in keys {
            guard let value = value(in: dictionary, matching: key) else { continue }
            if let date = Self.parseDateValue(value) {
                return date
            }
        }
        return nil
    }

    func value(in dictionary: [String: Any], matching requestedKey: String) -> Any? {
        let normalizedRequested = normalizeJSONKey(requestedKey)
        var bestMatch: (score: Int, value: Any)?
        let allowAffixFuzzyMatch = normalizedRequested.count >= 8
        let allowContainFuzzyMatch = normalizedRequested.count >= 12
        let requestLooksTemporal = keyLooksTemporal(normalizedRequested)

        for (key, value) in dictionary {
            let normalizedKey = normalizeJSONKey(key)
            let keyLooksTemporal = keyLooksTemporal(normalizedKey)
            let score: Int
            if normalizedKey == normalizedRequested {
                score = 3
            } else if allowAffixFuzzyMatch,
                      keyLooksTemporal == requestLooksTemporal,
                      (normalizedKey.hasSuffix(normalizedRequested) || normalizedKey.hasPrefix(normalizedRequested)) {
                score = 2
            } else if allowContainFuzzyMatch,
                      keyLooksTemporal == requestLooksTemporal,
                      normalizedKey.contains(normalizedRequested) {
                score = 1
            } else {
                continue
            }

            if score > (bestMatch?.score ?? -1) {
                bestMatch = (score, value)
            }
        }

        return bestMatch?.value
    }

    func normalizeJSONKey(_ key: String) -> String {
        key.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")
    }

    func keyLooksTemporal(_ key: String) -> Bool {
        key.hasSuffix("time")
            || key.hasSuffix("at")
            || key.contains("reset")
            || key.contains("expire")
            || key.contains("window")
            || key.contains("period")
    }

    func ratio(in dictionary: [String: Any], keys: [String]) -> (used: Double, limit: Double)? {
        for key in keys {
            guard let value = value(in: dictionary, matching: key) else { continue }
            if let string = value as? String, let parsed = parseRatioValues(from: string) {
                return parsed
            }
            if let array = value as? [Any], array.count >= 2,
               let first = array[0] as? NSNumber,
               let second = array[1] as? NSNumber {
                return (first.doubleValue, second.doubleValue)
            }
        }
        return nil
    }

    func parseNumericValue(from string: String) -> Double? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.contains("/") else { return nil }

        let normalized = trimmed.replacingOccurrences(of: ",", with: "")
        if let direct = Double(normalized) {
            return direct
        }

        let pattern = #"[-+]?\d*\.?\d+"#
        guard let range = normalized.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        return Double(String(normalized[range]))
    }

    func parseRatioValues(from string: String) -> (used: Double, limit: Double)? {
        let normalized = string.replacingOccurrences(of: ",", with: "")
        let slashParts = normalized.split(separator: "/")
        if slashParts.count == 2,
           let used = parseNumericValue(from: String(slashParts[0])),
           let limit = parseNumericValue(from: String(slashParts[1])) {
            return (used, limit)
        }

        if normalized.localizedCaseInsensitiveContains(" of ")
            || normalized.localizedCaseInsensitiveContains(" out of ") {
            let matches = normalized
                .components(separatedBy: CharacterSet(charactersIn: "0123456789.-").inverted)
                .filter { !$0.isEmpty }
            if matches.count >= 2,
               let used = Double(matches[0]),
               let limit = Double(matches[1]) {
                return (used, limit)
            }
        }

        return nil
    }

    func bestPathLabel(from path: [String]) -> String? {
        path.reversed().first { component in
            let normalized = normalizeJSONKey(component)
            return !component.hasPrefix("item")
                && normalized != "data"
                && normalized != "minimax"
                && normalized != "zai"
                && normalized != "baseresp"
                && normalized != "quotalist"
                && normalized != "modelremains"
                && normalized != "resourceremains"
        }
    }

    func normalizedBucketLabel(_ label: String, provider: AgentProvider, unit: Double? = nil, number: Double? = nil) -> String {
        let lowercased = label.lowercased()
        if provider == .zai {
            if lowercased.contains("tokens_limit") {
                // Z.ai API uses unit+number to distinguish windows:
                //   unit=3, number=5 → 5-hour rolling token quota
                //   unit=6, number=1 → weekly token quota
                if let unit, let number {
                    if Int(unit) == 6 && Int(number) == 1 {
                        return "Token usage (Weekly)"
                    }
                    if Int(unit) == 3 && Int(number) == 5 {
                        return "Token usage (5-hour)"
                    }
                }
                // Fallback if unit/number not available
                return "Token usage (5-hour)"
            }
            if lowercased.contains("time_limit") {
                return "MCP usage (1 month)"
            }
        }
        if lowercased.contains("five") || lowercased.contains("5hour") || lowercased.contains("5-hour") {
            return "5-hour window"
        }
        if lowercased.contains("seven") || lowercased.contains("7day") || lowercased.contains("7-day") || lowercased.contains("week") {
            return "7-day window"
        }
        if lowercased.contains("day") {
            return "Daily quota"
        }
        if lowercased.contains("month") {
            return "Monthly quota"
        }
        return label
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }

    func bucketSortPriority(for provider: AgentProvider, bucket: ProviderQuotaBucket) -> Int {
        guard provider == .zai else { return 0 }
        let lowercased = bucket.label.lowercased()
        if lowercased.contains("5-hour") || lowercased.contains("5hour") {
            // 5h token window is the most urgent
            return 0
        }
        if lowercased.contains("token") || lowercased.contains("api") {
            // Weekly or other token windows
            return 1
        }
        if lowercased.contains("mcp") || lowercased.contains("tool") || lowercased.contains("time_limit") || lowercased.contains("time limit") {
            return 2
        }
        if lowercased == "limits" || lowercased == "limit" {
            return 3
        }
        return 1
    }

    nonisolated(unsafe) static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) static let isoFormatterWithoutFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    enum CodexWindowRole {
        case session
        case weekly
        case unknown
    }

    func normalizedCodexRateLimitWindows(
        primary: CodexRateLimitWindow?,
        secondary: CodexRateLimitWindow?
    ) -> (primary: CodexRateLimitWindow?, secondary: CodexRateLimitWindow?) {
        switch (primary, secondary) {
        case let (.some(primaryWindow), .some(secondaryWindow)):
            switch (codexWindowRole(for: primaryWindow), codexWindowRole(for: secondaryWindow)) {
            case (.session, .weekly), (.session, .unknown), (.unknown, .weekly):
                return (primaryWindow, secondaryWindow)
            case (.weekly, .session), (.weekly, .unknown):
                return (secondaryWindow, primaryWindow)
            default:
                return (primaryWindow, secondaryWindow)
            }
        case let (.some(primaryWindow), .none):
            switch codexWindowRole(for: primaryWindow) {
            case .weekly:
                return (nil, primaryWindow)
            case .session, .unknown:
                return (primaryWindow, nil)
            }
        case let (.none, .some(secondaryWindow)):
            switch codexWindowRole(for: secondaryWindow) {
            case .weekly:
                return (nil, secondaryWindow)
            case .session, .unknown:
                return (secondaryWindow, nil)
            }
        case (.none, .none):
            return (nil, nil)
        }
    }

    func codexWindowRole(for window: CodexRateLimitWindow) -> CodexWindowRole {
        switch window.windowMinutes {
        case 300:
            return .session
        case 10_080:
            return .weekly
        default:
            return .unknown
        }
    }

    func codexWindowKind(for window: CodexRateLimitWindow) -> ProviderQuotaWindowKind {
        switch codexWindowRole(for: window) {
        case .session:
            return .rollingHours
        case .weekly:
            return .rollingDays
        case .unknown:
            return .custom
        }
    }

    func codexBucketLabel(for window: CodexRateLimitWindow, fallback: String) -> String {
        switch codexWindowRole(for: window) {
        case .session:
            return "5-hour window"
        case .weekly:
            return "7-day window"
        case .unknown:
            if let minutes = window.windowMinutes, minutes > 0 {
                if minutes % 60 == 0 {
                    return "\(minutes / 60)-hour window"
                }
                return "\(minutes)-minute window"
            }
            return fallback
        }
    }
}

// MARK: - Errors

#if false
private enum QuotaServiceError: LocalizedError {
    case httpStatus(provider: AgentProvider, code: Int)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case let .httpStatus(provider, code):
            return "\(provider.displayName) quota request failed with HTTP \(code)."
        case let .invalidResponse(message):
            return message
        }
    }
}

private struct CursorUsageSummary: Decodable {
    let billingCycleEnd: String?
    let isUnlimited: Bool?
    let individualUsage: CursorIndividualUsage?
}

private struct CursorIndividualUsage: Decodable {
    let plan: CursorPlanUsage?
    let onDemand: CursorOnDemandUsage?
}

private struct CursorPlanUsage: Decodable {
    let used: Int?
    let limit: Int?
    let autoPercentUsed: Double?
    let apiPercentUsed: Double?
    let totalPercentUsed: Double?
}

private struct CursorOnDemandUsage: Decodable {
    let used: Int?
    let limit: Int?
}

private struct CursorUserInfo: Decodable {
    let id: String
}

private struct CursorLegacyUsageResponse: Decodable {
    let gpt4: CursorLegacyRequestUsage?
}

private struct CursorLegacyRequestUsage: Decodable {
    let numRequests: Int?
    let numRequestsTotal: Int?
    let maxRequestUsage: Int?
}
#endif
