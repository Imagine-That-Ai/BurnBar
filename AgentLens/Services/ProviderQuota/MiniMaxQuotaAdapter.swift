import Foundation
import OpenBurnBarCore

@MainActor
struct MiniMaxQuotaAdapter: ProviderQuotaAdapter {
    private enum QuotaEndpoint {
        static let tokenPlan = ProviderEndpointProfileRegistry.minimaxTokenPlan.quotaRemainsURL
            ?? "https://www.minimax.io/v1/token_plan/remains"
        static let codingPlan = "https://www.minimax.io/v1/api/openplatform/coding_plan/remains"
    }
    func fetch(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot {
        guard context.miniMaxModeProvider() == .tokenPlan else {
            return unavailableSnapshot(
                for: .minimax,
                source: .unavailable,
                message: "MiniMax quota reporting is disabled while billing mode is set to Pay-as-you-go."
            )
        }

        guard let apiKey = resolveMiniMaxAPIKey(context: context) else {
            return unavailableSnapshot(
                for: .minimax,
                source: .unavailable,
                message: "Add a MiniMax Token Plan API key to report remaining quota."
            )
        }

        if miniMaxAPIKeyKind(apiKey) == .standard {
            return unavailableSnapshot(
                for: .minimax,
                source: .officialAPI,
                message: "MiniMax quota reporting requires a Coding Plan key (`sk-cp-...`), not a standard Open Platform key (`sk-api-...`)."
            )
        }

        let fetchResult = try await fetchMiniMaxRemains(apiKey: apiKey, session: context.session)
        if fetchResult.authRejected {
            return unavailableSnapshot(
                for: .minimax,
                source: .officialAPI,
                message: "MiniMax rejected the configured key. Token Plan quota requires a Token Plan API key, not a pay-as-you-go Open Platform key."
            )
        }
        guard let data = fetchResult.data else {
            if let statusCode = fetchResult.httpStatusCode {
                throw QuotaServiceError.httpStatus(provider: .minimax, code: statusCode)
            }
            throw QuotaServiceError.invalidResponse("MiniMax returned a non-HTTP response.")
        }

        let object = try JSONSerialization.jsonObject(with: data)
        if let inlineError = miniMaxInlineErrorMessage(from: object) {
            return unavailableSnapshot(
                for: .minimax,
                source: .officialAPI,
                message: inlineError
            )
        }
        let buckets = normalizeModelRemainsBucketLabels(
            FlexibleQuotaBucketNormalizer.extractFlexibleBuckets(
                from: object,
                provider: .minimax,
                endpointLabel: "minimax"
            ),
            from: object,
        )

        guard !buckets.isEmpty else {
            return unavailableSnapshot(
                for: .minimax,
                source: .officialAPI,
                message: "MiniMax returned a Token Plan response, but no recognizable quota buckets were found."
            )
        }

        return ProviderQuotaSnapshot(
            provider: .minimax,
            fetchedAt: Date(),
            source: .officialAPI,
            confidence: .exact,
            managementURL: "https://platform.minimax.io/docs/token-plan/faq",
            statusMessage: "Quota fetched from MiniMax Token Plan.",
            buckets: buckets
        )
    }

    // MARK: - MiniMax Helpers

    private struct MiniMaxRemainsFetchResult {
        let data: Data?
        let httpStatusCode: Int?
        let authRejected: Bool
    }

    private func fetchMiniMaxRemains(
        apiKey: String,
        session: URLSession
    ) async throws -> MiniMaxRemainsFetchResult {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        let codingResult = try await fetchMiniMaxRemains(from: QuotaEndpoint.codingPlan, apiKey: trimmed, session: session)
        if codingResult.data != nil || codingResult.authRejected {
            return codingResult
        }
        return try await fetchMiniMaxRemains(from: QuotaEndpoint.tokenPlan, apiKey: trimmed, session: session)
    }

    private func fetchMiniMaxRemains(
        from urlString: String,
        apiKey: String,
        session: URLSession
    ) async throws -> MiniMaxRemainsFetchResult {
        guard let url = URL(string: urlString) else {
            throw QuotaServiceError.invalidResponse("MiniMax quota URL is invalid: \(urlString)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            return MiniMaxRemainsFetchResult(data: nil, httpStatusCode: nil, authRejected: false)
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            return MiniMaxRemainsFetchResult(data: nil, httpStatusCode: http.statusCode, authRejected: true)
        }
        guard (200..<300).contains(http.statusCode) else {
            return MiniMaxRemainsFetchResult(data: nil, httpStatusCode: http.statusCode, authRejected: false)
        }
        return MiniMaxRemainsFetchResult(data: data, httpStatusCode: http.statusCode, authRejected: false)
    }

    private func resolveMiniMaxAPIKey(context: ProviderQuotaAdapterContext) -> String? {
        quotaNonEmpty(context.resolvedAPIKeys["minimax"] ?? nil)
            ?? cursorConnectorKey(for: "provider.minimax.apiKey")
            ?? quotaNonEmpty(context.environment["MINIMAX_API_KEY"])
    }

    private func miniMaxAPIKeyKind(_ apiKey: String) -> MiniMaxAPIKeyKind {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("sk-cp-") {
            return .codingPlan
        }
        if trimmed.hasPrefix("sk-api-") {
            return .standard
        }
        return .unknown
    }

    private func miniMaxInlineErrorMessage(from object: Any) -> String? {
        guard let dictionary = FlexibleQuotaBucketNormalizer.unwrapDataEnvelope(object) as? [String: Any] else { return nil }
        let baseResponse = (dictionary["base_resp"] as? [String: Any]) ?? dictionary

        if let statusCode = FlexibleQuotaBucketNormalizer.number(in: baseResponse, keys: ["status_code", "statusCode", "code"]),
           Int(statusCode.rounded()) != 0,
           Int(statusCode.rounded()) != 200 {
            let message = FlexibleQuotaBucketNormalizer.string(in: baseResponse, keys: ["status_msg", "statusMsg", "message", "msg", "error"])
                ?? "code \(Int(statusCode.rounded()))"
            return "MiniMax returned an API error: \(message)"
        }

        if let success = baseResponse["success"] as? Bool, !success {
            let message = FlexibleQuotaBucketNormalizer.string(in: baseResponse, keys: ["status_msg", "statusMsg", "message", "msg", "error"])
                ?? "request unsuccessful"
            return "MiniMax returned an API error: \(message)"
        }

        return nil
    }

    private func normalizeModelRemainsBucketLabels(
        _ buckets: [ProviderQuotaBucket],
        from object: Any
    ) -> [ProviderQuotaBucket] {
        guard buckets.count == 1,
              let dictionary = FlexibleQuotaBucketNormalizer.unwrapDataEnvelope(object) as? [String: Any],
              let modelRemains = dictionary["model_remains"] as? [[String: Any]],
              let first = modelRemains.first,
              let modelName = FlexibleQuotaBucketNormalizer.string(in: first, keys: ["model_name", "modelName"]),
              !modelName.isEmpty else {
            return buckets
        }

        let normalizedLabel = FlexibleQuotaBucketNormalizer.normalizedBucketLabel(
            modelName,
            provider: .minimax
        )
        let bucket = buckets[0]

        return [
            ProviderQuotaBucket(
                key: bucket.key,
                label: normalizedLabel,
                windowKind: bucket.windowKind,
                usedValue: bucket.usedValue,
                limitValue: bucket.limitValue,
                remainingValue: bucket.remainingValue,
                usedPercent: bucket.usedPercent,
                resetsAt: bucket.resetsAt,
                unit: bucket.unit,
                isEstimated: bucket.isEstimated
            )
        ]
    }

    private func cursorConnectorKey(for account: String) -> String? {
        let keychain = KeychainStore()
        let raw = try? keychain.string(for: account, allowUserInteraction: false)
        return quotaNonEmpty(raw ?? nil)
    }
}
