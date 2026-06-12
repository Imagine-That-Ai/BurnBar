import Foundation

@MainActor
struct ZAIQuotaAdapter: ProviderQuotaAdapter {
    func fetch(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot {
        guard let apiKey = resolveZaiAPIKey(context: context) else {
            return unavailableSnapshot(
                for: .zai,
                source: .unavailable,
                message: "Add a Z.ai coding-plan key to report remaining quota."
            )
        }

        let candidateBaseURLs = zaiCandidateBaseURLs(environment: context.environment)
        let queryItems = zaiUsageQueryItems()
        var lastInlineError: String?

        for baseURL in candidateBaseURLs {
            do {
                let quotaObject = try await requestJSON(
                    url: baseURL.appendingPathComponent("api/monitor/usage/quota/limit"),
                    authorizationValue: "Bearer \(apiKey)",
                    session: context.session
                )

                let buckets = FlexibleQuotaBucketNormalizer.extractFlexibleBuckets(
                    from: quotaObject,
                    provider: .zai,
                    endpointLabel: "zai"
                )
                guard !buckets.isEmpty else { continue }

                let modelUsageObject = try? await requestJSON(
                    url: baseURL.appendingPathComponent("api/monitor/usage/model-usage"),
                    queryItems: queryItems,
                    authorizationValue: "Bearer \(apiKey)",
                    session: context.session
                )
                let toolUsageObject = try? await requestJSON(
                    url: baseURL.appendingPathComponent("api/monitor/usage/tool-usage"),
                    queryItems: queryItems,
                    authorizationValue: "Bearer \(apiKey)",
                    session: context.session
                )
                let modelRows = modelUsageObject.map(Self.extractRecordCount(from:)) ?? 0
                let toolRows = toolUsageObject.map(Self.extractRecordCount(from:)) ?? 0

                return ProviderQuotaSnapshot(
                    provider: .zai,
                    fetchedAt: Date(),
                    source: .officialAPI,
                    confidence: .exact,
                    managementURL: "https://bigmodel.cn/usercenter/glm-coding/usage",
                    statusMessage: "Quota fetched from Z.ai usage monitor. Model rows: \(modelRows) · tool rows: \(toolRows).",
                    buckets: buckets
                )
            } catch let error as QuotaServiceError {
                if case let .invalidResponse(message) = error {
                    lastInlineError = message
                }
                continue
                } catch {
                    AppLogger.sync.error("zai_quota_parse_failed", metadata: ["error": error.localizedDescription])
                    continue
                }
        }

        if let lastInlineError {
            return unavailableSnapshot(
                for: .zai,
                source: .officialAPI,
                message: lastInlineError
            )
        }

        return unavailableSnapshot(
            for: .zai,
            source: .officialAPI,
            message: "Z.ai did not return a recognizable coding-plan quota payload from api.z.ai or open.bigmodel.cn."
        )
    }

    // MARK: - ZAI Helpers

    private func resolveZaiAPIKey(context: ProviderQuotaAdapterContext) -> String? {
        quotaNonEmpty(context.resolvedAPIKeys["zai"] ?? nil)
            ?? cursorConnectorKey(for: "provider.zai.apiKey")
            ?? quotaNonEmpty(context.environment["ZAI_API_KEY"])
            ?? quotaNonEmpty(context.environment["Z_AI_API_KEY"])
    }

    private func zaiCandidateBaseURLs(environment: [String: String]) -> [URL] {
        var candidates: [URL] = []
        if let explicitQuotaURL = quotaNonEmpty(environment["Z_AI_QUOTA_URL"]),
           let url = normalizedZaiHostURL(from: explicitQuotaURL) {
            candidates.append(url)
        }
        if let configuredHost = quotaNonEmpty(environment["Z_AI_API_HOST"]),
           let url = normalizedZaiHostURL(from: configuredHost) {
            candidates.append(url)
        }
        if let configured = environment["ZAI_BASE_URL"], let url = URL(string: configured) {
            candidates.append(url)
        }
        if let apiURL = URL(string: "https://api.z.ai") {
            candidates.append(apiURL)
        }
        if let bigModelURL = URL(string: "https://open.bigmodel.cn") {
            candidates.append(bigModelURL)
        }

        var seen = Set<String>()
        return candidates.filter { url in
            seen.insert(url.absoluteString).inserted
        }.sorted { lhs, rhs in
            lhs.absoluteString.contains("api.z.ai") && !rhs.absoluteString.contains("api.z.ai")
        }
    }

    private func normalizedZaiHostURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
            components.path = ""
            components.query = nil
            components.fragment = nil
            return components.url ?? url
        }
        return normalizedZaiHostURL(from: "https://\(trimmed)")
    }

    private func zaiUsageQueryItems() -> [URLQueryItem] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        let calendar = Calendar.current
        let now = Date()
        let start = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        let startWindow = calendar.date(
            bySettingHour: calendar.component(.hour, from: now),
            minute: 0,
            second: 0,
            of: start
        ) ?? start
        let endWindow = calendar.date(
            bySettingHour: calendar.component(.hour, from: now),
            minute: 59,
            second: 59,
            of: now
        ) ?? now

        return [
            URLQueryItem(name: "startTime", value: formatter.string(from: startWindow)),
            URLQueryItem(name: "endTime", value: formatter.string(from: endWindow))
        ]
    }

    private func zaiInlineErrorMessage(from object: Any) -> String? {
        guard let dictionary = object as? [String: Any] else { return nil }

        if let success = dictionary["success"] as? Bool, !success {
            let message = FlexibleQuotaBucketNormalizer.string(in: dictionary, keys: ["msg", "message", "error"])
                ?? "Z.ai monitor returned an unsuccessful response."
            return "Z.ai monitor returned an inline error: \(message)"
        }

        if let code = FlexibleQuotaBucketNormalizer.number(in: dictionary, keys: ["code", "status"]),
           code != 0, code != 200 {
            let message = FlexibleQuotaBucketNormalizer.string(in: dictionary, keys: ["msg", "message", "error"])
                ?? "code \(Int(code.rounded()))"
            if Int(code.rounded()) == 401 || Int(code.rounded()) == 1001 {
                return "Z.ai monitor rejected the configured key: \(message)"
            }
            return "Z.ai monitor returned an inline error: \(message)"
        }

        if let code = FlexibleQuotaBucketNormalizer.string(in: dictionary, keys: ["code", "status"]),
           let parsed = Double(code),
           parsed != 0, parsed != 200 {
            let message = FlexibleQuotaBucketNormalizer.string(in: dictionary, keys: ["msg", "message", "error"]) ?? code
            if Int(parsed.rounded()) == 401 || Int(parsed.rounded()) == 1001 {
                return "Z.ai monitor rejected the configured key: \(message)"
            }
            return "Z.ai monitor returned an inline error: \(message)"
        }

        return nil
    }

    private func requestJSON(
        url: URL,
        queryItems: [URLQueryItem] = [],
        authorizationValue: String,
        session: URLSession
    ) async throws -> Any {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let finalURL = components?.url else {
            throw QuotaServiceError.invalidResponse("Could not build request URL for \(url.absoluteString).")
        }

        var request = URLRequest(url: finalURL)
        request.httpMethod = "GET"
        request.setValue(authorizationValue, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("en-US,en", forHTTPHeaderField: "Accept-Language")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw QuotaServiceError.invalidResponse("Non-HTTP response for \(finalURL.absoluteString).")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw QuotaServiceError.httpStatus(provider: .zai, code: http.statusCode)
        }
        let object = try JSONSerialization.jsonObject(with: data)
        if let inlineError = zaiInlineErrorMessage(from: object) {
            throw QuotaServiceError.invalidResponse(inlineError)
        }
        return object
    }

    private func cursorConnectorKey(for account: String) -> String? {
        let keychain = KeychainStore()
        let raw = try? keychain.string(for: account, allowUserInteraction: false)
        return quotaNonEmpty(raw ?? nil)
    }

    private static func extractRecordCount(from object: Any) -> Int {
        let unwrapped = FlexibleQuotaBucketNormalizer.unwrapDataEnvelope(object)
        if let array = unwrapped as? [Any] {
            return array.count
        }
        if let dictionary = unwrapped as? [String: Any] {
            for key in ["items", "records", "list", "rows"] {
                if let array = dictionary[key] as? [Any] {
                    return array.count
                }
            }
        }
        return 0
    }
}
