import Foundation

// MARK: - Quota Domain

enum ProviderQuotaSourceKind: String, Codable, CaseIterable {
    case officialAPI
    case localCLI
    case localSession
    case manualEstimate
    case unavailable

    var label: String {
        switch self {
        case .officialAPI: return "Official API"
        case .localCLI: return "Local CLI"
        case .localSession: return "Local session"
        case .manualEstimate: return "Estimated"
        case .unavailable: return "Unavailable"
        }
    }
}

enum ProviderQuotaConfidence: String, Codable {
    case exact
    case estimated
    case unavailable

    var label: String {
        switch self {
        case .exact: return "Exact"
        case .estimated: return "Estimated"
        case .unavailable: return "Unavailable"
        }
    }
}

enum ProviderQuotaUnit: String, Codable {
    case percent
    case requests
    case tokens
    case count

    var shortLabel: String {
        switch self {
        case .percent: return "%"
        case .requests: return "req"
        case .tokens: return "tok"
        case .count: return ""
        }
    }
}

enum ProviderQuotaWindowKind: String, Codable {
    case rollingHours
    case rollingDays
    case daily
    case weekly
    case monthly
    case custom
}

struct ProviderQuotaBucket: Codable, Hashable, Identifiable {
    let key: String
    let label: String
    let windowKind: ProviderQuotaWindowKind
    let usedValue: Double?
    let limitValue: Double?
    let remainingValue: Double?
    let usedPercent: Double?
    let resetsAt: Date?
    let unit: ProviderQuotaUnit
    let isEstimated: Bool

    var id: String { key }

    var remainingPercent: Double? {
        if let remainingValue, unit == .percent {
            return remainingValue
        }
        if let usedPercent {
            return max(0, 100 - usedPercent)
        }
        if let remainingValue, let limitValue, limitValue > 0 {
            return (remainingValue / limitValue) * 100
        }
        return nil
    }

    var progressFraction: Double {
        if let usedPercent {
            return min(max(usedPercent / 100, 0), 1)
        }
        if let usedValue, let limitValue, limitValue > 0 {
            return min(max(usedValue / limitValue, 0), 1)
        }
        if let remainingPercent {
            return min(max((100 - remainingPercent) / 100, 0), 1)
        }
        return 0
    }

    var remainingText: String {
        if let remainingPercent {
            return Self.format(remainingPercent, unit: .percent)
        }
        if let remainingValue {
            return Self.format(remainingValue, unit: unit)
        }
        return "Unavailable"
    }

    var usageText: String {
        if let usedValue, let limitValue {
            return "\(Self.format(usedValue, unit: unit)) / \(Self.format(limitValue, unit: unit))"
        }
        if let usedPercent {
            return "\(Self.format(usedPercent, unit: .percent)) used"
        }
        return "No usage detail"
    }

    private static func format(_ value: Double, unit: ProviderQuotaUnit) -> String {
        switch unit {
        case .percent:
            return "\(Int(value.rounded()))%"
        case .tokens:
            if value >= 1_000_000 {
                return String(format: "%.1fM", value / 1_000_000)
            }
            if value >= 1_000 {
                return String(format: "%.1fK", value / 1_000)
            }
            return "\(Int(value.rounded()))"
        case .requests, .count:
            if value >= 1_000 {
                return String(format: "%.1fK", value / 1_000)
            }
            if value.rounded() == value {
                return "\(Int(value))"
            }
            return String(format: "%.1f", value)
        }
    }
}

struct ProviderQuotaSnapshot: Codable, Hashable {
    let provider: AgentProvider
    let fetchedAt: Date
    let source: ProviderQuotaSourceKind
    let confidence: ProviderQuotaConfidence
    let managementURL: String?
    let statusMessage: String
    let buckets: [ProviderQuotaBucket]

    var managementLink: URL? {
        guard let managementURL else { return nil }
        return URL(string: managementURL)
    }

    var primaryBucket: ProviderQuotaBucket? {
        buckets.sorted {
            let lhsRemaining = $0.remainingPercent ?? .infinity
            let rhsRemaining = $1.remainingPercent ?? .infinity
            if lhsRemaining == rhsRemaining {
                return ($0.resetsAt ?? .distantFuture) < ($1.resetsAt ?? .distantFuture)
            }
            return lhsRemaining < rhsRemaining
        }.first
    }

    var summaryText: String {
        guard let primaryBucket else { return statusMessage }
        return "\(primaryBucket.label): \(primaryBucket.remainingText) left"
    }

    func isStale(relativeTo now: Date = Date()) -> Bool {
        now.timeIntervalSince(fetchedAt) > 12 * 60 * 60
    }
}

