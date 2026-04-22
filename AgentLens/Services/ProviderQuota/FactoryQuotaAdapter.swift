import Foundation


struct FactoryQuotaAdapter: ProviderQuotaAdapter {
    func fetch(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot {
        if let exactSnapshot = try? await fetchFactoryExactSnapshot(context: context) {
            return exactSnapshot
        }
        return await fetchFactoryEstimatedSnapshot(context: context)
    }

    // MARK: - Estimated Snapshot

    private func fetchFactoryEstimatedSnapshot(context: ProviderQuotaAdapterContext) async -> ProviderQuotaSnapshot {
        let tier = context.factoryPlanProvider()
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
        let used = await MainActor.run {
            Double(context.dataStore.usages(for: .factory, in: monthRange).reduce(0) { $0 + $1.totalTokens })
        }
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

    // MARK: - Exact Snapshot

    private func fetchFactoryExactSnapshot(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot {
        guard let credentials = loadFactoryCredentials(context: context) else {
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

    // MARK: - Factory Helpers

    private func loadFactoryCredentials(context: ProviderQuotaAdapterContext) -> FactorySessionCredentialEnvelope? {
        let envCookie = quotaNonEmpty(context.environment["FACTORY_COOKIE_HEADER"])
        let envBearer = quotaNonEmpty(context.environment["FACTORY_BEARER_TOKEN"])
        if envCookie != nil || envBearer != nil {
            return FactorySessionCredentialEnvelope(
                cookieHeader: envCookie,
                bearerToken: envBearer ?? factoryBearerToken(fromCookieHeader: envCookie),
                sourceLabel: "environment override"
            )
        }
        return nil
    }

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
        let body = try JSONSerialization.data(withJSONObject: ["useCache": true], options: [])
        let data = try await performFactoryRequest(
            url: url,
            method: "POST",
            credentials: credentials,
            session: session,
            body: body
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
        guard let allowance, allowance > 0 else {
            return nil
        }
        return min(max((used / allowance) * 100, 0), 100)
    }

    private func makeFactoryBucket(
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
