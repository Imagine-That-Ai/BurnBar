import Foundation
import OpenBurnBarKernel

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Together / Meta Llama usage meter
//
// Reports month-to-date Together spend for the catalog `meta` route
// (aliases llama / together). Together's documented meter is
// `GET /v1/billing/usage` (Bearer API key, org-gated beta).
//
// Remaining prepaid credits are console-only in the public Together docs.
// This adapter never invents a remaining-credit percentage. A 404 means
// the org does not have billing-usage enabled — that is an explicit
// unsupported remaining-credit state, not a fake meter.

public struct TogetherQuotaAdapter: ProviderQuotaAdapter {
    public static let billingUsagePath = "/v1/billing/usage"
    public static let defaultAPIBaseURL = URL(string: "https://api.together.ai")!
    public static let managementURL = "https://api.together.ai/settings/billing"
    public static let maxUsagePages = 8

    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    public func fetch(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot {
        guard let apiKey = Self.resolveAPIKey(context: context) else {
            return unavailableSnapshot(
                for: .together,
                source: .officialAPI,
                message: "Add a Together / Llama API key to report month-to-date Together usage."
            )
        }

        guard let firstURL = Self.billingUsageURL(context: context, month: Self.billingMonth(now: now())) else {
            return unavailableSnapshot(
                for: .together,
                source: .officialAPI,
                message: "Together billing usage URL could not be built."
            )
        }

        do {
            let report = try await fetchUsageReport(url: firstURL, apiKey: apiKey, context: context)
            return snapshot(for: report)
        } catch let error as TogetherBillingUsageError {
            return snapshot(for: error)
        }
    }

    // MARK: - HTTP

    private func fetchUsageReport(
        url firstURL: URL,
        apiKey: String,
        context: ProviderQuotaAdapterContext
    ) async throws -> TogetherBillingUsageReport {
        var url: URL? = firstURL
        var pages: [TogetherBillingUsageReport] = []

        for _ in 0..<Self.maxUsagePages {
            guard let requestURL = url else { break }
            let (status, object) = try await performJSONGET(url: requestURL, apiKey: apiKey, session: context.session)
            switch status {
            case 200:
                guard let dictionary = object as? [String: Any] else {
                    throw TogetherBillingUsageError.malformed("Together billing usage payload was not a JSON object.")
                }
                if let inline = Self.inlineErrorMessage(from: dictionary) {
                    throw TogetherBillingUsageError.malformed(inline)
                }
                let page = TogetherBillingUsageReport.parse(dictionary)
                pages.append(page)
                if let cursor = page.nextCursor, !cursor.isEmpty {
                    url = Self.billingUsageURL(
                        context: context,
                        month: page.billingPeriod ?? Self.billingMonth(now: now()),
                        after: cursor
                    )
                } else {
                    url = nil
                }
            case 404:
                throw TogetherBillingUsageError.notEnabled
            case 401, 403:
                throw TogetherBillingUsageError.unauthorized(status)
            case 429:
                throw TogetherBillingUsageError.rateLimited
            default:
                throw QuotaServiceError.httpStatus(provider: .together, code: status)
            }
        }

        guard let first = pages.first else {
            throw TogetherBillingUsageError.malformed("Together billing usage returned no pages.")
        }
        return first.merging(pages.dropFirst())
    }

    private func performJSONGET(
        url: URL,
        apiKey: String,
        session: URLSession
    ) async throws -> (Int, Any) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw QuotaServiceError.invalidResponse("Together returned a non-HTTP response.")
        }
        let object: Any
        if data.isEmpty {
            object = [String: Any]()
        } else if let parsed = try? JSONSerialization.jsonObject(with: data) {
            object = parsed
        } else if (200..<300).contains(http.statusCode) {
            throw TogetherBillingUsageError.malformed("Together billing usage payload was not valid JSON.")
        } else {
            object = [String: Any]()
        }
        return (http.statusCode, object)
    }

    // MARK: - Snapshots

    private func snapshot(for report: TogetherBillingUsageReport) -> ProviderQuotaSnapshot {
        let month = report.billingPeriod ?? Self.billingMonth(now: now())
        let cost = report.totalCostUSD
        let formatted = Self.currencyString(cost)
        let buckets = [
            ProviderQuotaBucket(
                key: "together-billing-usage-\(month)",
                label: "Together spend (\(month))",
                windowKind: .monthly,
                usedValue: cost,
                limitValue: nil,
                remainingValue: nil,
                usedPercent: nil,
                resetsAt: nil,
                unit: .currency,
                isEstimated: false
            )
        ]
        return ProviderQuotaSnapshot(
            provider: .together,
            fetchedAt: now(),
            source: .officialAPI,
            confidence: .exact,
            managementURL: Self.managementURL,
            statusMessage: "Together billed \(formatted) in \(month). Remaining prepaid credits are console-only (Together signs in with Google or GitHub, not Facebook).",
            buckets: buckets
        )
    }

    private func snapshot(for error: TogetherBillingUsageError) -> ProviderQuotaSnapshot {
        ProviderQuotaSnapshot(
            provider: .together,
            fetchedAt: now(),
            source: .officialAPI,
            confidence: .unavailable,
            managementURL: Self.managementURL,
            statusMessage: error.statusMessage,
            buckets: []
        )
    }

    // MARK: - Resolution

    static func resolveAPIKey(context: ProviderQuotaAdapterContext) -> String? {
        let identifiers = [
            "together",
            "meta",
            "meta-together-key",
            "llama",
            "together_api_key",
            "together-api-key"
        ]
        for identifier in identifiers {
            if let key = quotaNonEmpty(context.resolvedAPIKeys[identifier] ?? nil) {
                return key
            }
        }
        return context.cursorConnectorCredential(for: "provider.together.apiKey")
            ?? context.cursorConnectorCredential(for: "provider.meta.apiKey")
            ?? quotaNonEmpty(context.environment["TOGETHER_API_KEY"])
            ?? quotaNonEmpty(context.environment["META_TOGETHER_API_KEY"])
    }

    static func billingMonth(now: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month], from: now)
        let year = parts.year ?? 1970
        let month = parts.month ?? 1
        return String(format: "%04d-%02d", year, month)
    }

    static func billingUsageURL(
        context: ProviderQuotaAdapterContext,
        month: String,
        after: String? = nil
    ) -> URL? {
        if let explicit = quotaNonEmpty(context.environment["TOGETHER_BILLING_USAGE_URL"]), after == nil {
            return URL(string: explicit)
        }
        let rawBase = quotaNonEmpty(context.environment["TOGETHER_API_BASE_URL"])
            ?? quotaNonEmpty(context.environment["TOGETHER_BASE_URL"])
            ?? Self.defaultAPIBaseURL.absoluteString
        guard var components = URLComponents(string: rawBase) else { return nil }
        var path = components.path
        if path.hasSuffix("/v1") {
            path.removeLast(3)
        } else if path.hasSuffix("/v1/") {
            path.removeLast(4)
        }
        components.path = path + Self.billingUsagePath
        var items = [URLQueryItem(name: "month", value: month), URLQueryItem(name: "granularity", value: "day")]
        if let after, !after.isEmpty {
            items.append(URLQueryItem(name: "after", value: after))
        }
        components.queryItems = items
        return components.url
    }

    static func inlineErrorMessage(from dictionary: [String: Any]) -> String? {
        if let error = dictionary["error"] as? [String: Any] {
            let message = FlexibleQuotaBucketNormalizer.string(in: error, keys: ["message", "msg", "error"])
                ?? "request failed"
            return "Together returned an API error: \(message)"
        }
        return nil
    }

    static func currencyString(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "$%.2f", value)
    }
}

