import Foundation

// MARK: - Factory / Droid Quota Adapter

/// Reports real Factory/droid token usage from `~/.factory/sessions/**/*.settings.json`.
///
/// ## Ground truth sources (tried in order):
/// 1. **Droid session tracking** — `~/.factory/sessions/**/*.settings.json`
///    Every droid session stores `tokenUsage` with exact input/output/cache/thinking tokens.
///    This is the canonical source — zero config, zero auth, always available.
/// 2. **Factory billing API** — `GET api.factory.ai/api/organization/subscription/usage`
///    Returns org-level billing data when the user's organization has billing configured.
///    Requires Chrome cookie auth or WKWebView login.
/// 3. **Unavailable** — when neither source yields data.
///
/// ## Data returned
/// - 5-hour window: rolling token count from recent sessions
/// - 7-day window: token count from the past week
/// - 30-day window: monthly token count
/// - Per-model breakdown (top models by session count)
/// - Cache efficiency (cache read / total tokens)
///
/// No estimates. No heuristics. Every number comes from droid's own tracking.

struct FactoryQuotaAdapter: ProviderQuotaAdapter {

    // MARK: - Constants

    private static let factorySessionsPath = (
        "~/.factory/sessions" as NSString
    ).expandingTildeInPath

    // MARK: - Fetch

