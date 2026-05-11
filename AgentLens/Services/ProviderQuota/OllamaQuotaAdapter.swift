import Foundation

// MARK: - Ollama Quota Adapter

/// Reports real Ollama Cloud quota windows when Ollama exposes them.
///
/// ## Local Ollama
/// Reads `/api/tags` and `/api/ps` only for status text. Local models are not
/// quota and never become quota buckets.
///
/// ## Ollama Cloud
/// Two-tier approach for cloud quota:
/// 1. **OpenBurnBar login session** — the user clicks "Connect Ollama" in
///    Settings, which opens an OpenBurnBar-owned WKWebView and stores the
///    captured cookie header under `ollama_cookie_header` in Keychain. This
///    adapter pulls that cookie out of `context.resolvedAPIKeys` (populated
///    by `QuotaRefreshActor`/`ProviderQuotaService`) and forwards it to
///    `OllamaCloudScraper.fetchCloudUsage`, which fetches
///    `ollama.com/settings` and parses real usage percentages from the HTML.
///    Session usage %, Weekly usage %, plan name, reset times — all exact.
/// 2. **Environment override** — `OPENBURNBAR_OLLAMA_CLOUD_HTML` (raw HTML)
///    or `OLLAMA_COOKIE_HEADER` (cookie jar) for tests and CI.
/// 3. **Fallback** — detects `:cloud` models via local daemon, marks quota
///    `.unavailable` with a link to ollama.com/settings/billing.
///
/// Reference: CodexBar `OllamaUsageFetcher.swift` + `OllamaUsageParser.swift`

struct OllamaQuotaAdapter: ProviderQuotaAdapter {

    func fetch(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot {
        let apiKey = resolveAPIKey(context: context)
        let endpoint = resolveEndpoint(context: context)
        let hasCloudKey = apiKey != nil
        let hasCloudCookie = resolveOllamaSessionCookie(context: context) != nil

        // --- Cloud quota scraping (uses an OpenBurnBar-owned session cookie) ---
        async let cloudUsage = fetchCloudUsage(context: context)

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

        let buckets = cloud.map(cloudQuotaBuckets) ?? []

        // --- Status message ---
        let loadedLabel = loadedModels.isEmpty ? "" : " (\(loadedModels.joined(separator: ", ")))"

        var statusParts: [String] = ["Ollama is running"]
        if !localModels.isEmpty {
            statusParts.append("\(localModels.count) local model(s)")
        }
        if let cloud {
            let planLabel = cloud.planName ?? "Cloud"
            if let sessionUsedPercent = cloud.sessionUsedPercent {
                statusParts.append("\(planLabel) — \(String(format: "%.1f", sessionUsedPercent))% used in the 5-hour window")
            } else if let weeklyUsedPercent = cloud.weeklyUsedPercent {
                statusParts.append("\(planLabel) — \(String(format: "%.1f", weeklyUsedPercent))% used weekly")
            } else {
                statusParts.append("\(planLabel) quota page reached")
            }
        } else if hasCloudCookie {
            statusParts.append("Cloud session stored — Ollama returned no usage data. Reconnect if this persists.")
        } else if !cloudModels.isEmpty {
            if hasCloudKey {
                statusParts.append("\(cloudModels.count) cloud model(s) — connect Ollama for quota windows")
            } else {
                statusParts.append("\(cloudModels.count) cloud model(s) — add OLLAMA_API_KEY + connect Ollama for quota windows")
            }
        } else {
            statusParts.append("Connect Ollama to read cloud quota windows from ollama.com")
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
            confidence: buckets.isEmpty ? .unavailable : .exact,
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
        let buckets = cloudQuotaBuckets(cloud)

        let planLabel = cloud.planName ?? "Cloud"
        let emailSuffix = cloud.accountEmail.map { " (\($0))" } ?? ""
        let usageSummary = cloud.sessionUsedPercent
            .map { "\(String(format: "%.1f", $0))% used in the 5-hour window" }
            ?? cloud.weeklyUsedPercent.map { "\(String(format: "%.1f", $0))% used weekly" }
            ?? "quota page reached"

        return ProviderQuotaSnapshot(
            provider: .ollama,
            fetchedAt: Date(),
            source: .officialAPI,
            confidence: buckets.isEmpty ? .unavailable : .exact,
            managementURL: "https://ollama.com/settings/billing",
            statusMessage: "Ollama Cloud · \(planLabel)\(emailSuffix) · \(usageSummary). Local daemon not running.",
            buckets: buckets
        )
    }

    // MARK: - Helpers

    private func fetchCloudUsage(context: ProviderQuotaAdapterContext) async -> OllamaCloudScraper.CloudUsage? {
        if let html = quotaNonEmpty(context.environment["OPENBURNBAR_OLLAMA_CLOUD_HTML"]) {
            return OllamaCloudScraper.parseCloudUsage(html: html)
        }
        guard let cookieHeader = resolveOllamaSessionCookie(context: context) else { return nil }
        return await OllamaCloudScraper.fetchCloudUsage(cookieHeader: cookieHeader, session: context.session)
    }

    private func resolveOllamaSessionCookie(context: ProviderQuotaAdapterContext) -> String? {
        if let envCookie = quotaNonEmpty(context.environment["OLLAMA_COOKIE_HEADER"]) {
            return envCookie
        }
        for identifier in ["ollama_cookie_header", "ollama_cookie"] {
            if let stored = quotaNonEmpty(context.resolvedAPIKeys[identifier] ?? nil) {
                return stored
            }
        }
        return nil
    }

    private func cloudQuotaBuckets(_ cloud: OllamaCloudScraper.CloudUsage) -> [ProviderQuotaBucket] {
        var buckets: [ProviderQuotaBucket] = []

        if let sessionPct = cloud.sessionUsedPercent {
            buckets.append(ProviderQuotaBucket(
                key: "ollama-cloud-session",
                label: "Cloud · 5-hour window",
                windowKind: .rollingHours,
                usedValue: sessionPct,
                limitValue: 100,
                remainingValue: max(0, 100 - sessionPct),
                usedPercent: sessionPct,
                resetsAt: cloud.sessionResetsAt,
                unit: .percent,
                isEstimated: false
            ))
        }

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

        return buckets
    }

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
