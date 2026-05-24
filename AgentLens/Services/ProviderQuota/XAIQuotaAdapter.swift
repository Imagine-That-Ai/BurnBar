import Foundation
import OpenBurnBarCore

// MARK: - xAI / Grok Quota Adapter
//
// Reports remaining usage for both the xAI consumer plans (SuperGrok Lite,
// SuperGrok, SuperGrok Heavy) and the developer pay-as-you-go tier
// ("GrokBuild" — xAI API prepaid credits).
//
// Two branches, picked by `XAIQuotaPlanTier`:
//
// 1. **GrokBuild** (or `.unknown` with a management key on file)
//    Hits the xAI Management API:
//      - `GET  https://api.x.ai/v1/billing/teams/{team_id}/prepaid/balance`
//        Returns `{ changes:[…], total:{ val: "<usd-cents-string>" } }`
//        where xAI's sign convention is **negative total = positive unspent**.
//        Remaining cents = `-Int(total.val)`.
//      - `POST https://api.x.ai/v1/billing/teams/{team_id}/usage`
//        Time-series with `usd` floats (dollars, NOT cents — confirmed by
//        the public docs example showing fractional values like
//        `0.75973725`). Used for rolling 24h / 7d / 30d burn buckets.
//      - Team id is auto-discovered via `GET /v1/teams` and cached in
//        `ProviderQuotaSnapshotStore`'s scratch store.
//      - Auth: `Authorization: Bearer <xai-mgmt-…>`. The management key is
//        separate from inference keys; see `BurnBarProviderAuthRegistry`.
//
// 2. **SuperGrok / Lite / Heavy** — Pacing branch
//    Reads `~/Library/Application Support/OpenBurnBar/xai/superGrok-events.jsonl`
//    (one JSONL line per Hermes-issued Grok prompt) and computes a rolling
//    2-hour prompt count. Caps are `XAIQuotaPlanTier.rollingTwoHourPromptCap`.
//    Snapshots are marked `confidence: .estimated`, `isEstimated: true`.
//
// 3. **Neither key nor active plan** → `.unavailable` snapshot pointing at
//    `https://console.x.ai`.
//
// Reference: xAI Management API
// (docs.x.ai/docs/management-api/billing, verified 2026-05-21).

struct XAIQuotaAdapter: ProviderQuotaAdapter {

    // MARK: - Constants

    static let consoleURL = "https://console.x.ai"
    static let plansURL = "https://grok.com/plans"
    static let managementBaseURL = URL(string: "https://api.x.ai")!
    static let rollingWindowSeconds: TimeInterval = 2 * 60 * 60

    /// Subdirectory inside `~/Library/Application Support/OpenBurnBar/`
    /// where Hermes / proxy code writes one event line per Grok prompt.
    static let superGrokLogRelativePath = "OpenBurnBar/xai/superGrok-events.jsonl"

    // MARK: - JSON shapes

    private struct PrepaidBalanceResponse: Codable {
        let total: ValWrapper
        let changes: [ChangeRecord]?
    }

    private struct ValWrapper: Codable {
        let val: String
    }

    private struct ChangeRecord: Codable {
        let createTime: String?
        let amount: ValWrapper
        let changeOrigin: String?
    }

    private struct TeamsResponse: Codable {
        let teams: [TeamRecord]?
    }

    private struct TeamRecord: Codable {
        let id: String
        let name: String?
    }

    private struct UsageResponse: Codable {
        let timeSeries: [UsageTimeSeries]?
    }

    private struct UsageTimeSeries: Codable {
        let dataPoints: [UsageDataPoint]?
    }

    private struct UsageDataPoint: Codable {
        let timestamp: String?
        let values: [UsageValue]?
    }

    private struct UsageValue: Codable {
        let name: String
        let value: Double
    }

    private struct SuperGrokEvent: Codable {
        let timestamp: Double          // ms since epoch
        let model: String?
        let plan: String?
    }

    // MARK: - Fetch

