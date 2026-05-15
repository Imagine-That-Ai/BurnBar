import Foundation

struct CodexQuotaAdapter: ProviderQuotaAdapter {
    func fetch(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot {
        if let oauthSnapshot = try? await CodexOAuthQuotaFetcher.fetch(context: context) {
            return oauthSnapshot
        }

        let codexConfigURL = Self.codexConfigURL(context: context)
        let candidateDirectories = [
            codexConfigURL.appendingPathComponent("sessions", isDirectory: true),
            codexConfigURL.appendingPathComponent("archived_sessions", isDirectory: true),
        ]

        let freshnessCutoff = Date().addingTimeInterval(-CodexQuotaScanPolicy.freshnessWindow)
        let existingCache = context.codexRolloutScanCache
        let scanResult = try await Task.detached(priority: .utility) {
            try CodexRolloutScanner.scanCodexRateLimitEvents(
                in: candidateDirectories,
                freshnessCutoff: freshnessCutoff,
                existingCache: existingCache
            )
        }.value
        context.updateCodexRolloutScanCache(scanResult.cache, scanResult.didChangeCache)

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
            message: "No Codex usage API response or recent local rate-limit snapshot was available. Reconnect Codex only if the local Codex login has expired."
        )
    }

    // MARK: - Codex Helpers

    static func codexConfigURL(context: ProviderQuotaAdapterContext) -> URL {
        for key in ["CODEX_HOME", "CODEX_CONFIG_PATH"] {
            if let raw = context.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !raw.isEmpty {
                return URL(fileURLWithPath: raw, isDirectory: true)
            }
        }
        return context.homeDirectoryURL.appendingPathComponent(".codex", isDirectory: true)
    }

    enum CodexWindowRole {
        case session
        case weekly
        case unknown
    }

