import Foundation

// MARK: - Anthropic Usage API

/// Fetches usage data from the Anthropic Admin API.
/// Requires an Admin API key (sk-ant-admin...).
/// Endpoint: GET /v1/organizations/usage_report/messages
final class AnthropicUsageAPI: ProviderUsageAPI, Sendable {
    let providerName = "Anthropic"
    let authMethod: ProviderAuthMethod = .apiKey

    private let apiKey: String
    private let baseURL = "https://api.anthropic.com/v1/organizations"
    private let session: URLSession

    init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    func validate() async throws -> Bool {
        let now = Date()
        let oneDayAgo = now.addingTimeInterval(-86400)
        let url = buildURL(startTime: oneDayAgo, endTime: now, granularity: "1d")
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { return false }
        return httpResponse.statusCode == 200
    }

    func fetchUsage(since: Date) async throws -> [ProviderUsageRecord] {
        let now = Date()
        let url = buildURL(startTime: since, endTime: now, granularity: "1d", groupBy: "model")

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        var allRecords: [ProviderUsageRecord] = []
        var currentURL: URL? = url

        while let fetchURL = currentURL {
            request.url = fetchURL
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

            if let buckets = json["data"] as? [[String: Any]] {
                for bucket in buckets {
                    let records = parseBucket(bucket)
                    allRecords.append(contentsOf: records)
                }
            }

            // Pagination
            if let hasMore = json["has_more"] as? Bool, hasMore,
               let nextPage = json["next_page"] as? String {
                currentURL = URL(string: "\(baseURL)/usage_report/messages?page=\(nextPage)")
            } else {
                currentURL = nil
            }
        }

        return allRecords
    }

    private func buildURL(
        startTime: Date,
        endTime: Date,
        granularity: String,
        groupBy: String? = nil
    ) -> URL {
        var components = URLComponents(string: "\(baseURL)/usage_report/messages")!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "start_time", value: iso8601(startTime)),
            URLQueryItem(name: "end_time", value: iso8601(endTime)),
            URLQueryItem(name: "granularity", value: granularity)
        ]
        if let groupBy {
            items.append(URLQueryItem(name: "group_by", value: groupBy))
        }
        components.queryItems = items
        // URLComponents.url is guaranteed non-nil here — scheme, host, and path are hardcoded
        return components.url ?? URL(string: "\(baseURL)/usage_report/messages")!
    }

    private func parseBucket(_ bucket: [String: Any]) -> [ProviderUsageRecord] {
        let dateStr = bucket["start_time"] as? String ?? ""
        let date = ISO8601DateFormatter().date(from: dateStr) ?? Date()
        let model = bucket["model"] as? String ?? "claude"

        let input = bucket["input_tokens"] as? Int
            ?? bucket["uncached_input_tokens"] as? Int ?? 0
        let output = bucket["output_tokens"] as? Int ?? 0
        let cachedInput = bucket["cached_input_tokens"] as? Int ?? 0
        let cacheCreation = bucket["cache_creation_input_tokens"] as? Int ?? 0

        guard input > 0 || output > 0 || cachedInput > 0 else { return [] }

        // Anthropic doesn't return cost directly — compute from pricing
        let pricing = ModelPricing.lookup(model: model)
        let cost = pricing.cost(
            inputTokens: input,
            outputTokens: output,
            cacheCreationTokens: cacheCreation,
            cacheReadTokens: cachedInput
        )

        return [ProviderUsageRecord(
            providerName: "Anthropic",
            model: model,
            date: date,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cachedInput,
            cacheCreationTokens: cacheCreation,
            costUSD: cost,
            requestCount: bucket["num_requests"] as? Int ?? 1
        )]
    }

    private func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

// MARK: - Shared Error

enum ProviderUsageAPIError: LocalizedError {
    case httpError(Int)
    case invalidResponse
    case unauthorized

    var errorDescription: String? {
        switch self {
        case .httpError(let code): return "HTTP error \(code)"
        case .invalidResponse: return "Invalid response format"
        case .unauthorized: return "Invalid or expired credentials"
        }
    }
}