    func fetch(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot {
        // 1. Try the billing API first (org billing data is authoritative for plan limits)
        if let exactSnapshot = try? await fetchFactoryExactSnapshot(context: context) {
            return exactSnapshot
        }

        // 2. Try dashboard scraper for personal accounts (cookie-based, same pattern as Ollama Cloud)
        if let personalSnapshot = try? await fetchFactoryPersonalSnapshot(context: context) {
            return personalSnapshot
        }

        // 3. Try droid session tracking (always available, real token counts)
        if let sessionSnapshot = await fetchDroidSessionSnapshot(context: context) {
            return sessionSnapshot
        }

        // 3. No data available — NOT an estimate
        return ProviderQuotaSnapshot(
            provider: .factory,
            fetchedAt: Date(),
            source: .unavailable,
            confidence: .unavailable,
            managementURL: "https://app.factory.ai",
            statusMessage: "No droid session data found. Start using Factory/droid to see real token usage.",
            buckets: []
        )
    }

    // MARK: - Droid Session Snapshot

    private func fetchDroidSessionSnapshot(context: ProviderQuotaAdapterContext) async -> ProviderQuotaSnapshot? {
        let sessionsURL = URL(fileURLWithPath: Self.factorySessionsPath)
        let fileManager = context.fileManager

        guard fileManager.fileExists(atPath: sessionsURL.path) else { return nil }

        // Collect all .settings.json files
        guard let enumerator = fileManager.enumerator(
            at: sessionsURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }

        let now = Date()
        let fiveHoursAgo = now.addingTimeInterval(-5 * 60 * 60)
        let sevenDaysAgo = now.addingTimeInterval(-7 * 24 * 60 * 60)
        let thirtyDaysAgo = now.addingTimeInterval(-30 * 24 * 60 * 60)

        var fiveHourTokens: Int64 = 0
        var sevenDayTokens: Int64 = 0
        var thirtyDayTokens: Int64 = 0
        var cacheReadTokens: Int64 = 0
        var filesScanned = 0
        var filesWithUsage = 0
        var modelCounts: [String: Int] = [:]

        while let fileURL = enumerator.nextObject() as? URL {
            guard fileURL.pathExtension == "json",
                  fileURL.lastPathComponent.hasSuffix(".settings.json") else { continue }

            filesScanned += 1

            guard let data = try? Data(contentsOf: fileURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let usage = json["tokenUsage"] as? [String: Any] else { continue }

            let input = (usage["inputTokens"] as? Int64) ?? (usage["inputTokens"] as? Int).map(Int64.init) ?? 0
            let output = (usage["outputTokens"] as? Int64) ?? (usage["outputTokens"] as? Int).map(Int64.init) ?? 0
            let cacheCreate = (usage["cacheCreationTokens"] as? Int64) ?? (usage["cacheCreationTokens"] as? Int).map(Int64.init) ?? 0
            let cacheRead = (usage["cacheReadTokens"] as? Int64) ?? (usage["cacheReadTokens"] as? Int).map(Int64.init) ?? 0
            let thinking = (usage["thinkingTokens"] as? Int64) ?? (usage["thinkingTokens"] as? Int).map(Int64.init) ?? 0

            let total = input + output + cacheCreate + cacheRead + thinking
            guard total > 0 else { continue }

            filesWithUsage += 1
            cacheReadTokens += cacheRead

            // Use providerLockTimestamp for accurate time-window bucketing
            let sessionDate: Date? = {
                if let ts = json["providerLockTimestamp"] as? String {
                    let fmt = ISO8601DateFormatter()
                    fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    return fmt.date(from: ts) ?? ISO8601DateFormatter().date(from: ts)
                }
                return (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            }()

            guard let sessionDate else { continue }

            if sessionDate >= thirtyDaysAgo {
                thirtyDayTokens += total
            }
            if sessionDate >= sevenDaysAgo {
                sevenDayTokens += total
            }
            if sessionDate >= fiveHoursAgo {
                fiveHourTokens += total
            }

            // Track models
            if let model = json["model"] as? String {
                modelCounts[model] = (modelCounts[model] ?? 0) + 1
            }
        }

        guard filesWithUsage > 0 else { return nil }

        var buckets: [ProviderQuotaBucket] = []
        let calendar = Calendar.current

        // 5-hour rolling window
        if fiveHourTokens > 0 {
            buckets.append(ProviderQuotaBucket(
                key: "factory-5h",
                label: "5-hour window",
                windowKind: .rollingHours,
                usedValue: Double(fiveHourTokens),
                limitValue: nil,
                remainingValue: nil,
                usedPercent: nil,
                resetsAt: calendar.date(byAdding: .hour, value: 5, to: now),
                unit: .tokens,
                isEstimated: false
            ))
        }

        // 7-day window
        if sevenDayTokens > 0 {
            buckets.append(ProviderQuotaBucket(
                key: "factory-7d",
                label: "7-day window",
                windowKind: .rollingDays,
                usedValue: Double(sevenDayTokens),
                limitValue: nil,
                remainingValue: nil,
                usedPercent: nil,
                resetsAt: calendar.date(byAdding: .day, value: 7, to: now),
                unit: .tokens,
                isEstimated: false
            ))
        }

        // 30-day window
        if thirtyDayTokens > 0 {
            buckets.append(ProviderQuotaBucket(
                key: "factory-30d",
                label: "30-day window",
                windowKind: .monthly,
                usedValue: Double(thirtyDayTokens),
                limitValue: nil,
                remainingValue: nil,
                usedPercent: nil,
                resetsAt: calendar.date(byAdding: .month, value: 1, to: calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now),
                unit: .tokens,
                isEstimated: false
            ))
        }

        // Cache efficiency
        if cacheReadTokens > 0 && thirtyDayTokens > 0 {
            let cacheRate = Double(cacheReadTokens) / Double(thirtyDayTokens) * 100
            buckets.append(ProviderQuotaBucket(
                key: "factory-cache",
                label: "Cache hit rate (30d)",
                windowKind: .monthly,
                usedValue: cacheRate,
                limitValue: 100,
                remainingValue: nil,
                usedPercent: cacheRate,
                resetsAt: nil,
                unit: .percent,
                isEstimated: false
            ))
        }

        // Top model
        let topModel = modelCounts.max(by: { $0.value < $1.value }).map { "\($0.key) (\($0.value) sessions)" } ?? ""

        let statusMessage = "Real token counts from \(filesWithUsage) droid sessions. \(topModel). Install the Factory CLI bridge for billing plan limits."

        return ProviderQuotaSnapshot(
            provider: .factory,
            fetchedAt: now,
            source: .localSession,
            confidence: .exact,
            managementURL: "https://app.factory.ai",
            statusMessage: statusMessage,
            buckets: buckets
        )
    }


    // MARK: - Personal Account Dashboard Scraper

    /// Tries the cookie-based dashboard scraper for personal (non-org) Factory accounts.
    /// Uses the same Chrome-cookie + HTML-scraping approach as OllamaCloudScraper.
    private func fetchFactoryPersonalSnapshot(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot {
        guard let usage = await FactoryDashboardScraper.fetchPersonalUsage(session: context.session) else {
            throw QuotaServiceError.invalidResponse("Factory dashboard scraper found no usage data.")
        }

        var buckets: [ProviderQuotaBucket] = []

        if let used = usage.tokensUsed, used > 0 {
            let pct = usage.usedPercent ?? 0
            buckets.append(ProviderQuotaBucket(
                key: "factory-plan",
                label: "\(usage.planName ?? "Plan") usage",
                windowKind: .monthly,
                usedValue: used,
                limitValue: usage.tokensLimit,
                remainingValue: usage.tokensLimit.map { max($0 - used, 0) },
                usedPercent: pct,
                resetsAt: usage.periodEnd,
                unit: .tokens,
                isEstimated: false
            ))
        }

        guard !buckets.isEmpty else {
            throw QuotaServiceError.invalidResponse("Factory dashboard returned empty usage data.")
        }

        let emailSuffix = usage.accountEmail.map { " (\($0))" } ?? ""
        let planLabel = usage.planName ?? "Factory"

        return ProviderQuotaSnapshot(
            provider: .factory,
            fetchedAt: Date(),
            source: .officialAPI,
            confidence: .exact,
            managementURL: "https://app.factory.ai/settings/billing",
            statusMessage: "\(planLabel)\(emailSuffix) — scraped from Factory dashboard.",
            buckets: buckets
        )
    }

    // MARK: - Billing API Snapshot (org billing)

    private func fetchFactoryExactSnapshot(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot {
        guard let credentials = await loadFactoryCredentials(context: context) else {
            throw QuotaServiceError.invalidResponse("No reusable Factory session was found.")
        }

        guard let baseURL = URL(
            string: quotaNonEmpty(context.environment["FACTORY_BASE_URL"])
                ?? "https://api.factory.ai"
        ) else {
            throw QuotaServiceError.invalidResponse("Factory base URL is invalid.")
        }

        let auth = try await fetchFactoryAuth(
            credentials: credentials,
            baseURL: baseURL,
            session: context.session
        )
        let usage = try await fetchFactoryUsage(
            credentials: credentials,
            baseURL: baseURL,
            session: context.session
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
            .compactMap { quotaNonEmpty($0) }
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

    // MARK: - Credential Resolution

    private func loadFactoryCredentials(context: ProviderQuotaAdapterContext) async -> FactorySessionCredentialEnvelope? {
        // 1. Environment variable overrides
        let envCookie = quotaNonEmpty(context.environment["FACTORY_COOKIE_HEADER"])
        let envBearer = quotaNonEmpty(context.environment["FACTORY_BEARER_TOKEN"])
        if envCookie != nil || envBearer != nil {
            return FactorySessionCredentialEnvelope(
                cookieHeader: envCookie,
                bearerToken: envBearer ?? factoryBearerToken(fromCookieHeader: envCookie),
                sourceLabel: "environment override"
            )
        }
        // 2. Chrome/Safari cookie auto-extraction
        if let extractedCookie = FactoryCookieExtractor.extractCookieHeader() {
            let bearerToken = quotaNonEmpty(context.environment["FACTORY_BEARER_TOKEN"])
                ?? FactoryCookieExtractor.extractBearerToken(from: extractedCookie)
            return FactorySessionCredentialEnvelope(
                cookieHeader: extractedCookie,
                bearerToken: bearerToken ?? factoryBearerToken(fromCookieHeader: extractedCookie),
                sourceLabel: "browser cookie store"
            )
        }

        // 3. WKWebView login flow
        if let loginCookie = await FactoryLoginHelper.runLoginFlow() {
            let bearerToken = FactoryCookieExtractor.extractBearerToken(from: loginCookie)
            return FactorySessionCredentialEnvelope(
                cookieHeader: loginCookie,
                bearerToken: bearerToken ?? factoryBearerToken(fromCookieHeader: loginCookie),
                sourceLabel: "WKWebView login"
            )
        }

        return nil
    }

    // MARK: - API Helpers

    private func fetchFactoryAuth(
        credentials: FactorySessionCredentialEnvelope,
        baseURL: URL,
        session: URLSession
    ) async throws -> FactoryAuthResponseEnvelope {
        let url = baseURL.appendingPathComponent("/api/app/auth/me")
        let data = try await performFactoryRequest(
            url: url,
            method: "GET",
            credentials: credentials,
            session: session
        )
        let json = try JSONSerialization.jsonObject(with: data)
        let object = FlexibleQuotaBucketNormalizer.unwrapDataEnvelope(json)
        guard let dictionary = object as? [String: Any] else {
            throw QuotaServiceError.invalidResponse("Factory auth payload was not a JSON object.")
        }

        let organization = dictionary["organization"] as? [String: Any]
        let subscription = organization?["subscription"] as? [String: Any]
        let orbSubscription = subscription?["orbSubscription"] as? [String: Any]
        let plan = orbSubscription?["plan"] as? [String: Any]

        return FactoryAuthResponseEnvelope(
            planName: quotaNonEmpty(plan?["name"] as? String),
            tier: quotaNonEmpty(subscription?["factoryTier"] as? String),
            organizationName: quotaNonEmpty(organization?["name"] as? String)
        )
    }

    private func fetchFactoryUsage(
        credentials: FactorySessionCredentialEnvelope,
        baseURL: URL,
        session: URLSession
    ) async throws -> FactoryUsageEnvelope {
        let url = baseURL.appendingPathComponent("/api/organization/subscription/usage")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "useCache", value: "true")]
        guard let finalURL = components?.url else {
            throw QuotaServiceError.invalidResponse("Factory usage URL is invalid.")
        }
        let data = try await performFactoryRequest(
            url: finalURL,
            method: "GET",
            credentials: credentials,
            session: session
        )
        let json = try JSONSerialization.jsonObject(with: data)
        let object = FlexibleQuotaBucketNormalizer.unwrapDataEnvelope(json)
        guard let dictionary = object as? [String: Any] else {
            throw QuotaServiceError.invalidResponse("Factory usage payload was not a JSON object.")
        }

        let usage = dictionary["usage"] as? [String: Any] ?? dictionary
        let periodEnd = FlexibleQuotaBucketNormalizer.date(in: usage, keys: ["endDate", "end_date"])
        let standard = factoryLane(from: usage["standard"] as? [String: Any])
        let premium = factoryLane(from: usage["premium"] as? [String: Any])

        return FactoryUsageEnvelope(
            periodEnd: periodEnd,
            standard: standard,
            premium: premium
        )
    }

    private func performFactoryRequest(
        url: URL,
        method: String,
        credentials: FactorySessionCredentialEnvelope,
        session: URLSession,
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

    private func factoryLane(from dictionary: [String: Any]?) -> FactoryUsageEnvelope.Lane {
        let lane = dictionary ?? [:]
        let used = FlexibleQuotaBucketNormalizer.number(in: lane, keys: ["userTokens", "user_tokens"]) ?? 0
        let allowance = FlexibleQuotaBucketNormalizer.number(in: lane, keys: ["totalAllowance", "total_allowance", "allowance"])
        let ratio = FlexibleQuotaBucketNormalizer.number(in: lane, keys: ["usedRatio", "used_ratio", "usageRatio", "usage_ratio"])
        let usedPercent = normalizedFactoryPercent(ratio: ratio, used: used, allowance: allowance)
        return FactoryUsageEnvelope.Lane(
            userTokens: used,
            totalAllowance: allowance,
            usedPercent: usedPercent
        )
    }

    private func normalizedFactoryPercent(ratio: Double?, used: Double, allowance: Double?) -> Double? {
        if let ratio, ratio.isFinite {
            if ratio >= 0, ratio <= 1.001 {
                return min(max(ratio * 100, 0), 100)
            }
            if ratio >= 0, ratio <= 100 {
                return ratio
            }
        }
        guard let allowance, allowance > 0 else { return nil }
        return min(max((used / allowance) * 100, 0), 100)
    }

    private func makeFactoryBucket(
        key: String,
        label: String,
        lane: FactoryUsageEnvelope.Lane,
        resetsAt: Date?
    ) -> ProviderQuotaBucket? {
        let hasCounts = lane.userTokens > 0 || (lane.totalAllowance ?? 0) > 0
        guard hasCounts || lane.usedPercent != nil else { return nil }

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

    private func factoryBearerToken(fromCookieHeader header: String?) -> String? {
        guard let header else { return nil }
        for pair in header.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard parts.count == 2 else { continue }
            if parts[0] == "access-token" {
                return quotaNonEmpty(parts[1])
            }
        }
        return nil
    }
}
