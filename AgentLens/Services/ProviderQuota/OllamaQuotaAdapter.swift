import Foundation

struct OllamaQuotaAdapter: ProviderQuotaAdapter {
    func fetch(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot {
        // Resolve API key from configured identifiers; optional for local Ollama.
        let apiKey = resolveAPIKey(context: context)
        let endpoint = resolveEndpoint(context: context)

        // Try /api/tags to list pulled models.
        let tagsURL = endpoint.appendingPathComponent("api/tags")
        guard let tagsRequest = buildRequest(url: tagsURL, apiKey: apiKey) else {
            return unavailableSnapshot(
                for: .ollama,
                source: .unavailable,
                message: "Ollama endpoint URL is invalid."
            )
        }

        do {
            let (tagsData, tagsResponse) = try await context.session.data(for: tagsRequest)
            guard let tagsHTTP = tagsResponse as? HTTPURLResponse, tagsHTTP.statusCode == 200 else {
                return unavailableSnapshot(
                    for: .ollama,
                    source: .unavailable,
                    message: "Ollama server is not reachable at \(endpoint.absoluteString). Start it with `ollama serve`."
                )
            }

            let modelCount = countModels(in: tagsData)
            let modelNames = modelNames(in: tagsData)

            // Try /api/ps for currently loaded models.
            let loadedCount: Int
            var loadedModels: [String] = []
            if let psURL = URL(string: endpoint.absoluteString + "/api/ps"),
               let psRequest = buildRequest(url: psURL, apiKey: apiKey),
               let (psData, psResponse) = try? await context.session.data(for: psRequest),
               let psHTTP = psResponse as? HTTPURLResponse, psHTTP.statusCode == 200 {
                loadedCount = countModels(in: psData)
                loadedModels = modelNames(in: psData)
            } else {
                loadedCount = 0
            }

            var buckets: [ProviderQuotaBucket] = []

            // Available models bucket (count only, no limit).
            buckets.append(ProviderQuotaBucket(
                key: "ollama-available",
                label: "Available models",
                windowKind: .custom,
                usedValue: nil,
                limitValue: nil,
                remainingValue: Double(modelCount),
                usedPercent: nil,
                resetsAt: nil,
                unit: .count,
                isEstimated: false
            ))

            // Currently loaded models bucket.
            if loadedCount > 0 {
                buckets.append(ProviderQuotaBucket(
                    key: "ollama-loaded",
                    label: "Loaded in memory",
                    windowKind: .custom,
                    usedValue: nil,
                    limitValue: nil,
                    remainingValue: Double(loadedCount),
                    usedPercent: nil,
                    resetsAt: nil,
                    unit: .count,
                    isEstimated: false
                ))
            }

            let loadedLabel = loadedCount > 0
                ? " (\(loadedModels.joined(separator: ", ")))"
                : ""
            let statusMessage = "Ollama is running\(loadedLabel). \(modelCount) model(s) pulled locally. No quota limits — local inference."

            return ProviderQuotaSnapshot(
                provider: .ollama,
                fetchedAt: Date(),
                source: .localSession,
                confidence: .exact,
                managementURL: "https://ollama.com",
                statusMessage: statusMessage,
                buckets: buckets
            )
        } catch {
            return unavailableSnapshot(
                for: .ollama,
                source: .unavailable,
                message: "Failed to reach Ollama: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Helpers

    private func resolveAPIKey(context: ProviderQuotaAdapterContext) -> String? {
        for identifier in ["ollama", "Ollama"] {
            if let value = quotaNonEmpty(context.resolvedAPIKeys[identifier] ?? nil) {
                return value
            }
        }
        return quotaNonEmpty(context.environment["OLLAMA_API_KEY"])
    }

    private func resolveEndpoint(context: ProviderQuotaAdapterContext) -> URL {
        // Check for configured host in environment.
        let host = context.environment["OLLAMA_HOST"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let baseString: String
        if !host.isEmpty {
            baseString = host.hasPrefix("http") ? host : "http://\(host)"
        } else {
            baseString = "http://localhost:11434"
        }
        return URL(string: baseString) ?? URL(string: "http://localhost:11434")!
    }

    private func buildRequest(url: URL, apiKey: String?) -> URLRequest? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func countModels(in data: Data) -> Int {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [Any] else {
            return 0
        }
        return models.count
    }

    private func modelNames(in data: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else {
            return []
        }
        return models.compactMap { $0["name"] as? String }
    }
}
