import Foundation

// MARK: - Kimi Quota Adapter

/// Fetches real Kimi (Moonshot) usage/quota from the Kimi billing API.
///
/// Ground truth source: `POST https://www.kimi.com/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages`
/// with JWT Bearer token authentication.
///
/// ## Auth flow
/// Kimi uses JWT tokens captured by OpenBurnBar after an explicit provider
/// login at `kimi.com` or `kimi.com/code/console`. The token is passed as both:
/// - `Authorization: Bearer <jwt>`
/// - `Cookie: kimi-auth=<jwt>`
///
/// Additional session headers extracted from the JWT payload:
/// - `x-msh-device-id`
/// - `x-msh-session-id`
/// - `x-traffic-id`
///
/// ## Resolution chain
/// 1. `KIMI_AUTH_TOKEN` environment variable
/// 2. Keychain-stored OpenBurnBar session token (`kimi_auth_token`)
/// 3. Falls to `.unavailable` with link to reconnect in OpenBurnBar
///
/// ## Data returned
/// - Weekly usage: tokens used / limit
/// - Rate limit window: requests / period
/// - Coding-specific plan data
///
/// Reference: CodexBar `KimiUsageFetcher.swift`
/// (github.com/steipete/CodexBar, verified 2026-05-03)

struct KimiQuotaAdapter: ProviderQuotaAdapter {

    // MARK: - Constants

    private static let usageURL = URL(string: "https://www.kimi.com/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages")!

    // MARK: - Types

    private struct KimiUsageResponse: Codable {
        let usages: [KimiUsageEntry]
    }

    private struct KimiUsageEntry: Codable {
        let scope: String
        let detail: KimiUsageDetail
        let limits: [KimiRateLimit]?
    }

    private struct KimiUsageDetail: Codable {
        let usedTokens: Int64?
        let totalTokens: Int64?
        let usedRequests: Int64?
        let totalRequests: Int64?
        let resetTime: String?

        enum CodingKeys: String, CodingKey {
            case usedTokens = "used_tokens"
            case totalTokens = "total_tokens"
            case usedRequests = "used_requests"
            case totalRequests = "total_requests"
            case resetTime = "reset_time"
        }
    }

    private struct KimiRateLimit: Codable {
        let detail: KimiUsageDetail
    }

    // MARK: - Fetch

