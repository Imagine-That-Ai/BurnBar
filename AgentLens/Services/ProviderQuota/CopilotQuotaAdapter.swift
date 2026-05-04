import Foundation

// MARK: - Copilot Quota Adapter

/// Fetches real Copilot rate-limit data from GitHub's `/copilot_internal/user` endpoint.
///
/// Ground truth: `POST https://api.github.com/copilot_internal/user`
/// with `Authorization: token ghp_...` (GitHub PAT with copilot scope).
///
/// Response schema (verified against CodexBar `CopilotUsageModels.swift`):
/// ```json
/// {
///   "copilot_plan": "pro",
///   "quota_snapshots": {
///     "premium_interactions": { "entitlement": 300.0, "remaining": 180.0, "percent_remaining": 60.0, "quota_id": "..." },
///     "chat": { "entitlement": 0.0, "remaining": 0.0, "percent_remaining": 0.0, "quota_id": "" }
///   },
///   "assigned_date": "2026-01-01",
///   "quota_reset_date": "2026-06-01"
/// }
/// ```
///
/// Reference: CodexBar (github.com/steipete/CodexBar) — `CopilotUsageModels.swift`, `CopilotUsageFetcher.swift`

struct CopilotQuotaAdapter: ProviderQuotaAdapter {

    // MARK: - Response Models

    private struct CopilotUsageResponse: Decodable {
        let copilotPlan: String?
        let quotaSnapshots: QuotaSnapshots?
        let quotaResetDate: String?
        let assignedDate: String?

        enum CodingKeys: String, CodingKey {
            case copilotPlan = "copilot_plan"
            case quotaSnapshots = "quota_snapshots"
            case quotaResetDate = "quota_reset_date"
            case assignedDate = "assigned_date"
        }

        struct QuotaSnapshots: Decodable {
            let premiumInteractions: QuotaSnapshot?
            let chat: QuotaSnapshot?

            enum CodingKeys: String, CodingKey {
                case premiumInteractions = "premium_interactions"
                case chat
            }
        }
    }

    /// A single quota snapshot from the Copilot API.
    ///
    /// Fields:
    /// - `entitlement`: total amount (the "limit") — e.g. 300 for 300 premium requests/month
    /// - `remaining`: how much is left
    /// - `percentRemaining`: percentage remaining (0-100)
    /// - `quotaId`: identifier string (empty = placeholder)
    private struct QuotaSnapshot: Decodable {
        let entitlement: Double
        let remaining: Double
        let percentRemaining: Double?
        let quotaId: String

        enum CodingKeys: String, CodingKey {
            case entitlement
            case remaining
            case percentRemaining = "percent_remaining"
            case quotaId = "quota_id"
        }

        /// Placeholder snapshots have all-zero fields + empty quotaId.
        var isPlaceholder: Bool {
            entitlement == 0 && remaining == 0 && (percentRemaining ?? 0) == 0 && quotaId.isEmpty
        }

        /// Converts percentRemaining (0-100) to usedPercent (0-100).
        var usedPercent: Double? {
            guard let percentRemaining, entitlement > 0 else { return nil }
            let remainingPct = max(0, min(100, percentRemaining))
            return max(0, 100 - remainingPct)
        }
    }

    // MARK: - Public API

