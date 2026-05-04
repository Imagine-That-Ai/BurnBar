import Foundation

// MARK: - Ollama Quota Adapter

/// Reports Ollama model availability (local + cloud) with real usage data.
///
/// ## Local Ollama
/// Reads `/api/tags` for available models and `/api/ps` for loaded models.
/// No billing or rate limits — local inference is unlimited.
///
/// ## Ollama Cloud
/// Two-tier approach for cloud quota:
/// 1. **Browser cookie scraping** — `OllamaCloudScraper` extracts Chrome cookies,
///    fetches `ollama.com/settings`, and parses real usage percentages from the HTML.
///    Session usage %, Weekly usage %, plan name, reset times — all exact.
/// 2. **WKWebView login** — opens ollama.com in a window, captures cookies, then scrapes.
/// 3. **Fallback** — detects `:cloud` models via local daemon, marks quota `.unavailable`
///    with a link to ollama.com/settings/billing.
///
/// Reference: CodexBar `OllamaUsageFetcher.swift` + `OllamaUsageParser.swift`

struct OllamaQuotaAdapter: ProviderQuotaAdapter {

    func fetch(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot {
        let apiKey = resolveAPIKey(context: context)
        let endpoint = resolveEndpoint(context: context)
        let hasCloudKey = apiKey != nil

        // --- Cloud quota scraping (uses Chrome cookies, same as Factory/Cursor) ---
        async let cloudUsage = OllamaCloudScraper.fetchCloudUsage(session: context.session)

        // --- Local model detection ---
        let tagsURL = endpoint.appendingPathComponent("api/tags")
        guard let tagsRequest = buildRequest(url: tagsURL, apiKey: apiKey) else {
            return unavailableSnapshot(
                for: .ollama,
                source: .unavailable,
                message: "Ollama endpoint URL is invalid."
            )
        }

        let tagsResult: (allModels: [ModelEntry], localModels: [ModelEntry], cloudModels: [ModelEntry], loadedModels: [String])?
        do {
            let (tagsData, tagsResponse) = try await context.session.data(for: tagsRequest)
            guard let tagsHTTP = tagsResponse as? HTTPURLResponse, tagsHTTP.statusCode == 200 else {
                let cloud = await cloudUsage
                if let cloud {
                    return buildCloudOnlySnapshot(cloud: cloud, hasCloudKey: hasCloudKey)
                }
                return unavailableSnapshot(
                    for: .ollama,
                    source: .unavailable,
                    message: "Ollama server is not reachable at \(endpoint.absoluteString). Start it with `ollama serve`."
                )
            }

            let allModels = modelEntries(in: tagsData)
            let localModels = allModels.filter { !$0.name.hasSuffix(":cloud") }
            let cloudModels = allModels.filter { $0.name.hasSuffix(":cloud") }

            let loadedModels: [String]
            if let psURL = URL(string: endpoint.absoluteString + "/api/ps"),
               let psRequest = buildRequest(url: psURL, apiKey: apiKey),
               let (psData, psResponse) = try? await context.session.data(for: psRequest),
               let psHTTP = psResponse as? HTTPURLResponse, psHTTP.statusCode == 200 {
                loadedModels = modelNames(in: psData)
            } else {
                loadedModels = []
            }

            tagsResult = (allModels, localModels, cloudModels, loadedModels)
        } catch {
            let cloud = await cloudUsage
            if let cloud {
                return buildCloudOnlySnapshot(cloud: cloud, hasCloudKey: hasCloudKey)
            }
            return unavailableSnapshot(
                for: .ollama,
                source: .unavailable,
                message: "Failed to reach Ollama: \(error.localizedDescription)"
            )
        }

        guard let (_, localModels, cloudModels, loadedModels) = tagsResult else {
            return unavailableSnapshot(for: .ollama, source: .unavailable, message: "Unexpected error.")
        }

        let cloud = await cloudUsage

        var buckets: [ProviderQuotaBucket] = []

        // --- Local models ---
        if !localModels.isEmpty {
            buckets.append(ProviderQuotaBucket(
                key: "ollama-local",
                label: "Local models",
                windowKind: .custom,
                usedValue: nil,
                limitValue: nil,
                remainingValue: Double(localModels.count),
                usedPercent: nil,
                resetsAt: nil,
                unit: .count,
                isEstimated: false
            ))
        }

        // --- Cloud models with real scraped usage ---
        if let cloud, !cloudModels.isEmpty {
            buckets.append(ProviderQuotaBucket(
                key: "ollama-cloud-session",
                label: "Cloud · \(cloud.planName ?? "Session")",
                windowKind: .custom,
                usedValue: cloud.sessionUsedPercent,
                limitValue: 100,
                remainingValue: max(0, 100 - cloud.sessionUsedPercent),
                usedPercent: cloud.sessionUsedPercent,
                resetsAt: cloud.sessionResetsAt,
                unit: .percent,
                isEstimated: false
            ))

            if let weeklyPct = cloud.weeklyUsedPercent {
                buckets.append(ProviderQuotaBucket(
                    key: "ollama-cloud-weekly",
                    label: "Cloud · Weekly",
                    windowKind: .weekly,
                    usedValue: weeklyPct,
                    limitValue: 100,
                    remainingValue: max(0, 100 - weeklyPct),
                    usedPercent: weeklyPct,
                    resetsAt: cloud.weeklyResetsAt,
                    unit: .percent,
                    isEstimated: false
                ))
            }
        } else if !cloudModels.isEmpty {
            buckets.append(ProviderQuotaBucket(
                key: "ollama-cloud",
                label: "Cloud models",
                windowKind: .custom,
                usedValue: nil,
                limitValue: nil,
                remainingValue: Double(cloudModels.count),
                usedPercent: nil,
                resetsAt: nil,
                unit: .count,
                isEstimated: false
            ))
        }

        // --- Status message ---
        let loadedLabel = loadedModels.isEmpty ? "" : " (\(loadedModels.joined(separator: ", ")))"

        var statusParts: [String] = ["Ollama is running"]
        if !localModels.isEmpty {
            statusParts.append("\(localModels.count) local model(s)")
        }
        if !cloudModels.isEmpty {
            if cloud != nil {
                let planLabel = cloud?.planName ?? "Cloud"
                statusParts.append("\(planLabel) — \(String(format: "%.1f", cloud?.sessionUsedPercent ?? 0))% used")
            } else if hasCloudKey {
                statusParts.append("\(cloudModels.count) cloud model(s) — sign in to ollama.com for quota")
            } else {
                statusParts.append("\(cloudModels.count) cloud model(s) — add OLLAMA_API_KEY + sign in")
            }
        }
        if !loadedModels.isEmpty {
            statusParts.append("\(loadedLabel)")
        }
        statusParts.append("No local rate limits.")

        let statusMessage = statusParts.joined(separator: ". ")

        return ProviderQuotaSnapshot(
            provider: .ollama,
            fetchedAt: Date(),
            source: cloud != nil ? .officialAPI : .localSession,
            confidence: .exact,
            managementURL: hasCloudKey
                ? "https://ollama.com/settings/billing"
                : "https://ollama.com",
            statusMessage: statusMessage,
            buckets: buckets
        )
    }

    // MARK: - Cloud-Only Snapshot (when daemon isn't running)

    private func buildCloudOnlySnapshot(
        cloud: OllamaCloudScraper.CloudUsage,
        hasCloudKey: Bool
    ) -> ProviderQuotaSnapshot {
        var buckets: [ProviderQuotaBucket] = []

        buckets.append(ProviderQuotaBucket(
            key: "ollama-cloud-session",
            label: "Cloud · \(cloud.planName ?? "Session")",
            windowKind: .custom,
            usedValue: cloud.sessionUsedPercent,
            limitValue: 100,
            remainingValue: max(0, 100 - cloud.sessionUsedPercent),
            usedPercent: cloud.sessionUsedPercent,
            resetsAt: cloud.sessionResetsAt,
            unit: .percent,
            isEstimated: false
        ))

        if let weeklyPct = cloud.weeklyUsedPercent {
            buckets.append(ProviderQuotaBucket(
                key: "ollama-cloud-weekly",
                label: "Cloud · Weekly",
                windowKind: .weekly,
                usedValue: weeklyPct,
                limitValue: 100,
                remainingValue: max(0, 100 - weeklyPct),
                usedPercent: weeklyPct,
                resetsAt: cloud.weeklyResetsAt,
                unit: .percent,
                isEstimated: false
            ))
        }

        let planLabel = cloud.planName ?? "Cloud"
        let emailSuffix = cloud.accountEmail.map { " (\($0))" } ?? ""

        return ProviderQuotaSnapshot(
            provider: .ollama,
            fetchedAt: Date(),
            source: .officialAPI,
            confidence: .exact,
            managementURL: "https://ollama.com/settings/billing",
            statusMessage: "Ollama Cloud · \(planLabel)\(emailSuffix) · \(String(format: "%.1f", cloud.sessionUsedPercent))% used. Local daemon not running.",
            buckets: buckets
        )
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

    // MARK: - Model Parsing

    private struct ModelEntry {
        let name: String
    }

    private func modelEntries(in data: Data) -> [ModelEntry] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else {
            return []
        }
        return models.compactMap { dict in
            guard let name = dict["name"] as? String else { return nil }
            return ModelEntry(name: name)
        }
    }

    private func modelNames(in data: Data) -> [String] {
        modelEntries(in: data).map(\.name)
    }
}
