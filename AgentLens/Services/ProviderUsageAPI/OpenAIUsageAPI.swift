import Foundation

// MARK: - OpenAI Usage API

/// Fetches usage data from the OpenAI Organization Usage API.
/// Requires an Admin API key.
/// Endpoint: GET /v1/organization/usage/completions
final class OpenAIUsageAPI: ProviderUsageAPI, @unchecked Sendable {
    let providerName = "OpenAI"
    let authMethod: ProviderAuthMethod = .apiKey

    private let apiKey: String
    private let baseURL = "https://api.openai.com/v1/organization"
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
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { return false }
        return httpResponse.statusCode == 200
    }

    func fetchUsage(since: Date) async throws -> [ProviderUsageRecord] {
        let now = Date()
        let url = buildURL(startTime: since, endTime: now, granularity: "1d", groupBy: "model")

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

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
                    if let records = parseBucket(bucket) {
                        allRecords.append(contentsOf: records)
                    }
                }
            }

            // Pagination
            if let hasMore = json["has_more"] as? Bool, hasMore,
               let nextPage = json["next_page"] as? String {
                var nextComponents = URLComponents(string: "\(baseURL)/usage/completions")!
                nextComponents.queryItems = [URLQueryItem(name: "page", value: nextPage)]
                currentURL = nextComponents.url
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
        var components = URLComponents(string: "\(baseURL)/usage/completions")!
        // OpenAI uses Unix timestamps
        var items: [URLQueryItem] = [
            URLQueryItem(name: "start_time", value: String(Int(startTime.timeIntervalSince1970))),
            URLQueryItem(name: "end_time", value: String(Int(endTime.timeIntervalSince1970))),
            URLQueryItem(name: "granularity", value: granularity)
        ]
        if let groupBy {
            items.append(URLQueryItem(name: "group_by[]", value: groupBy))
        }
        components.queryItems = items
        return components.url!
    }

    private func parseBucket(_ bucket: [String: Any]) -> [ProviderUsageRecord]? {
        let startTime = bucket["start_time"] as? Int ?? 0
        let date = Date(timeIntervalSince1970: Double(startTime))

        // Results may be nested under "results" array when grouped
        if let results = bucket["results"] as? [[String: Any]] {
            return results.compactMap { parseResult($0, date: date) }
        }

        return parseResult(bucket, date: date).map { [$0] }
    }

    private func parseResult(_ result: [String: Any], date: Date) -> ProviderUsageRecord? {
        let model = result["model"] as? String ?? "gpt-4"
        let input = result["input_tokens"] as? Int ?? 0
        let output = result["output_tokens"] as? Int ?? 0
        let cached = result["input_cached_tokens"] as? Int ?? 0
        let requests = result["num_model_requests"] as? Int ?? 1

        guard input > 0 || output > 0 else { return nil }

        let pricing = ModelPricing.lookup(model: model)
        let cost = pricing.cost(
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cached
        )

        return ProviderUsageRecord(
            providerName: "OpenAI",
            model: model,
            date: date,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cached,
            cacheCreationTokens: 0,
            costUSD: cost,
            requestCount: requests
        )
    }
}