    func fetch(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot {
        let plan = context.xaiPlanProvider()
        let mgmtKey = resolveManagementKey(context: context)

        // Branch 1 — developer credits.
        if plan == .grokBuild || (plan == .unknown && mgmtKey != nil) {
            guard let mgmtKey else {
                return unavailableSnapshot(
                    for: .xAI,
                    source: .officialAPI,
                    message: "Add an xAI Management Key (xai-mgmt-…) to report GrokBuild credit balance."
                )
            }
            return try await fetchGrokBuildSnapshot(context: context, managementKey: mgmtKey)
        }

        // Branch 2 — consumer pacing.
        if plan.isSuperGrokConsumer {
            return await fetchSuperGrokSnapshot(context: context, plan: plan)
        }

        // Branch 3 — unknown / disconnected.
        return unavailableSnapshot(
            for: .xAI,
            source: .unavailable,
            message: "Pick a Grok plan tier (SuperGrok or GrokBuild) and connect either your SuperGrok login or an xAI Management Key."
        )
    }

    // MARK: - GrokBuild credits branch

    private func fetchGrokBuildSnapshot(
        context: ProviderQuotaAdapterContext,
        managementKey: String
    ) async throws -> ProviderQuotaSnapshot {
        let teamID = try await resolveTeamID(context: context, managementKey: managementKey)
        guard let teamID else {
            return unavailableSnapshot(
                for: .xAI,
                source: .officialAPI,
                message: "xAI Management Key authenticated but no team is associated. Visit console.x.ai to create a team."
            )
        }

        let now = Date()
        async let balanceBuckets = fetchBalanceBuckets(
            context: context,
            managementKey: managementKey,
            teamID: teamID
        )
        async let usageBuckets = fetchUsageBuckets(
            context: context,
            managementKey: managementKey,
            teamID: teamID,
            now: now
        )

        let buckets = await balanceBuckets + usageBuckets
        let statusMessage = buckets.isEmpty
            ? "xAI Management API authenticated; no credit or usage activity reported yet."
            : "xAI GrokBuild — prepaid credit balance + rolling usage."

        return ProviderQuotaSnapshot(
            provider: .xAI,
            providerID: .xAI,
            fetchedAt: now,
            source: .officialAPI,
            confidence: buckets.isEmpty ? .unavailable : .exact,
            managementURL: "\(Self.consoleURL)/team/api-keys",
            statusMessage: statusMessage,
            buckets: buckets
        )
    }

    private func fetchBalanceBuckets(
        context: ProviderQuotaAdapterContext,
        managementKey: String,
        teamID: String
    ) async -> [ProviderQuotaBucket] {
        let url = Self.managementBaseURL.appendingPathComponent("v1/billing/teams/\(teamID)/prepaid/balance", isDirectory: false)

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("Bearer \(managementKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            let (data, response) = try await context.session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return []
            }
            let payload = try JSONDecoder().decode(PrepaidBalanceResponse.self, from: data)
            guard let cents = Int(payload.total.val) else { return [] }
            // xAI's convention: PURCHASE makes amount negative, SPEND makes it
            // positive. So `total.val` ends up negative when there is unspent
            // credit. Invert to express USD remaining.
            let remainingDollars = max(0.0, Double(-cents) / 100.0)

            return [
                ProviderQuotaBucket(
                    key: "xai-prepaid-credit-balance",
                    label: "Prepaid credit balance",
                    windowKind: .lifetime,
                    usedValue: nil,
                    limitValue: nil,
                    remainingValue: remainingDollars,
                    usedPercent: nil,
                    resetsAt: nil,
                    unit: .currency,
                    isEstimated: false
                )
            ]
        } catch {
            return []
        }
    }