// MARK: - Parsed report

struct TogetherBillingUsageReport: Sendable {
    var organizationID: String?
    var billingPeriod: String?
    var totalCostUSD: Double
    var nextCursor: String?

    func merging<S: Sequence>(_ others: S) -> TogetherBillingUsageReport where S.Element == TogetherBillingUsageReport {
        var merged = self
        for other in others {
            merged.totalCostUSD += other.totalCostUSD
            merged.nextCursor = other.nextCursor
            if merged.billingPeriod == nil {
                merged.billingPeriod = other.billingPeriod
            }
        }
        return merged
    }

    static func parse(_ dictionary: [String: Any]) -> TogetherBillingUsageReport {
        let windows = dictionary["data"] as? [[String: Any]] ?? []
        var total: Double = 0
        for window in windows {
            let items = window["line_items"] as? [[String: Any]] ?? []
            for item in items {
                if let cost = decimalNumber(in: item, key: "cost") {
                    total += cost
                }
            }
        }
        return TogetherBillingUsageReport(
            organizationID: FlexibleQuotaBucketNormalizer.string(in: dictionary, keys: ["organization_id", "organizationId"]),
            billingPeriod: FlexibleQuotaBucketNormalizer.string(in: dictionary, keys: ["billing_period", "billingPeriod"]),
            totalCostUSD: total,
            nextCursor: FlexibleQuotaBucketNormalizer.string(in: dictionary, keys: ["next_cursor", "nextCursor"])
        )
    }

    private static func decimalNumber(in dictionary: [String: Any], key: String) -> Double? {
        if let number = dictionary[key] as? NSNumber {
            return number.doubleValue
        }
        if let value = dictionary[key] as? Double {
            return value
        }
        if let value = dictionary[key] as? Int {
            return Double(value)
        }
        if let text = dictionary[key] as? String {
            return Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }
}

enum TogetherBillingUsageError: Error {
    case notEnabled
    case unauthorized(Int)
    case rateLimited
    case malformed(String)

    var statusMessage: String {
        switch self {
        case .notEnabled:
            return "Together has not enabled billing usage for this org. BurnBar will keep routing Llama and show harvested spend, not a remaining-credit window. Together console sign-in is Google or GitHub, not Facebook."
        case .unauthorized:
            return "Together rejected this API key. Reconnect a Together / Llama key to refresh usage meters."
        case .rateLimited:
            return "Together rate-limited the billing usage request. Retry shortly to refresh the Llama usage meter."
        case .malformed(let message):
            return message
        }
    }
}
