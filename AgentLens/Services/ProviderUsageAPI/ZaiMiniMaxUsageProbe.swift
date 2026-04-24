import Foundation

// MARK: - Z.ai Usage Probe

/// Attempts to discover and query Z.ai's usage/billing endpoints.
/// These are speculative — the endpoints may not exist. Failures are silent.
final class ZaiUsageProbe: ProviderUsageAPI, Sendable {
    let providerName = "Z.ai"
    let authMethod: ProviderAuthMethod = .apiKey

    private let apiKey: String
    private let baseURL: String
    private let session: URLSession

    init(apiKey: String, baseURL: String = "https://api.z.ai/api/coding/paas/v4", session: URLSession = .shared) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session
    }

    func validate() async throws -> Bool {
        // Try a lightweight models endpoint to verify the key works
        let candidateURLs = [
            "\(baseURL)/models",
            "\(baseURL.replacingOccurrences(of: "/v4", with: "/v4"))/models"
        ]

        for urlString in candidateURLs {
            guard let url = URL(string: urlString) else { continue }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 5

            if let (_, response) = try? await session.data(for: request),
               let http = response as? HTTPURLResponse,
               http.statusCode == 200 {
                return true
            }
        }
        return false
    }

    func fetchUsage(since: Date) async throws -> [ProviderUsageRecord] {
        // Probe known and speculative endpoints
        let probeURLs = [
            "\(baseURL)/usage",
            "\(baseURL)/billing/usage",
            "\(baseURL.replacingOccurrences(of: "/coding/paas/v4", with: ""))/dashboard/billing/usage",
            "https://open.bigmodel.cn/api/billing/usage"
        ]

        for urlString in probeURLs {
            guard let url = URL(string: urlString) else { continue }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 5

            guard let (data, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse,
                  http.statusCode == 200 else {
                continue
            }

            if let records = parseUsageResponse(data, since: since), !records.isEmpty {
                return records
            }
        }

        return []
    }

    private func parseUsageResponse(_ data: Data, since: Date) -> [ProviderUsageRecord]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        var records: [ProviderUsageRecord] = []

        // Try common response shapes
        if let usage = json["usage"] as? [String: Any] ?? json["data"] as? [String: Any] {
            let input = usage["total_tokens"] as? Int ?? usage["input_tokens"] as? Int ?? 0
            let output = usage["output_tokens"] as? Int ?? 0
            let cost = usage["total_cost"] as? Double ?? 0

            if input > 0 || output > 0 {
                records.append(ProviderUsageRecord(
                    providerName: "Z.ai",
                    model: "glm",
                    date: Date(),
                    inputTokens: input,
                    outputTokens: output,
                    cacheReadTokens: 0,
                    cacheCreationTokens: 0,
                    costUSD: cost,
                    requestCount: 1
                ))
            }
        }

        // Try array of daily entries
        if let entries = json["data"] as? [[String: Any]] ?? json["daily"] as? [[String: Any]] {
            for entry in entries {
                let dateStr = entry["date"] as? String ?? ""
                let date = ISO8601DateFormatter().date(from: dateStr) ?? Date()
                guard date >= since else { continue }

                let input = entry["input_tokens"] as? Int ?? entry["prompt_tokens"] as? Int ?? 0
                let output = entry["output_tokens"] as? Int ?? entry["completion_tokens"] as? Int ?? 0
                let cost = entry["cost"] as? Double ?? 0
                let model = entry["model"] as? String ?? "glm"

                if input > 0 || output > 0 {
                    records.append(ProviderUsageRecord(
                        providerName: "Z.ai",
                        model: model,
                        date: date,
                        inputTokens: input,
                        outputTokens: output,
                        cacheReadTokens: 0,
                        cacheCreationTokens: 0,
                        costUSD: cost,
                        requestCount: 1
                    ))
                }
            }
        }

        return records.isEmpty ? nil : records
    }
}

// MARK: - MiniMax Usage Probe

/// Attempts to discover and query MiniMax's usage/billing endpoints.
/// Speculative — failures are silent.
final class MiniMaxUsageProbe: ProviderUsageAPI, Sendable {
    let providerName = "MiniMax"
    let authMethod: ProviderAuthMethod = .apiKey

    private let apiKey: String
    private let baseURL: String
    private let session: URLSession

    init(apiKey: String, baseURL: String = "https://api.minimax.io/v1", session: URLSession = .shared) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session
    }

    func validate() async throws -> Bool {
        guard let url = URL(string: "\(baseURL)/models") else { return false }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 5

        if let (_, response) = try? await session.data(for: request),
           let http = response as? HTTPURLResponse,
           http.statusCode == 200 {
            return true
        }
        return false
    }

    func fetchUsage(since: Date) async throws -> [ProviderUsageRecord] {
        let probeURLs = [
            "\(baseURL)/usage",
            "\(baseURL)/billing/usage",
            "https://api.minimax.io/usage",
            "https://api.minimax.io/v1/dashboard/billing/usage"
        ]

        for urlString in probeURLs {
            guard let url = URL(string: urlString) else { continue }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 5

            guard let (data, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse,
                  http.statusCode == 200 else {
                continue
            }

            if let records = parseUsageResponse(data, since: since), !records.isEmpty {
                return records
            }
        }

        return []
    }

    private func parseUsageResponse(_ data: Data, since: Date) -> [ProviderUsageRecord]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        var records: [ProviderUsageRecord] = []

        if let usage = json["usage"] as? [String: Any] ?? json["data"] as? [String: Any] {
            let input = usage["total_tokens"] as? Int ?? usage["input_tokens"] as? Int ?? 0
            let output = usage["output_tokens"] as? Int ?? 0
            let cost = usage["total_cost"] as? Double ?? 0

            if input > 0 || output > 0 {
                records.append(ProviderUsageRecord(
                    providerName: "MiniMax",
                    model: "minimax",
                    date: Date(),
                    inputTokens: input,
                    outputTokens: output,
                    cacheReadTokens: 0,
                    cacheCreationTokens: 0,
                    costUSD: cost,
                    requestCount: 1
                ))
            }
        }

        if let entries = json["data"] as? [[String: Any]] ?? json["daily"] as? [[String: Any]] {
            for entry in entries {
                let dateStr = entry["date"] as? String ?? ""
                let date = ISO8601DateFormatter().date(from: dateStr) ?? Date()
                guard date >= since else { continue }

                let input = entry["input_tokens"] as? Int ?? 0
                let output = entry["output_tokens"] as? Int ?? 0
                let cost = entry["cost"] as? Double ?? 0
                let model = entry["model"] as? String ?? "minimax"

                if input > 0 || output > 0 {
                    records.append(ProviderUsageRecord(
                        providerName: "MiniMax",
                        model: model,
                        date: date,
                        inputTokens: input,
                        outputTokens: output,
                        cacheReadTokens: 0,
                        cacheCreationTokens: 0,
                        costUSD: cost,
                        requestCount: 1
                    ))
                }
            }
        }

        return records.isEmpty ? nil : records
    }
}