    func fetch(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot {
        guard let pat = resolveCopilotPAT(context: context) else {
            return unavailableSnapshot(
                for: .copilot,
                source: .unavailable,
                message: "Add a GitHub personal access token with copilot scope to report Copilot quota."
            )
        }

        guard let url = URL(string: "https://api.github.com/copilot_internal/user") else {
            throw QuotaServiceError.invalidResponse("Copilot internal URL is invalid.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("token \(pat)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("2025-04-01", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("vscode/1.96.2", forHTTPHeaderField: "Editor-Version")
        request.setValue("copilot-chat/0.26.7", forHTTPHeaderField: "Editor-Plugin-Version")
        request.setValue("GitHubCopilotChat/0.26.7", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await context.session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw QuotaServiceError.invalidResponse("Copilot returned a non-HTTP response.")
        }

        switch http.statusCode {
        case 401, 403:
            return unavailableSnapshot(
                for: .copilot,
                source: .officialAPI,
                message: "GitHub rejected the configured token. Verify the token has copilot scope and is not expired."
            )
        case 404:
            return unavailableSnapshot(
                for: .copilot,
                source: .officialAPI,
                message: "Copilot internal endpoint not available. The GitHub token may lack the required copilot scope."
            )
        default:
            guard (200..<300).contains(http.statusCode) else {
                throw QuotaServiceError.httpStatus(provider: .copilot, code: http.statusCode)
            }
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let usage = try decoder.decode(CopilotUsageResponse.self, from: data)

        let resetsAt = usage.quotaResetDate
            .flatMap { ISO8601DateFormatter().date(from: $0) }

        var buckets: [ProviderQuotaBucket] = []

        // Premium interactions — primary window
        if let premium = usage.quotaSnapshots?.premiumInteractions,
           !premium.isPlaceholder {
            if let bucket = makeBucket(
                key: "copilot-premium",
                label: "Premium requests",
                snapshot: premium,
                resetsAt: resetsAt,
                isPrimary: true
            ) {
                buckets.append(bucket)
            }
        }

        // Chat — secondary window
        if let chat = usage.quotaSnapshots?.chat,
           !chat.isPlaceholder {
            if let bucket = makeBucket(
                key: "copilot-chat",
                label: "Chat requests",
                snapshot: chat,
                resetsAt: resetsAt,
                isPrimary: false
            ) {
                buckets.append(bucket)
            }
        }

        guard !buckets.isEmpty else {
            return unavailableSnapshot(
                for: .copilot,
                source: .officialAPI,
                message: "Copilot returned a valid response but no recognizable rate-limit windows were found."
            )
        }

        let plan = usage.copilotPlan?.capitalized ?? "Copilot"
        return ProviderQuotaSnapshot(
            provider: .copilot,
            fetchedAt: Date(),
            source: .officialAPI,
            confidence: .exact,
            managementURL: "https://github.com/settings/copilot",
            statusMessage: "\(plan) quota from GitHub Copilot usage API.",
            buckets: buckets
        )
    }

    // MARK: - Helpers

    private func resolveCopilotPAT(context: ProviderQuotaAdapterContext) -> String? {
        for identifier in ["copilot", "github", "Copilot", "GitHub"] {
            if let stored = context.resolvedAPIKeys[identifier] ?? nil,
               !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return stored
            }
        }
        if let envToken = context.environment["GITHUB_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !envToken.isEmpty {
            return envToken
        }
        return nil
    }

    private func makeBucket(
        key: String,
        label: String,
        snapshot: QuotaSnapshot,
        resetsAt: Date?,
        isPrimary: Bool
    ) -> ProviderQuotaBucket? {
        let usedPercent = snapshot.usedPercent
        let usedValue: Double? = {
            if snapshot.entitlement > 0 {
                return max(snapshot.entitlement - snapshot.remaining, 0)
            }
            return nil
        }()

        let remainingValue = snapshot.remaining > 0 || snapshot.entitlement > 0
            ? max(snapshot.remaining, 0)
            : nil

        guard usedPercent != nil || usedValue != nil else { return nil }

        return ProviderQuotaBucket(
            key: key,
            label: label,
            windowKind: isPrimary ? .monthly : .custom,
            usedValue: usedValue ?? usedPercent,
            limitValue: usedPercent != nil && usedValue == nil ? 100 : snapshot.entitlement,
            remainingValue: remainingValue,
            usedPercent: usedPercent,
            resetsAt: resetsAt,
            unit: usedPercent != nil && usedValue == nil ? .percent : .requests,
            isEstimated: false
        )
    }
}
