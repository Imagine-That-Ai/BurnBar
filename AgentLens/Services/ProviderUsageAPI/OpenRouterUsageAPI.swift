import Foundation

// MARK: - OpenRouter Usage API

/// Fetches usage data from the OpenRouter Activity API.
/// Uses a standard API key (Bearer token).
/// Endpoint: GET /api/v1/activity
/// Returns daily aggregates by model/endpoint for the last 30 days.
final class OpenRouterUsageAPI: ProviderUsageAPI, Sendable {
    let providerName = "OpenRouter"
    let authMethod: ProviderAuthMethod = .apiKey

    private let apiKey: String
    private let baseURL = "https://openrouter.ai/api/v1"
    private let session: URLSession

    init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    func validate() async throws -> Bool {
        var request = URLRequest(url: URL(string: "\(baseURL)/auth/key")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { return false }
        return httpResponse.statusCode == 200
    }

    func fetchUsage(since: Date) async throws -> [ProviderUsageRecord] {
        var request = URLRequest(url: URL(string: "\(baseURL)/activity")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw ProviderUsageAPIError.httpError(
                (response as? HTTPURLResponse)?.statusCode ?? 0
            )
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderUsageAPIError.invalidResponse
        }

        var records: [ProviderUsageRecord] = []

        // Activity returns daily data grouped by model
        if let activities = json["data"] as? [[String: Any]] {
            for activity in activities {
                if let record = parseActivity(activity, since: since) {
                    records.append(record)
                }
            }
        }

        return records
    }

    private func parseActivity(_ activity: [String: Any], since: Date) -> ProviderUsageRecord? {
        let dateStr = activity["date"] as? String ?? ""
        let model = activity["model"] as? String ?? activity["model_id"] as? String ?? "unknown"

        let date: Date
        if let d = ISO8601DateFormatter().date(from: dateStr) {
            date = d
        } else {
            // Try YYYY-MM-DD format
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            guard let d = formatter.date(from: dateStr) else { return nil }
            date = d
        }

        guard date >= since else { return nil }

        let tokens = activity["total_tokens"] as? Int ?? 0
        let inputTokens = activity["input_tokens"] as? Int ?? activity["prompt_tokens"] as? Int ?? 0
        let outputTokens = activity["output_tokens"] as? Int ?? activity["completion_tokens"] as? Int ?? 0
        let cost = activity["total_cost"] as? Double ?? activity["cost"] as? Double ?? 0
        let requests = activity["num_requests"] as? Int ?? activity["count"] as? Int ?? 1

        // If only total_tokens is available, report output as total tokens without fabricating a split.
        let finalInput: Int
        let finalOutput: Int
        if inputTokens > 0 || outputTokens > 0 {
            finalInput = inputTokens
            finalOutput = outputTokens
        } else if tokens > 0 {
            finalInput = 0
            finalOutput = tokens
        } else {
            return nil
        }

        guard finalInput > 0 || finalOutput > 0 else { return nil }

        // Use OpenRouter's reported cost if available, otherwise compute
        let finalCost: Double
        if cost > 0 {
            finalCost = cost
        } else {
            let pricing = ModelPricing.lookup(model: model)
            finalCost = pricing.cost(inputTokens: finalInput, outputTokens: finalOutput)
        }

        return ProviderUsageRecord(
            providerName: "OpenRouter",
            model: model,
            date: date,
            inputTokens: finalInput,
            outputTokens: finalOutput,
            cacheReadTokens: 0,
            cacheCreationTokens: 0,
            costUSD: finalCost,
            requestCount: requests
        )
    }
}