    func fetch(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot {
        guard let authToken = resolveAuthToken(context: context) else {
            return unavailableSnapshot(
                for: .kimi,
                source: .unavailable,
                message: "Reconnect Kimi in OpenBurnBar, or set KIMI_AUTH_TOKEN."
            )
        }

        let decoder = JSONDecoder()
        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.setValue("kimi-auth=\(authToken)", forHTTPHeaderField: "Cookie")
        request.setValue("https://www.kimi.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.kimi.com/code/console", forHTTPHeaderField: "Referer")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("1", forHTTPHeaderField: "connect-protocol-version")
        request.setValue("en-US", forHTTPHeaderField: "x-language")
        request.setValue("web", forHTTPHeaderField: "x-msh-platform")
        request.setValue(TimeZone.current.identifier, forHTTPHeaderField: "r-timezone")

        // Extract session info from JWT payload
        if let sessionInfo = decodeSessionInfo(from: authToken) {
            if let deviceId = sessionInfo.deviceId {
                request.setValue(deviceId, forHTTPHeaderField: "x-msh-device-id")
            }
            if let sessionId = sessionInfo.sessionId {
                request.setValue(sessionId, forHTTPHeaderField: "x-msh-session-id")
            }
            if let trafficId = sessionInfo.trafficId {
                request.setValue(trafficId, forHTTPHeaderField: "x-traffic-id")
            }
        }

        let body = ["scope": ["FEATURE_CODING"]]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await context.session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw QuotaServiceError.invalidResponse("Kimi API returned non-HTTP response.")
        }

        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                return unavailableSnapshot(
                    for: .kimi,
                    source: .unavailable,
                    message: "Kimi auth token expired. Reconnect Kimi in OpenBurnBar."
                )
            }
            throw QuotaServiceError.invalidResponse("Kimi API returned HTTP \(httpResponse.statusCode).")
        }

        let usageResponse = try decoder.decode(KimiUsageResponse.self, from: data)
        guard let codingUsage = usageResponse.usages.first(where: { $0.scope == "FEATURE_CODING" }) else {
            throw QuotaServiceError.invalidResponse("Kimi usage response missing FEATURE_CODING scope.")
        }

        return buildSnapshot(detail: codingUsage.detail, rateLimit: codingUsage.limits?.first?.detail)
    }

    // MARK: - Snapshot Building

    private func buildSnapshot(detail: KimiUsageDetail, rateLimit: KimiUsageDetail?) -> ProviderQuotaSnapshot {
        var buckets: [ProviderQuotaBucket] = []
        let now = Date()

        // Weekly token usage
        if let used = detail.usedTokens, let total = detail.totalTokens, total > 0 {
            let pct = Double(used) / Double(total) * 100
            buckets.append(ProviderQuotaBucket(
                key: "kimi-weekly-tokens",
                label: "Weekly tokens",
                windowKind: .weekly,
                usedValue: Double(used),
                limitValue: Double(total),
                remainingValue: Double(max(0, total - used)),
                usedPercent: pct,
                resetsAt: detail.resetTime.flatMap(parseISO8601),
                unit: .tokens,
                isEstimated: false
            ))
        }

        // Weekly request usage
        if let used = detail.usedRequests, let total = detail.totalRequests, total > 0 {
            let pct = Double(used) / Double(total) * 100
            buckets.append(ProviderQuotaBucket(
                key: "kimi-weekly-requests",
                label: "Weekly requests",
                windowKind: .weekly,
                usedValue: Double(used),
                limitValue: Double(total),
                remainingValue: Double(max(0, total - used)),
                usedPercent: pct,
                resetsAt: detail.resetTime.flatMap(parseISO8601),
                unit: .requests,
                isEstimated: false
            ))
        }

        // Rate limit window (if different from weekly)
        if let rl = rateLimit {
            if let used = rl.usedRequests, let total = rl.totalRequests, total > 0 {
                let pct = Double(used) / Double(total) * 100
                buckets.append(ProviderQuotaBucket(
                    key: "kimi-rate-limit",
                    label: "Rate limit",
                    windowKind: .custom,
                    usedValue: Double(used),
                    limitValue: Double(total),
                    remainingValue: Double(max(0, total - used)),
                    usedPercent: pct,
                    resetsAt: rl.resetTime.flatMap(parseISO8601),
                    unit: .requests,
                    isEstimated: false
                ))
            }
        }

        guard !buckets.isEmpty else {
            return ProviderQuotaSnapshot(
                provider: .kimi,
                fetchedAt: now,
                source: .officialAPI,
                confidence: .exact,
                managementURL: "https://kimi.com/code/console",
                statusMessage: "Kimi Coding plan active. No usage limits reported.",
                buckets: []
            )
        }

        return ProviderQuotaSnapshot(
            provider: .kimi,
            fetchedAt: now,
            source: .officialAPI,
            confidence: .exact,
            managementURL: "https://kimi.com/code/console",
            statusMessage: "Kimi Coding · \(buckets.count) usage windows",
            buckets: buckets
        )
    }

    // MARK: - Auth Resolution

    private func resolveAuthToken(context: ProviderQuotaAdapterContext) -> String? {
        // 1. Environment variable
        if let envToken = context.environment["KIMI_AUTH_TOKEN"], !envToken.isEmpty {
            return envToken
        }

        // 2. Resolved API keys
        for key in ["kimi_auth_token", "kimi_jwt", "KIMI_AUTH_TOKEN"] {
            if let token = context.resolvedAPIKeys[key] ?? nil, !token.isEmpty {
                return token
            }
        }

        return nil
    }

    // MARK: - JWT Session Info

    private struct KimiSessionInfo {
        let deviceId: String?
        let sessionId: String?
        let trafficId: String?
    }

    private func decodeSessionInfo(from jwt: String) -> KimiSessionInfo? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }

        let payload = String(parts[1])
        var base64 = payload
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }

        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        return KimiSessionInfo(
            deviceId: json["device_id"] as? String,
            sessionId: json["session_id"] as? String,
            trafficId: json["traffic_id"] as? String
        )
    }

    // MARK: - Helpers

    private func parseISO8601(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    private func unavailableSnapshot(
        for provider: AgentProvider,
        source: ProviderQuotaSourceKind,
        message: String
    ) -> ProviderQuotaSnapshot {
        ProviderQuotaSnapshot(
            provider: provider,
            fetchedAt: Date(),
            source: source,
            confidence: .unavailable,
            managementURL: "https://kimi.com/code/console",
            statusMessage: message,
            buckets: []
        )
    }
}