struct ClaudeQuotaBridgeStatus: Equatable {
    enum State: Equatable {
        case notInstalled
        case awaitingFirstPayload
        case ready
        case disabledByHooks
        case invalidConfiguration
    }

    let state: State
    let wrapperPath: String
    let detailText: String
    let lastPayloadAt: Date?

    var isInstalled: Bool {
        switch state {
        case .awaitingFirstPayload, .ready, .disabledByHooks:
            return true
        case .notInstalled, .invalidConfiguration:
            return false
        }
    }
}

// MARK: - Provider Settings

enum MiniMaxQuotaMode: String, CaseIterable, Codable, Identifiable {
    case tokenPlan
    case payAsYouGo

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tokenPlan: return "Token Plan"
        case .payAsYouGo: return "Pay-as-you-go"
        }
    }
}

enum FactoryQuotaPlanTier: String, CaseIterable, Codable, Identifiable {
    case unknown
    case pro
    case max

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .unknown: return "Unknown"
        case .pro: return "Pro (20M/month)"
        case .max: return "Max (200M/month)"
        }
    }

    var monthlyTokenCap: Double? {
        switch self {
        case .unknown: return nil
        case .pro: return 20_000_000
        case .max: return 200_000_000
        }
    }
}

private enum CodexQuotaScanPolicy {
    static let freshnessWindow: TimeInterval = 7 * 24 * 60 * 60
    static let tailReadBytes = 512 * 1024
    static let maxTailLines = 4000
}

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
    ]

    private let keyStore: ProviderAPIKeyStore
    private let appPaths: BurnBarAppPaths
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
        appPaths: BurnBarAppPaths = .live(),
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
            detailText: "Enable BurnBar's status line bridge to capture Claude quota updates.",
            lastPayloadAt: nil
        )

        _ = try? BurnBarMigration.prepareSupportDirectory(fileManager: fileManager, paths: appPaths)
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
        let originalStatusLine: Any
        if currentCommand == wrapperCommand, let existingOriginal = metadata["originalStatusLine"] {
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

        settings["statusLine"] = [
            "type": "command",
            "command": wrapperCommand,
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
                detailText: "Claude settings were not found. BurnBar can install a global status line bridge in ~/.claude/settings.json.",
                lastPayloadAt: nil
            )
            return
        }

        let disableAllHooks = (settings["disableAllHooks"] as? Bool) == true
        let configuredCommand = command(fromStatusLine: settings["statusLine"])
        let snapshotDate = modificationDate(for: snapshotURL)

        if configuredCommand == wrapperPath {
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
                    detailText: "Bridge installed. Claude must produce at least one response before rate-limit JSON is captured.",
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
            detail = "Claude already has a custom status line command. BurnBar can wrap and preserve it if you enable the bridge."
        } else {
            detail = "Enable BurnBar's status line bridge to capture Claude quota updates."
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
            return try fetchClaudeSnapshot()
        case .minimax:
            return try await fetchMiniMaxSnapshot()
        case .zai:
            return try await fetchZaiSnapshot()
        case .factory:
            return fetchFactorySnapshot(dataStore: dataStore)
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
            var buckets: [ProviderQuotaBucket] = []
            if let primary = event.primary {
                buckets.append(
                    ProviderQuotaBucket(
                        key: "codex-primary",
                        label: "5-hour window",
                        windowKind: .rollingHours,
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
            if let secondary = event.secondary {
                buckets.append(
                    ProviderQuotaBucket(
                        key: "codex-secondary",
                        label: "7-day window",
                        windowKind: .rollingDays,
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

    func fetchClaudeSnapshot() throws -> ProviderQuotaSnapshot {
        refreshClaudeBridgeStatus()

        if claudeAPIBillingOverrideDetected() {
            return unavailableSnapshot(
                for: .claudeCode,
                source: .unavailable,
                message: "ANTHROPIC_API_KEY is set for this app process. Claude Code may be using API billing instead of a Claude plan, so BurnBar will not claim remaining plan quota."
            )
        }

        switch claudeBridgeStatus.state {
        case .notInstalled, .invalidConfiguration:
            return unavailableSnapshot(
                for: .claudeCode,
                source: .unavailable,
                message: claudeBridgeStatus.detailText
            )
        case .disabledByHooks:
            return unavailableSnapshot(
                for: .claudeCode,
                source: .localCLI,
                message: claudeBridgeStatus.detailText
            )
        case .awaitingFirstPayload:
            return unavailableSnapshot(
                for: .claudeCode,
                source: .localCLI,
                message: claudeBridgeStatus.detailText
            )
        case .ready:
            break
        }

        guard
            let payload = try readJSONObject(from: appPaths.claudeStatuslineSnapshotURL),
            let rateLimits = payload["rate_limits"] as? [String: Any]
        else {
            return unavailableSnapshot(
                for: .claudeCode,
                source: .localCLI,
                message: "Claude bridge is installed, but the captured status line payload does not yet include rate_limits."
            )
        }

        var buckets: [ProviderQuotaBucket] = []
        if let fiveHour = rateLimits["five_hour"] as? [String: Any] {
            buckets.append(
                ProviderQuotaBucket(
                    key: "claude-five-hour",
                    label: "5-hour window",
                    windowKind: .rollingHours,
                    usedValue: number(in: fiveHour, keys: ["used_percentage", "usedPercent", "percentage"]),
                    limitValue: 100,
                    remainingValue: remainingPercent(from: fiveHour),
                    usedPercent: number(in: fiveHour, keys: ["used_percentage", "usedPercent", "percentage"]),
                    resetsAt: date(in: fiveHour, keys: ["resets_at", "reset_at", "resetTime"]),
                    unit: .percent,
                    isEstimated: false
                )
            )
        }
        if let sevenDay = rateLimits["seven_day"] as? [String: Any] {
            buckets.append(
                ProviderQuotaBucket(
                    key: "claude-seven-day",
                    label: "7-day window",
                    windowKind: .rollingDays,
                    usedValue: number(in: sevenDay, keys: ["used_percentage", "usedPercent", "percentage"]),
                    limitValue: 100,
                    remainingValue: remainingPercent(from: sevenDay),
                    usedPercent: number(in: sevenDay, keys: ["used_percentage", "usedPercent", "percentage"]),
                    resetsAt: date(in: sevenDay, keys: ["resets_at", "reset_at", "resetTime"]),
                    unit: .percent,
                    isEstimated: false
                )
            )
        }

        let fetchedAt = claudeBridgeStatus.lastPayloadAt ?? Date()
        guard !buckets.isEmpty else {
            return unavailableSnapshot(
                for: .claudeCode,
                source: .localCLI,
                message: "Claude bridge is installed, but quota fields are still empty. Send one response in Claude Code first."
            )
        }

        return ProviderQuotaSnapshot(
            provider: .claudeCode,
            fetchedAt: fetchedAt,
            source: .localCLI,
            confidence: .exact,
            managementURL: "https://code.claude.com/docs/en/statusline",
            statusMessage: "Quota captured from Claude Code's local status line JSON bridge.",
            buckets: buckets
        )
    }

    func fetchMiniMaxSnapshot() async throws -> ProviderQuotaSnapshot {
        guard miniMaxModeProvider() == .tokenPlan else {
            return unavailableSnapshot(
                for: .minimax,
                source: .unavailable,
                message: "MiniMax quota reporting is disabled while billing mode is set to Pay-as-you-go."
            )
        }

        guard let apiKey = resolveMiniMaxAPIKey() else {
            return unavailableSnapshot(
                for: .minimax,
                source: .unavailable,
                message: "Add a MiniMax Token Plan API key to report remaining quota."
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

    func fetchZaiSnapshot() async throws -> ProviderQuotaSnapshot {
        guard let apiKey = resolveZaiAPIKey() else {
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
                let modelUsageObject = try await requestJSON(
                    url: baseURL.appendingPathComponent("api/monitor/usage/model-usage"),
                    queryItems: queryItems,
                    authorizationValue: apiKey
                )
                let toolUsageObject = try await requestJSON(
                    url: baseURL.appendingPathComponent("api/monitor/usage/tool-usage"),
                    queryItems: queryItems,
                    authorizationValue: apiKey
                )
                let quotaObject = try await requestJSON(
                    url: baseURL.appendingPathComponent("api/monitor/usage/quota/limit"),
                    authorizationValue: apiKey
                )

                let buckets = extractFlexibleBuckets(
                    from: quotaObject,
                    provider: .zai,
                    endpointLabel: "zai"
                )
                guard !buckets.isEmpty else { continue }

                let modelRows = extractRecordCount(from: modelUsageObject)
                let toolRows = extractRecordCount(from: toolUsageObject)

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

    func fetchFactorySnapshot(dataStore: DataStore) -> ProviderQuotaSnapshot {
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
            statusMessage: "Estimated from BurnBar-tracked Factory / Droid raw tokens this month, not Factory billable tokens.",
            buckets: [bucket]
        )
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
            print("ProviderQuotaService: Failed to persist snapshots: \(error)")
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
            print("ProviderQuotaService: Failed to persist codex scan cache: \(error)")
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
            ($0.remainingPercent ?? -1) > ($1.remainingPercent ?? -1)
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
        let usedPercent = number(in: dictionary, keys: [
            "used_percent", "usedPercent", "used_percentage", "usage_percent", "usagePercent", "percentage", "usedRate", "usageRate"
        ])
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
            ?? bestPathLabel(from: path)
            ?? string(in: dictionary, keys: ["window", "type"])
            ?? "quota"
        let label = normalizedBucketLabel(rawLabel, provider: provider)
        let windowKind = inferWindowKind(
            from: intervalHint ?? rawLabel,
            intervalStart: intervalStart,
            resetsAt: resetsAt
        )
        let unit = inferUnit(provider: provider, label: rawLabel, dictionary: dictionary, usedPercent: usedPercent, limitValue: limitValue)
        let normalizedRemaining: Double?
        if let remainingValue {
            normalizedRemaining = remainingValue
        } else if let usedPercent {
            normalizedRemaining = max(0, 100 - usedPercent)
        } else if let usedValue, let limitValue {
            normalizedRemaining = max(limitValue - usedValue, 0)
        } else {
            normalizedRemaining = nil
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
            ?? nonEmpty(environment["ANTHROPIC_AUTH_TOKEN"])
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
            if let date = zaiDateFormatter.date(from: string) {
                return date
            }
        }
        return nil
    }

    func zaiCandidateBaseURLs() -> [URL] {
        var candidates: [URL] = []
        if let configured = environment["ANTHROPIC_BASE_URL"], let url = URL(string: configured) {
            let host = URL(string: "\(url.scheme ?? "https")://\(url.host ?? "")")
            if let host {
                candidates.append(host)
            }
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
        TMP_FILE="$(mktemp "${TMPDIR:-/tmp}/burnbar-claude-statusline.XXXXXX")"
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
                        resetsAt: $0.resetsAt
                    )
                },
                secondary: event.payload.rateLimits.secondary.map {
                    CodexRateLimitWindow(
                        usedPercent: $0.usedPercent,
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

    func normalizedBucketLabel(_ label: String, provider: AgentProvider) -> String {
        let lowercased = label.lowercased()
        if provider == .zai {
            if lowercased.contains("tokens_limit") {
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

    nonisolated(unsafe) static let zaiDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}

// MARK: - Models

private extension ProviderQuotaService {
    struct CodexRateLimitEvent: Codable, Equatable, Sendable {
        let timestamp: Date
        let planType: String?
        let primary: CodexRateLimitWindow?
        let secondary: CodexRateLimitWindow?
    }

    struct CodexRateLimitWindow: Codable, Equatable, Sendable {
        let usedPercent: Double?
        let resetsAt: Date?
    }

    struct CodexRolloutFileSignature: Codable, Equatable, Sendable {
        let modifiedAt: TimeInterval
        let sizeBytes: Int64
    }

    struct CodexRolloutFileCacheEntry: Codable, Equatable, Sendable {
        let signature: CodexRolloutFileSignature
        let latestRateLimitEvent: CodexRateLimitEvent?
    }

    struct CodexRolloutScanCache: Codable, Equatable, Sendable {
        var schemaVersion: Int
        var fileEntries: [String: CodexRolloutFileCacheEntry]
        var latestRateLimitEvent: CodexRateLimitEvent?
        var lastUpdatedAt: Date?

        static let empty = CodexRolloutScanCache(
            schemaVersion: 1,
            fileEntries: [:],
            latestRateLimitEvent: nil,
            lastUpdatedAt: nil
        )
    }

    struct CodexRateLimitScanResult: Sendable {
        let latestEvent: CodexRateLimitEvent?
        let cache: CodexRolloutScanCache
        let didChangeCache: Bool
    }

    struct CodexRolloutEnvelope: Decodable {
        let timestamp: Date
        let type: String
        let payload: Payload

        struct Payload: Decodable {
            let type: String
            let rateLimits: RateLimits

            enum CodingKeys: String, CodingKey {
                case type
                case rateLimits = "rate_limits"
            }

            struct RateLimits: Decodable {
                let primary: Window?
                let secondary: Window?
                let planType: String?

                enum CodingKeys: String, CodingKey {
                    case primary
                    case secondary
                    case planType = "plan_type"
                }
            }

            struct Window: Decodable {
                let usedPercent: Double?
                let resetsAt: Date?

                enum CodingKeys: String, CodingKey {
                    case usedPercent = "used_percent"
                    case resetsAt = "resets_at"
                }

                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    usedPercent = try container.decodeIfPresent(Double.self, forKey: .usedPercent)

                    if let unixSeconds = try container.decodeIfPresent(Double.self, forKey: .resetsAt) {
                        resetsAt = Date(timeIntervalSince1970: unixSeconds)
                    } else if let stringValue = try container.decodeIfPresent(String.self, forKey: .resetsAt),
                              let parsed = ProviderQuotaService.parseDateValue(stringValue) {
                        resetsAt = parsed
                    } else {
                        resetsAt = nil
                    }
                }
            }
        }
    }
}

// MARK: - Errors

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