    private func fetchUsageBuckets(
        context: ProviderQuotaAdapterContext,
        managementKey: String,
        teamID: String,
        now: Date
    ) async -> [ProviderQuotaBucket] {
        let url = Self.managementBaseURL.appendingPathComponent("v1/billing/teams/\(teamID)/usage", isDirectory: false)
        let cutoff30d = now.addingTimeInterval(-30 * 24 * 60 * 60)
        let body: [String: Any] = [
            "analyticsRequest": [
                "timeRange": [
                    "startTime": iso8601(cutoff30d),
                    "endTime": iso8601(now),
                    "timezone": "UTC"
                ],
                "timeUnit": "TIME_UNIT_DAY",
                "values": [
                    ["name": "usd", "aggregation": "AGGREGATION_SUM"]
                ]
            ]
        ]
        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else { return [] }

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(managementKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.httpBody = httpBody

            let (data, response) = try await context.session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return []
            }
            let payload = try JSONDecoder().decode(UsageResponse.self, from: data)
            let points = (payload.timeSeries ?? []).flatMap { $0.dataPoints ?? [] }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let fallbackFormatter = ISO8601DateFormatter()

            var total24h = 0.0
            var total7d = 0.0
            var total30d = 0.0
            let cutoff24h = now.addingTimeInterval(-24 * 60 * 60)
            let cutoff7d = now.addingTimeInterval(-7 * 24 * 60 * 60)

            for point in points {
                guard let ts = point.timestamp,
                      let date = formatter.date(from: ts) ?? fallbackFormatter.date(from: ts) else {
                    continue
                }
                let usd = point.values?.first(where: { $0.name == "usd" })?.value ?? 0.0
                total30d += usd
                if date >= cutoff7d { total7d += usd }
                if date >= cutoff24h { total24h += usd }
            }

            return [
                ProviderQuotaBucket(
                    key: "xai-usage-24h",
                    label: "Spend (last 24h)",
                    windowKind: .rollingHours,
                    usedValue: total24h,
                    limitValue: nil,
                    remainingValue: nil,
                    usedPercent: nil,
                    resetsAt: nil,
                    unit: .currency,
                    isEstimated: false
                ),
                ProviderQuotaBucket(
                    key: "xai-usage-7d",
                    label: "Spend (last 7 days)",
                    windowKind: .rollingDays,
                    usedValue: total7d,
                    limitValue: nil,
                    remainingValue: nil,
                    usedPercent: nil,
                    resetsAt: nil,
                    unit: .currency,
                    isEstimated: false
                ),
                ProviderQuotaBucket(
                    key: "xai-usage-30d",
                    label: "Spend (last 30 days)",
                    windowKind: .monthly,
                    usedValue: total30d,
                    limitValue: nil,
                    remainingValue: nil,
                    usedPercent: nil,
                    resetsAt: nil,
                    unit: .currency,
                    isEstimated: false
                )
            ]
        } catch {
            return []
        }
    }

    /// Resolves the xAI team id for the management key. Cached in the
    /// snapshot store under the `xai/team-id` scratch key so we don't hit
    /// `/v1/teams` on every refresh.
    private func resolveTeamID(
        context: ProviderQuotaAdapterContext,
        managementKey: String
    ) async throws -> String? {
        if let cached = context.snapshotStore.loadScratchString(forKey: "xai/team-id"),
           !cached.isEmpty {
            return cached
        }

        // Allow an env override for power users / CI fixtures.
        if let envOverride = quotaNonEmpty(context.environment["XAI_TEAM_ID"]) {
            context.snapshotStore.saveScratchString(envOverride, forKey: "xai/team-id")
            return envOverride
        }

        let url = Self.managementBaseURL.appendingPathComponent("v1/teams", isDirectory: false)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(managementKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await context.session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return nil
        }
        let payload = try JSONDecoder().decode(TeamsResponse.self, from: data)
        guard let id = payload.teams?.first?.id, !id.isEmpty else { return nil }
        context.snapshotStore.saveScratchString(id, forKey: "xai/team-id")
        return id
    }

    // MARK: - SuperGrok pacing branch

    private func fetchSuperGrokSnapshot(
        context: ProviderQuotaAdapterContext,
        plan: XAIQuotaPlanTier
    ) async -> ProviderQuotaSnapshot {
        let now = Date()
        let logURL = Self.superGrokLogURL(homeDirectoryURL: context.homeDirectoryURL)

        guard let cap = plan.rollingTwoHourPromptCap else {
            return unavailableSnapshot(
                for: .xAI,
                source: .unavailable,
                message: "Unknown SuperGrok cap — pick a tier to enable pacing estimates."
            )
        }

        let events = readSuperGrokEvents(at: logURL, fileManager: context.fileManager)
        let cutoff = now.addingTimeInterval(-Self.rollingWindowSeconds)
        let inWindow = events.filter { event in
            let date = Date(timeIntervalSince1970: event.timestamp / 1000.0)
            return date >= cutoff && date <= now
        }
        let usedCount = Double(inWindow.count)
        let remaining = max(0.0, cap - usedCount)
        let usedPercent = cap > 0 ? min(max((usedCount / cap) * 100.0, 0), 100) : nil

        // Resets-at is `(earliest in-window event) + 2h`. If there are no
        // events yet, the window has full headroom and no scheduled reset.
        let resetsAt = inWindow
            .map { Date(timeIntervalSince1970: $0.timestamp / 1000.0) }
            .min()
            .map { $0.addingTimeInterval(Self.rollingWindowSeconds) }

        let bucket = ProviderQuotaBucket(
            key: "xai-supergrok-2h-rolling",
            label: "\(plan.shortName) prompts (rolling 2h)",
            windowKind: .rollingHours,
            usedValue: usedCount,
            limitValue: cap,
            remainingValue: remaining,
            usedPercent: usedPercent,
            resetsAt: resetsAt,
            unit: .requests,
            isEstimated: true
        )

        let confidence: ProviderQuotaConfidence
        let statusMessage: String
        if events.isEmpty {
            confidence = .estimated
            statusMessage = "\(plan.displayName): no SuperGrok prompts observed yet. Caps are community-estimated; run a Grok session via OpenBurnBar to populate the rolling window."
        } else {
            confidence = .estimated
            statusMessage = "\(plan.displayName): rolling 2-hour pacing window. Cap is community-estimated and may vary by account."
        }

        return ProviderQuotaSnapshot(
            provider: .xAI,
            providerID: .xAI,
            fetchedAt: now,
            source: .localSession,
            confidence: confidence,
            managementURL: Self.plansURL,
            statusMessage: statusMessage,
            buckets: [bucket]
        )
    }

    /// Returns the absolute URL of the SuperGrok event log under the user's
    /// Application Support directory. Resolved per-call so tests can
    /// inject a temp home directory.
    static func superGrokLogURL(homeDirectoryURL: URL) -> URL {
        homeDirectoryURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(superGrokLogRelativePath, isDirectory: false)
    }

    private func readSuperGrokEvents(
        at logURL: URL,
        fileManager: FileManager
    ) -> [SuperGrokEvent] {
        guard fileManager.fileExists(atPath: logURL.path),
              let data = try? Data(contentsOf: logURL),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }
        let decoder = JSONDecoder()
        var events: [SuperGrokEvent] = []
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let event = try? decoder.decode(SuperGrokEvent.self, from: lineData) else {
                continue
            }
            events.append(event)
        }
        return events
    }

    // MARK: - Helpers

    private func resolveManagementKey(context: ProviderQuotaAdapterContext) -> String? {
        quotaNonEmpty(context.resolvedAPIKeys["xai_management_key"] ?? nil)
            ?? quotaNonEmpty(context.resolvedAPIKeys["xai-management-key"] ?? nil)
            ?? cursorConnectorKey(for: "provider.xai.managementKey")
            ?? quotaNonEmpty(context.environment["XAI_MANAGEMENT_KEY"])
    }

    private func cursorConnectorKey(for account: String) -> String? {
        let keychain = KeychainStore()
        let raw = try? keychain.string(for: account, allowUserInteraction: false)
        return quotaNonEmpty(raw ?? nil)
    }

    private func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