    private func normalizedCodexRateLimitWindows(
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

    private func codexWindowRole(for window: CodexRateLimitWindow) -> CodexWindowRole {
        switch window.windowMinutes {
        case 300:
            return .session
        case 10_080:
            return .weekly
        default:
            return .unknown
        }
    }

    private func codexWindowKind(for window: CodexRateLimitWindow) -> ProviderQuotaWindowKind {
        switch codexWindowRole(for: window) {
        case .session:
            return .rollingHours
        case .weekly:
            return .rollingDays
        case .unknown:
            return .custom
        }
    }

    private func codexBucketLabel(for window: CodexRateLimitWindow, fallback: String) -> String {
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

private enum CodexOAuthQuotaFetcher {
    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private static let authRefreshGrace: TimeInterval = 8 * 24 * 60 * 60

    static func fetch(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot {
        let configURL = CodexQuotaAdapter.codexConfigURL(context: context)
        let authURL = configURL.appendingPathComponent("auth.json")
        var auth = try loadAuth(from: authURL)
        if shouldNudgeCodexAuthRefresh(auth: auth) {
            await nudgeCodexAuthRefresh(environment: context.environment, configURL: configURL)
            auth = try loadAuth(from: authURL)
        }

        do {
            return try await fetchUsageSnapshot(accessToken: auth.accessToken, session: context.session)
        } catch CodexOAuthQuotaError.unauthorized {
            await nudgeCodexAuthRefresh(environment: context.environment, configURL: configURL)
            auth = try loadAuth(from: authURL)
            return try await fetchUsageSnapshot(accessToken: auth.accessToken, session: context.session)
        }
    }

    private static func fetchUsageSnapshot(accessToken: String, session: URLSession) async throws -> ProviderQuotaSnapshot {
        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CodexOAuthQuotaError.invalidResponse
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw CodexOAuthQuotaError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CodexOAuthQuotaError.invalidResponse
        }

        let payload = try JSONDecoder().decode(CodexUsagePayload.self, from: data)
        let now = Date()
        var buckets = rateLimitBuckets(
            payload.rateLimit,
            prefix: "codex",
            labelPrefix: nil,
            now: now
        )

        for additional in payload.additionalRateLimits.prefix(8) {
            let label = additional.limitName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { continue }
            buckets.append(contentsOf: rateLimitBuckets(
                additional.rateLimit,
                prefix: "codex-\(slug(label))",
                labelPrefix: label,
                now: now
            ))
        }

        guard !buckets.isEmpty else {
            throw CodexOAuthQuotaError.invalidResponse
        }

        let plan = payload.planType?.capitalized ?? "Codex"
        return ProviderQuotaSnapshot(
            provider: .codex,
            fetchedAt: now,
            source: .officialAPI,
            confidence: .exact,
            managementURL: "https://chatgpt.com/codex/settings/usage",
            statusMessage: "\(plan) quota snapshot from the local Codex login session.",
            buckets: buckets
        )
    }

    private static func rateLimitBuckets(
        _ limit: CodexUsagePayload.RateLimit?,
        prefix: String,
        labelPrefix: String?,
        now: Date
    ) -> [ProviderQuotaBucket] {
        guard let limit else { return [] }
        var buckets: [ProviderQuotaBucket] = []
        if let primary = limit.primaryWindow {
            buckets.append(bucket(
                window: primary,
                key: "\(prefix)-5h",
                label: labelPrefix.map { "\($0) 5-hour window" } ?? "5-hour window",
                fallbackKind: .rollingHours,
                now: now
            ))
        }
        if let secondary = limit.secondaryWindow {
            buckets.append(bucket(
                window: secondary,
                key: "\(prefix)-7d",
                label: labelPrefix.map { "\($0) 7-day window" } ?? "7-day window",
                fallbackKind: .rollingDays,
                now: now
            ))
        }
        return buckets
    }

    private static func bucket(
        window: CodexUsagePayload.Window,
        key: String,
        label: String,
        fallbackKind: ProviderQuotaWindowKind,
        now: Date
    ) -> ProviderQuotaBucket {
        let used = min(max(window.usedPercent, 0), 100)
        return ProviderQuotaBucket(
            key: key,
            label: label,
            windowKind: windowKind(seconds: window.limitWindowSeconds) ?? fallbackKind,
            usedValue: used,
            limitValue: 100,
            remainingValue: max(0, 100 - used),
            usedPercent: used,
            resetsAt: resetDate(for: window, now: now),
            unit: .percent,
            isEstimated: false
        )
    }

    private static func resetDate(for window: CodexUsagePayload.Window, now: Date) -> Date? {
        if let resetAt = window.resetAt, resetAt > 0 {
            return Date(timeIntervalSince1970: TimeInterval(resetAt))
        }
        if let resetAfter = window.resetAfterSeconds, resetAfter >= 0 {
            return now.addingTimeInterval(TimeInterval(resetAfter))
        }
        return nil
    }

    private static func windowKind(seconds: Int?) -> ProviderQuotaWindowKind? {
        guard let seconds, seconds > 0 else { return nil }
        switch seconds {
        case 18_000:
            return .rollingHours
        case 604_800:
            return .rollingDays
        default:
            return seconds >= 86_400 ? .rollingDays : .rollingHours
        }
    }

    private static func loadAuth(from url: URL) throws -> CodexAuth {
        let data = try Data(contentsOf: url)
        let payload = try JSONDecoder().decode(CodexAuthPayload.self, from: data)
        guard payload.authMode == "chatgpt" || payload.authMode == nil else {
            throw CodexOAuthQuotaError.unsupportedAuthMode
        }
        guard let accessToken = payload.tokens?.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty else {
            throw CodexOAuthQuotaError.missingToken
        }
        return CodexAuth(accessToken: accessToken, lastRefresh: payload.lastRefreshDate)
    }

    private static func shouldNudgeCodexAuthRefresh(auth: CodexAuth) -> Bool {
        guard let lastRefresh = auth.lastRefresh else { return false }
        return Date().timeIntervalSince(lastRefresh) > authRefreshGrace
    }

    private static func nudgeCodexAuthRefresh(environment: [String: String], configURL: URL) async {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["codex", "login", "status"]
            var env = environment
            env["CODEX_HOME"] = configURL.path
            env["CODEX_CONFIG_PATH"] = configURL.path
            process.environment = env
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            process.standardInput = FileHandle.nullDevice

            do {
                try process.run()
            } catch {
                return
            }

            let deadline = Date().addingTimeInterval(8)
            while process.isRunning && Date() < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if process.isRunning {
                process.terminate()
            }
            process.waitUntilExit()
        }.value
    }

    private static func slug(_ value: String) -> String {
        let lower = value.lowercased()
        let scalars = lower.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(scalars).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "additional" : collapsed
    }
}

private struct CodexAuth {
    let accessToken: String
    let lastRefresh: Date?
}

private struct CodexAuthPayload: Decodable {
    let authMode: String?
    let tokens: Tokens?
    let lastRefresh: LastRefresh?

    enum CodingKeys: String, CodingKey {
        case authMode = "auth_mode"
        case tokens
        case lastRefresh = "last_refresh"
    }

    struct Tokens: Decodable {
        let accessToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
        }
    }

    var lastRefreshDate: Date? {
        lastRefresh?.date
    }

    enum LastRefresh: Decodable {
        case date(Date)
        case seconds(Double)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Double.self) {
                self = .seconds(value)
                return
            }
            let string = try container.decode(String.self)
            if let seconds = Double(string) {
                self = .seconds(seconds)
                return
            }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: string) {
                self = .date(date)
                return
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported Codex last_refresh value")
        }

        var date: Date? {
            switch self {
            case .date(let date):
                return date
            case .seconds(let seconds):
                return Date(timeIntervalSince1970: seconds)
            }
        }
    }
}

private struct CodexUsagePayload: Decodable {
    let planType: String?
    let rateLimit: RateLimit?
    let additionalRateLimits: [AdditionalRateLimit]

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case additionalRateLimits = "additional_rate_limits"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        planType = try container.decodeIfPresent(String.self, forKey: .planType)
        rateLimit = try container.decodeIfPresent(RateLimit.self, forKey: .rateLimit)
        additionalRateLimits = try container.decodeIfPresent([AdditionalRateLimit].self, forKey: .additionalRateLimits) ?? []
    }

    struct AdditionalRateLimit: Decodable {
        let limitName: String
        let rateLimit: RateLimit?

        enum CodingKeys: String, CodingKey {
            case limitName = "limit_name"
            case rateLimit = "rate_limit"
        }
    }

    struct RateLimit: Decodable {
        let primaryWindow: Window?
        let secondaryWindow: Window?

        enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }

    struct Window: Decodable {
        let usedPercent: Double
        let limitWindowSeconds: Int?
        let resetAfterSeconds: Int?
        let resetAt: Int?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case limitWindowSeconds = "limit_window_seconds"
            case resetAfterSeconds = "reset_after_seconds"
            case resetAt = "reset_at"
        }
    }
}

private enum CodexOAuthQuotaError: Error {
    case missingToken
    case unsupportedAuthMode
    case unauthorized
    case invalidResponse
}
