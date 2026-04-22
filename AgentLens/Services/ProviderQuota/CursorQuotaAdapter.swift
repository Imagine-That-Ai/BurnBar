import Foundation


struct CursorQuotaAdapter: ProviderQuotaAdapter {
    func fetch(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot {
        if let cookieHeader = resolveCursorCookieHeader(context: context) {
            do {
                let usageSummary = try await fetchCursorUsageSummary(cookieHeader: cookieHeader, session: context.session)
                let userInfo = try await fetchCursorUserInfo(cookieHeader: cookieHeader, session: context.session)
                let requestUsage = try? await fetchCursorLegacyRequestUsage(
                    userID: userInfo.id,
                    cookieHeader: cookieHeader,
                    session: context.session
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
                    return await fallbackCursorEstimate(
                        message: "Cursor rejected the configured cookie header. Refresh the session cookie from cursor.com and try again."
                    )
                }
                return await fallbackCursorEstimate(
                    message: error.localizedDescription
                )
            } catch {
                return await fallbackCursorEstimate(
                    message: "Cursor web quota fetch failed. OpenBurnBar is showing recent routed-token estimates instead."
                )
            }
        }

        return await fallbackCursorEstimate(
            message: "Add a Cursor cookie header to fetch billing-cycle quota. OpenBurnBar can still estimate routed tokens from the local connector."
        )
    }

    // MARK: - Cursor Helpers

    private func fallbackCursorEstimate(message: String) async -> ProviderQuotaSnapshot {
        let (isConnected, statusMessage, buckets) = await MainActor.run {
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

            return (isConnected, statusMessage, buckets)
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

    private func resolveCursorCookieHeader(context: ProviderQuotaAdapterContext) -> String? {
        if let environmentValue = context.environment["CURSOR_COOKIE_HEADER"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !environmentValue.isEmpty {
            return environmentValue
        }
        if let storedValue = (context.resolvedAPIKeys["cursor_cookie"] ?? nil)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !storedValue.isEmpty {
            return storedValue
        }
        return nil
    }

    private func fetchCursorUsageSummary(cookieHeader: String, session: URLSession) async throws -> CursorUsageSummary {
        guard let url = URL(string: "https://cursor.com/api/usage-summary") else {
            throw QuotaServiceError.invalidResponse("Cursor usage-summary URL is invalid.")
        }
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

    private func fetchCursorUserInfo(cookieHeader: String, session: URLSession) async throws -> CursorUserInfo {
        guard let url = URL(string: "https://cursor.com/api/auth/me") else {
            throw QuotaServiceError.invalidResponse("Cursor auth URL is invalid.")
        }
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
        cookieHeader: String,
        session: URLSession
    ) async throws -> CursorLegacyUsageResponse {
        guard var components = URLComponents(string: "https://cursor.com/api/usage") else {
            throw QuotaServiceError.invalidResponse("Cursor legacy usage URL is invalid.")
        }
        components.queryItems = [URLQueryItem(name: "user", value: userID)]
        guard let url = components.url else {
            throw QuotaServiceError.invalidResponse("Cursor legacy usage request URL is invalid.")
        }
        var request = URLRequest(url: url)
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
        let billingCycleEnd = usageSummary.billingCycleEnd.flatMap(FlexibleQuotaBucketNormalizer.parseDateValue)
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
