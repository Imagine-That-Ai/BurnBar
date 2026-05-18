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
///    Requires an explicit OpenBurnBar-owned Factory login session.
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

    /// Falls back to Pro (20M tokens/month) so a fresh install still renders
    /// displayable quota buckets. Users can override in Settings → Providers
    /// once they confirm their plan tier. Marked `isEstimated` on the bucket
    /// so the UI reflects the inferred-vs-confirmed distinction.
    private static let inferredMonthlyTokenCap: Double = 20_000_000

    private func fetchDroidSessionSnapshot(context: ProviderQuotaAdapterContext) async -> ProviderQuotaSnapshot? {
        let sessionsURL = context.homeDirectoryURL
            .appendingPathComponent(".factory", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
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

        // Lane-segregated accumulators. Sessions are filtered by
        // FactorySessionClassifier so user-configured custom proxies
        // (third-party proxies, localhost Ollama, BYOK keys, etc.) never poison
        // the Factory plan cap. Standard + Droid Core both count against
        // Standard Usage until it's exhausted, but we track them
        // separately so the popover can show which lane is burning.
        var standardFiveHour: Int64 = 0
        var standardSevenDay: Int64 = 0
        var standardThirtyDay: Int64 = 0
        var coreFiveHour: Int64 = 0
        var coreSevenDay: Int64 = 0
        var coreThirtyDay: Int64 = 0
        var customProxyTokens: Int64 = 0
        var factoryUnknownTokens: Int64 = 0
        var cacheReadTokens: Int64 = 0
        var filesScanned = 0
        var filesWithUsage = 0
        var factoryBilledSessions = 0
        var customProxySessions = 0
        var modelCounts: [String: Int] = [:]
        var laneCounts: [FactorySessionLane: Int] = [:]

        while let fileURL = enumerator.nextObject() as? URL {
            guard fileURL.pathExtension == "json",
                  fileURL.lastPathComponent.hasSuffix(".settings.json") else { continue }

            filesScanned += 1

            guard let data = try? Data(contentsOf: fileURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let usage = json["tokenUsage"] as? [String: Any] else { continue }

            let total = FactorySessionClassifier.totalTokens(in: usage)
            guard total > 0 else { continue }

            filesWithUsage += 1
            let cacheRead = (usage["cacheReadTokens"] as? Int64)
                ?? (usage["cacheReadTokens"] as? Int).map(Int64.init)
                ?? 0
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

            // Track models — only for sessions that actually counted, to
            // avoid the "top model" line being dominated by custom proxy
            // entries that don't touch Factory billing.
            let lane = FactorySessionClassifier.lane(for: json)
            laneCounts[lane, default: 0] += 1

            switch lane {
            case .customProxy:
                customProxyTokens += total
                customProxySessions += 1
                continue
            case .factoryUnknown:
                factoryUnknownTokens += total
                // Fall through — treat unknown Factory-billed models as
                // Standard (the conservative choice — better to over-report
                // Standard burn than to silently misattribute it to Core).
                if sessionDate >= thirtyDaysAgo { standardThirtyDay += total }
                if sessionDate >= sevenDaysAgo  { standardSevenDay  += total }
                if sessionDate >= fiveHoursAgo  { standardFiveHour  += total }
            case .standard:
                if sessionDate >= thirtyDaysAgo { standardThirtyDay += total }
                if sessionDate >= sevenDaysAgo  { standardSevenDay  += total }
                if sessionDate >= fiveHoursAgo  { standardFiveHour  += total }
            case .droidCore:
                if sessionDate >= thirtyDaysAgo { coreThirtyDay += total }
                if sessionDate >= sevenDaysAgo  { coreSevenDay  += total }
                if sessionDate >= fiveHoursAgo  { coreFiveHour  += total }
            }

            factoryBilledSessions += 1

            if let model = json["model"] as? String {
                modelCounts[model] = (modelCounts[model] ?? 0) + 1
            }
        }

        guard filesWithUsage > 0 else { return nil }

        // Combined Standard + Droid Core token totals for the "Total
        // Factory burn" buckets. Until Standard Usage is exhausted,
        // both lanes draw from the same pool, so this is the number
        // users actually need to see.
        let fiveHourTokens = standardFiveHour + coreFiveHour
        let sevenDayTokens = standardSevenDay + coreSevenDay
        let thirtyDayTokens = standardThirtyDay + coreThirtyDay

        var buckets: [ProviderQuotaBucket] = []
        let calendar = Calendar.current

        // Plan-tier cap drives the displayable percentage. If the user has not
        // chosen a tier yet, fall back to Pro (20M) so the card still renders
        // meaningful numbers — marked `isEstimated` so the UI reflects that
        // it's inferred rather than confirmed.
        let planTier = context.factoryPlanProvider()
        let confirmedCap = planTier.monthlyTokenCap
        let monthlyCap = confirmedCap ?? Self.inferredMonthlyTokenCap
        let isInferredCap = confirmedCap == nil

        func percent(_ used: Int64) -> Double {
            guard monthlyCap > 0 else { return 0 }
            return min(max(Double(used) / monthlyCap * 100, 0), 100)
        }

        func remaining(_ used: Int64) -> Double {
            max(monthlyCap - Double(used), 0)
        }

        // 5-hour rolling Standard Usage window. Factory enforces independent
        // 5h / 7d / 30d caps — Standard Usage is consumed first, then Droid
        // Core (free, separate pool) or Extra Usage (prepaid) take over.
        // Per-window caps aren't published; we display the 5h burn against
        // the monthly cap so users can see "% of plan" at this time scale.
        if fiveHourTokens > 0 {
            buckets.append(ProviderQuotaBucket(
                key: "factory-5h",
                label: "5-hour rolling",
                windowKind: .rollingHours,
                usedValue: Double(fiveHourTokens),
                limitValue: monthlyCap,
                remainingValue: remaining(fiveHourTokens),
                usedPercent: percent(fiveHourTokens),
                resetsAt: calendar.date(byAdding: .hour, value: 5, to: now),
                unit: .tokens,
                isEstimated: isInferredCap
            ))
        }

        // 7-day rolling Standard Usage window.
        if sevenDayTokens > 0 {
            buckets.append(ProviderQuotaBucket(
                key: "factory-7d",
                label: "7-day rolling",
                windowKind: .rollingDays,
                usedValue: Double(sevenDayTokens),
                limitValue: monthlyCap,
                remainingValue: remaining(sevenDayTokens),
                usedPercent: percent(sevenDayTokens),
                resetsAt: calendar.date(byAdding: .day, value: 7, to: now),
                unit: .tokens,
                isEstimated: isInferredCap
            ))
        }

        // 30-day window — the authoritative "you're at X% of your plan" line.
        if thirtyDayTokens > 0 {
            // Factory rate-limit windows are rolling, not calendar-aligned,
            // so the 30-day window resets 30 days from first use (not the
            // first of next month). Use a 30-day rolling reset to match the
            // pricing docs.
            let rollingMonthlyReset = calendar.date(byAdding: .day, value: 30, to: now)
            let monthlyLabel: String = {
                switch planTier {
                case .unknown: return "Monthly (inferred Pro)"
                case .pro, .plus, .max: return "Monthly · \(planTier.shortName)"
                }
            }()
            buckets.append(ProviderQuotaBucket(
                key: "factory-30d",
                label: monthlyLabel,
                windowKind: .monthly,
                usedValue: Double(thirtyDayTokens),
                limitValue: monthlyCap,
                remainingValue: remaining(thirtyDayTokens),
                usedPercent: percent(thirtyDayTokens),
                resetsAt: rollingMonthlyReset,
                unit: .tokens,
                isEstimated: isInferredCap
            ))
        }

        // Lane breakdown — informational, lets users see how much of
        // their Factory burn is Premium frontier models (Standard lane,
        // always counts) vs Droid Core open-weight models (which fall
        // back to a separate free pool once Standard is exhausted).
        // Filtered out of the displayable quota signal so it never
        // double-counts in headline % calcs.
        if standardThirtyDay > 0 {
            buckets.append(ProviderQuotaBucket(
                key: "factory-standard-30d",
                label: "Standard (Premium models, 30d)",
                windowKind: .monthly,
                usedValue: Double(standardThirtyDay),
                limitValue: monthlyCap,
                remainingValue: max(monthlyCap - Double(standardThirtyDay), 0),
                usedPercent: monthlyCap > 0
                    ? min(max(Double(standardThirtyDay) / monthlyCap * 100, 0), 100)
                    : nil,
                resetsAt: nil,
                unit: .tokens,
                isEstimated: isInferredCap
            ))
        }
        if coreThirtyDay > 0 {
            buckets.append(ProviderQuotaBucket(
                key: "factory-droid-core-30d",
                label: "Droid Core (open-weight, 30d)",
                windowKind: .monthly,
                usedValue: Double(coreThirtyDay),
                limitValue: nil,  // Separate free pool — no public cap.
                remainingValue: nil,
                usedPercent: nil,
                resetsAt: nil,
                unit: .tokens,
                isEstimated: false
            ))
        }
        // Custom proxy passthrough — diagnostic only. Surfaces how many
        // tokens the user ran through their own proxies so the lane
        // segregation is transparent. Filtered from the displayable
        // signal by ProviderQuotaSnapshot.isDisplayableQuotaSignal.
        if customProxyTokens > 0 {
            buckets.append(ProviderQuotaBucket(
                key: "factory-custom-proxy-30d",
                label: "Custom proxy passthrough (30d, not Factory-billed)",
                windowKind: .monthly,
                usedValue: Double(customProxyTokens),
                limitValue: nil,
                remainingValue: nil,
                usedPercent: nil,
                resetsAt: nil,
                unit: .tokens,
                isEstimated: false
            ))
        }

        // Cache efficiency — informational only; intentionally filtered out
        // of the displayable quota signal (`isDisplayableQuotaSignal` excludes
        // "cache"/"hit rate" markers) but kept in the snapshot for diagnostics.
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

        // Top model — only across Factory-billed sessions so the line
        // isn't dominated by custom proxy / OpenCode-Go entries that don't
        // touch Factory's plan.
        let topModel = modelCounts.max(by: { $0.value < $1.value }).map { "\($0.key) (\($0.value) sessions)" } ?? ""

        let planSuffix: String
        switch planTier {
        case .unknown:
            planSuffix = " Set your plan tier in Settings → Providers (or connect Factory so OpenBurnBar can auto-detect it). Standard Usage is consumed first; falls back to Droid Core (free, separate pool) or Extra Usage (prepaid) when limits hit."
        case .pro, .plus, .max:
            planSuffix = " Standard Usage is consumed first; falls back to Droid Core (free, separate pool) or Extra Usage (prepaid) when limits hit."
        }
        let proxySuffix = customProxySessions > 0
            ? " Excluded \(customProxySessions) custom-proxy session(s) — those route through your own proxies and don't count against Factory's plan."
            : ""

        let statusMessage = "Real token counts from \(factoryBilledSessions) Factory-billed droid session(s). \(topModel).\(planSuffix)\(proxySuffix)"

        return ProviderQuotaSnapshot(
            provider: .factory,
            fetchedAt: now,
            source: .localSession,
            confidence: isInferredCap ? .estimated : .exact,
            managementURL: "https://app.factory.ai",
            statusMessage: statusMessage,
            buckets: buckets
        )
    }


    // MARK: - Personal Account Dashboard Scraper

    /// Tries the app-owned-session dashboard scraper for personal (non-org) Factory accounts.
    private func fetchFactoryPersonalSnapshot(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot {
        guard let cookieHeader = resolveFactorySessionCookie(context: context),
              let usage = await FactoryDashboardScraper.fetchPersonalUsage(cookieHeader: cookieHeader, session: context.session) else {
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
            statusMessage: "\(planLabel)\(emailSuffix) — Factory dashboard via OpenBurnBar login session.",
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

        var buckets = [
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

        // Droid Core lane — only present when the billing API exposes
        // it. Renders as a separate bucket so users see at a glance
        // whether they've burnt through the free open-weight pool too.
        if let core = usage.droidCore,
           let bucket = makeFactoryBucket(
                key: "factory-droid-core",
                label: "Droid Core (open-weight)",
                lane: core,
                resetsAt: usage.periodEnd
           ) {
            buckets.append(bucket)
        }

        // Extra Usage prepaid wallet — currency-unit bucket (USD).
        // Surfaces the credit balance even when zero so users can see
        // the toggle is on and ready. Filtered from the headline
        // displayable signal by isDisplayableQuotaSignal because it's
        // not a percent-of-plan thing — it's a backup wallet.
        if let extra = usage.extraUsage, extra.balanceUSD > 0 || extra.enabled {
            let stateSuffix = extra.enabled ? "" : " (disabled)"
            buckets.append(ProviderQuotaBucket(
                key: "factory-extra-usage",
                label: "Extra Usage wallet\(stateSuffix)",
                windowKind: .lifetime,
                usedValue: nil,
                limitValue: nil,
                remainingValue: extra.balanceUSD,
                usedPercent: nil,
                resetsAt: nil,
                unit: .currency,
                isEstimated: false
            ))
        }

        guard !buckets.isEmpty else {
            throw QuotaServiceError.invalidResponse("Factory returned usage data without recognizable token lanes.")
        }

        let planParts = [auth.tier, auth.planName]
            .compactMap { quotaNonEmpty($0) }
            .joined(separator: " · ")
        let authSummary = planParts.isEmpty ? credentials.sourceLabel : "\(credentials.sourceLabel) · \(planParts)"
        let statusBadge: String = {
            switch (auth.subscriptionStatus ?? "").lowercased() {
            case "", "active": return ""
            case "trialing":   return " · trial"
            case "past_due":   return " · past_due"
            case "canceled", "cancelled": return " · canceled"
            default: return " · \(auth.subscriptionStatus ?? "")"
            }
        }()

        return ProviderQuotaSnapshot(
            provider: .factory,
            fetchedAt: Date(),
            source: .officialAPI,
            confidence: .exact,
            managementURL: "https://app.factory.ai",
            statusMessage: "Factory quota fetched from subscription usage API via \(authSummary)\(statusBadge).",
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
        // 2. OpenBurnBar-owned login session captured through explicit provider setup.
        if let loginCookie = resolveFactorySessionCookie(context: context) {
            return FactorySessionCredentialEnvelope(
                cookieHeader: loginCookie,
                bearerToken: FactoryCookieExtractor.extractBearerToken(from: loginCookie)
                    ?? factoryBearerToken(fromCookieHeader: loginCookie),
                sourceLabel: "OpenBurnBar login session"
            )
        }

        return nil
    }

    private func resolveFactorySessionCookie(context: ProviderQuotaAdapterContext) -> String? {
        if let envCookie = quotaNonEmpty(context.environment["FACTORY_COOKIE_HEADER"]) {
            return envCookie
        }
        for identifier in ["factory_cookie_header", "factory_cookie"] {
            if let stored = quotaNonEmpty(context.resolvedAPIKeys[identifier] ?? nil) {
                return stored
            }
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

        let planName = quotaNonEmpty(plan?["name"] as? String)
        let tier = quotaNonEmpty(subscription?["factoryTier"] as? String)
        let status = quotaNonEmpty(orbSubscription?["status"] as? String)
            ?? quotaNonEmpty(subscription?["status"] as? String)

        return FactoryAuthResponseEnvelope(
            planName: planName,
            tier: tier,
            organizationName: quotaNonEmpty(organization?["name"] as? String),
            subscriptionStatus: status,
            inferredPlanTier: Self.inferPlanTier(tier: tier, planName: planName)
        )
    }

    /// Maps Factory's reported `factoryTier` / plan name onto the
    /// OpenBurnBar enum. Accepts both the short tier string ("pro",
    /// "plus", "max") and the human-readable plan name shipped via Orb
    /// ("Pro Plan", "Plus", "Max — Enterprise Trial", etc.). Returns
    /// `.unknown` when the response is missing or doesn't match any
    /// known tier so callers can fall back to the user-selected tier.
    static func inferPlanTier(tier: String?, planName: String?) -> FactoryQuotaPlanTier {
        let haystack = ((tier ?? "") + " " + (planName ?? "")).lowercased()
        // Order matters — match the most specific tier first so "max
        // pro plan" is recognized as Max, not Pro.
        if haystack.contains("max") || haystack.contains("ultra") {
            return .max
        }
        if haystack.contains("plus") {
            return .plus
        }
        if haystack.contains("pro") {
            return .pro
        }
        // Enterprise / Teams / unrecognized — leave `.unknown` so the UI
        // doesn't pretend to know the cap. Enterprise plans aren't
        // affected by rate-limit caps anyway per Factory's docs.
        return .unknown
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

        // Droid Core lane — open-weight models on a separate free pool.
        // Factory's API may expose this under `droidCore`, `core`, or
        // `coreUsage` depending on release date; check all three.
        let droidCoreDict = usage["droidCore"] as? [String: Any]
            ?? usage["core"] as? [String: Any]
            ?? usage["coreUsage"] as? [String: Any]
        let droidCore = droidCoreDict.map { factoryLane(from: $0) }

        // Extra Usage prepaid credit wallet. Lives at the top level of
        // the usage payload (sibling to `standard` / `premium`).
        let extraUsage = parseExtraUsage(from: dictionary, usage: usage)

        return FactoryUsageEnvelope(
            periodEnd: periodEnd,
            standard: standard,
            premium: premium,
            droidCore: droidCore,
            extraUsage: extraUsage
        )
    }

    /// Parses the Extra Usage prepaid wallet from the billing payload.
    /// Accepts both new (`extraUsage`) and legacy (`extra_usage`,
    /// `additionalUsage`, `prepaidBalance`) field names. Treats a
    /// missing `enabled` flag as `true` when there's a positive balance
    /// because Factory's docs say the toggle is sticky — if there's
    /// money on the wallet, it'll be used.
    private func parseExtraUsage(
        from root: [String: Any],
        usage: [String: Any]
    ) -> FactoryUsageEnvelope.ExtraUsage? {
        let candidates: [[String: Any]?] = [
            usage["extraUsage"] as? [String: Any],
            usage["extra_usage"] as? [String: Any],
            usage["additionalUsage"] as? [String: Any],
            usage["prepaidBalance"] as? [String: Any],
            root["extraUsage"] as? [String: Any],
            root["extra_usage"] as? [String: Any]
        ]
        for dict in candidates.compactMap({ $0 }) {
            let balance = FlexibleQuotaBucketNormalizer.number(
                in: dict,
                keys: ["balanceUSD", "balance_usd", "balance", "remainingUSD", "remaining_usd", "remainingCents", "remaining_cents"]
            )
            guard var balanceUSD = balance else { continue }
            // Normalize cents → dollars when the key suggests cents.
            if dict["balanceCents"] != nil || dict["balance_cents"] != nil
                || dict["remainingCents"] != nil || dict["remaining_cents"] != nil {
                balanceUSD /= 100
            }
            let enabled = (dict["enabled"] as? Bool)
                ?? (dict["isEnabled"] as? Bool)
                ?? (balanceUSD > 0)
            return FactoryUsageEnvelope.ExtraUsage(balanceUSD: balanceUSD, enabled: enabled)
        }
        return nil
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
