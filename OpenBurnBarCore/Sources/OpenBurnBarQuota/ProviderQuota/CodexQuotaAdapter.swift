import Foundation
import OpenBurnBarKernel

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct CodexQuotaAdapter: ProviderQuotaAdapter {
    public init() {}
    public func fetch(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot {
        if let oauthSnapshot = try? await CodexOAuthQuotaFetcher.fetch(context: context) { // try?-ok(quota fetch, fallback to scan)
            return oauthSnapshot
        }

        let codexConfigURL = Self.codexConfigURL(context: context)
        let candidateDirectories = [
            codexConfigURL.appendingPathComponent("sessions", isDirectory: true),
            codexConfigURL.appendingPathComponent("archived_sessions", isDirectory: true)
        ]

        let freshnessCutoff = Date().addingTimeInterval(-CodexQuotaScanPolicy.freshnessWindow)
        let existingCache = context.codexRolloutScanCache
        // `fetch` is a `nonisolated` `async` method, so the blocking rollout scan
        // runs off the main actor (SE-0338) without an extra detached task.
        let scanResult = try CodexRolloutScanner.scanCodexRateLimitEvents(
            in: candidateDirectories,
            freshnessCutoff: freshnessCutoff,
            existingCache: existingCache
        )
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

enum CodexOAuthQuotaFetcher {
    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private static let authRefreshGrace: TimeInterval = 8 * 24 * 60 * 60

    static func fetch(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot {
        let configURL = CodexQuotaAdapter.codexConfigURL(context: context)
        let authURL = configURL.appendingPathComponent("auth.json")
        var auth = try loadAuth(from: authURL)
        if shouldNudgeCodexAuthRefresh(auth: auth) {
            await nudgeCodexAuthRefresh(context: context, configURL: configURL)
            auth = try loadAuth(from: authURL)
        }

        do {
            return try await fetchUsageSnapshot(accessToken: auth.accessToken, context: context)
        } catch CodexOAuthQuotaError.unauthorized {
            await nudgeCodexAuthRefresh(context: context, configURL: configURL)
            auth = try loadAuth(from: authURL)
            return try await fetchUsageSnapshot(accessToken: auth.accessToken, context: context)
        }
    }

    private static func fetchUsageSnapshot(
        accessToken: String,
        context: ProviderQuotaAdapterContext
    ) async throws -> ProviderQuotaSnapshot {
        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await context.session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CodexOAuthQuotaError.invalidResponse
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw CodexOAuthQuotaError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CodexOAuthQuotaError.invalidResponse
        }

        let now = Date()
        return try parseUsageSnapshot(
            data,
            now: now,
            environment: context.environment,
            quotaLogger: context.quotaLogger
        )
    }

    static func parseUsageSnapshot(
        _ data: Data,
        now: Date,
        environment: [String: String],
        quotaLogger: any QuotaLogger
    ) throws -> ProviderQuotaSnapshot {
        let snapshot = try CodexQuotaDomainCoreAdapter.snapshot(
            payload: data,
            now: now,
            environment: environment,
            quotaLogger: quotaLogger
        ) {
            try CodexQuotaLegacy.usageSnapshot(data, now: now)
        }
        let credits = QuotaResetCreditParser.parse(payload: data, now: now)
        return credits.isEmpty ? snapshot : snapshot.withResetCredits(credits)
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

    /// Runs off the main actor (`nonisolated` `async`, SE-0338).
    private static func nudgeCodexAuthRefresh(context: ProviderQuotaAdapterContext, configURL: URL) async {
        #if !os(macOS)
        return
        #else
        let environment = context.environment
        guard let codexExecutable = CLILaunchAdapter.resolvePinnedExecutable(for: .codex) else {
            return
        }
        var env = CLILaunchAdapter.buildAllowlistedBaselineEnvironment(baseEnv: environment)
        env["PATH"] = CLILaunchAdapter.trustedExecutableEnvironmentPath(homeDirectory: environment["HOME"])
        env["CODEX_HOME"] = configURL.path
        env["CODEX_CONFIG_PATH"] = configURL.path
        _ = try? context.cliExecutor.run(
            executable: codexExecutable.path,
            arguments: ["login", "status"],
            environment: env
        )
        #endif
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
            if let value = try? container.decode(Double.self) { // try?-ok(optional decode, falls through)
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

enum CodexOAuthQuotaError: Error {
    case missingToken
    case unsupportedAuthMode
    case unauthorized
    case invalidResponse
}
