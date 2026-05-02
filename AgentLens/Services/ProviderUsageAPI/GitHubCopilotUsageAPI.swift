import Foundation

// MARK: - GitHub Copilot Usage API

/// Fetches usage metrics from the GitHub Copilot REST API.
/// Auth: GitHub PAT with `manage_billing:copilot` or `read:org` scope.
/// Endpoint: GET /user/copilot/metrics
final class GitHubCopilotUsageAPI: ProviderUsageAPI, Sendable {
    let providerName = "GitHub Copilot"
    let authMethod: ProviderAuthMethod = .pat

    private let pat: String
    private let baseURL = "https://api.github.com"
    private let session: URLSession

    init(pat: String, session: URLSession = .shared) {
        self.pat = pat
        self.session = session
    }

    func validate() async throws -> Bool {
        var request = URLRequest(url: URL(string: "\(baseURL)/user")!)
        request.setValue("Bearer \(pat)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { return false }
        return httpResponse.statusCode == 200
    }

    func fetchUsage(since: Date) async throws -> [ProviderUsageRecord] {
        // Try user-level metrics first
        let records = try await fetchUserMetrics(since: since)
        if !records.isEmpty { return records }

        // Fall back to org-level if user has org access
        return try await fetchOrgMetrics(since: since)
    }

    private func fetchUserMetrics(since: Date) async throws -> [ProviderUsageRecord] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")

        guard var components = URLComponents(string: "\(baseURL)/user/copilot/metrics") else { return [] }
        components.queryItems = [
            URLQueryItem(name: "since", value: formatter.string(from: since)),
            URLQueryItem(name: "until", value: formatter.string(from: Date()))
        ]
        guard let metricsURL = components.url else { return [] }

        var request = URLRequest(url: metricsURL)
        request.setValue("Bearer \(pat)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            return []
        }

        // 404 means the endpoint isn't available for this user/scope
        if httpResponse.statusCode == 404 || httpResponse.statusCode == 403 {
            return []
        }

        guard httpResponse.statusCode == 200 else {
            throw ProviderUsageAPIError.httpError(httpResponse.statusCode)
        }

        return parseMetricsResponse(data)
    }

    private func fetchOrgMetrics(since: Date) async throws -> [ProviderUsageRecord] {
        // List user's orgs first
        guard let orgsURL = URL(string: "\(baseURL)/user/orgs") else { return [] }
        var orgRequest = URLRequest(url: orgsURL)
        orgRequest.setValue("Bearer \(pat)", forHTTPHeaderField: "Authorization")
        orgRequest.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (orgData, orgResponse) = try await session.data(for: orgRequest)
        guard let httpResponse = orgResponse as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let orgs = try? JSONSerialization.jsonObject(with: orgData) as? [[String: Any]] else {
            return []
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")

        var allRecords: [ProviderUsageRecord] = []

        for org in orgs.prefix(3) {
            guard let orgLogin = org["login"] as? String else { continue }

            guard var components = URLComponents(string: "\(baseURL)/orgs/\(orgLogin)/copilot/metrics") else { continue }
            components.queryItems = [
                URLQueryItem(name: "since", value: formatter.string(from: since)),
                URLQueryItem(name: "until", value: formatter.string(from: Date()))
            ]
            guard let orgMetricsURL = components.url else { continue }

            var request = URLRequest(url: orgMetricsURL)
            request.setValue("Bearer \(pat)", forHTTPHeaderField: "Authorization")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

            if let (data, response) = try? await session.data(for: request),
               let httpResp = response as? HTTPURLResponse,
               httpResp.statusCode == 200 {
                allRecords.append(contentsOf: parseMetricsResponse(data))
            }
        }

        return allRecords
    }

    private func parseMetricsResponse(_ data: Data) -> [ProviderUsageRecord] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }

        var records: [ProviderUsageRecord] = []
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")

        // Response can be an array of daily metric objects
        let entries: [[String: Any]]
        if let array = json as? [[String: Any]] {
            entries = array
        } else if let obj = json as? [String: Any], let data = obj["data"] as? [[String: Any]] {
            entries = data
        } else {
            return []
        }

        for entry in entries {
            let dateStr = entry["date"] as? String ?? ""
            let date = formatter.date(from: dateStr) ?? Date()

            // Copilot metrics may have model-level breakdowns
            if let models = entry["copilot_ide_chat"] as? [String: Any],
               let modelBreakdown = models["models"] as? [[String: Any]] {
                for modelEntry in modelBreakdown {
                    let model = modelEntry["name"] as? String ?? "copilot"
                    let totalTokens = modelEntry["total_tokens"] as? Int ?? 0
                    let _ = modelEntry["avg_tokens_per_request"] as? Int
                    let requests = modelEntry["total_engaged_users"] as? Int ?? 1

                    guard totalTokens > 0 else { continue }

                    let inputTokens = Int(Double(totalTokens) * 0.85)
                    let outputTokens = max(totalTokens - inputTokens, 0)

                    let pricing = ModelPricing.lookup(model: model)
                    let cost = pricing.cost(inputTokens: inputTokens, outputTokens: outputTokens)

                    records.append(ProviderUsageRecord(
                        providerName: "GitHub Copilot",
                        model: model,
                        date: date,
                        inputTokens: inputTokens,
                        outputTokens: outputTokens,
                        cacheReadTokens: 0,
                        cacheCreationTokens: 0,
                        costUSD: cost,
                        requestCount: requests
                    ))
                }
            }

            // Also check for flat token counts
            let totalTokens = entry["total_tokens_used"] as? Int
                ?? entry["total_tokens"] as? Int ?? 0
            if totalTokens > 0 && records.isEmpty {
                let inputTokens = Int(Double(totalTokens) * 0.85)
                let outputTokens = max(totalTokens - inputTokens, 0)

                let pricing = ModelPricing.lookup(model: "copilot")
                let cost = pricing.cost(inputTokens: inputTokens, outputTokens: outputTokens)

                records.append(ProviderUsageRecord(
                    providerName: "GitHub Copilot",
                    model: "copilot",
                    date: date,
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    cacheReadTokens: 0,
                    cacheCreationTokens: 0,
                    costUSD: cost,
                    requestCount: entry["total_active_users"] as? Int ?? 1
                ))
            }
        }

        return records
    }
}
