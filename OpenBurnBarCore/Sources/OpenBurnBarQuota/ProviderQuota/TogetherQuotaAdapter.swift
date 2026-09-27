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
// Phase 2 remaining prepaid credits: still console-only. Official OpenAPI
// has no Bearer balance/credits endpoint. Folklore `/v1/billing/balance`
// 404s to the Together console HTML app. This adapter never requests those
// paths, never scrapes WKWebView, and never invents remaining % / limit
// from spend. A 404 on billing-usage is an explicit unsupported
// remaining-credit state, not a fake meter.

public struct TogetherQuotaAdapter: ProviderQuotaAdapter {
    public static let billingUsagePath = "/v1/billing/usage"
    public static let defaultAPIBaseURL = URL(staticString: "https://api.together.ai")
    public static let managementURL = "https://api.together.ai/settings/billing"
    public static let maxUsagePages = 8
    public static let folkloreBalancePaths = TogetherRemainingCreditsMeter.folkloreBalancePaths

    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    public func fetch(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot {
        guard let apiKey = Self.resolveAPIKey(context: context) else {
            return unavailableSnapshot(
                for: .together,
                source: .officialAPI,
                message: "Add a Together / Llama API key to report month-to-date Together usage. \(TogetherRemainingCreditsMeter.unsupportedStatus)"
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
            let (status, body) = try await performJSONGET(url: requestURL, apiKey: apiKey, session: context.session)
            switch status {
            case 200:
                guard let payload = try? JSONDecoder().decode(TogetherBillingUsagePayload.self, from: body) else {
                    throw TogetherBillingUsageError.malformed("Together billing usage payload was not a JSON object.")
                }
                if let inline = Self.inlineErrorMessage(from: payload) {
                    throw TogetherBillingUsageError.malformed(inline)
                }
                let page = TogetherBillingUsageReport(payload)
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
    ) async throws -> (Int, Data) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw QuotaServiceError.invalidResponse("Together returned a non-HTTP response.")
        }
        // An empty body reads as an empty object; invalid JSON on a success
        // status is reported as such, and ignored on error statuses.
        let emptyObject = Data("{}".utf8)
        if data.isEmpty {
            return (http.statusCode, emptyObject)
        }
        if (try? JSONSerialization.jsonObject(with: data)) == nil {
            if (200..<300).contains(http.statusCode) {
                throw TogetherBillingUsageError.malformed("Together billing usage payload was not valid JSON.")
            }
            return (http.statusCode, emptyObject)
        }
        return (http.statusCode, data)
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
            statusMessage: "Together billed \(formatted) in \(month). \(TogetherRemainingCreditsMeter.fullUnsupportedMessage)",
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
        calendar.timeZone = .gmt
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

    static func inlineErrorMessage(from payload: TogetherBillingUsagePayload) -> String? {
        guard let error = payload.error else { return nil }
        return "Together returned an API error: \(error.message ?? "request failed")"
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

    init(organizationID: String?, billingPeriod: String?, totalCostUSD: Double, nextCursor: String?) {
        self.organizationID = organizationID
        self.billingPeriod = billingPeriod
        self.totalCostUSD = totalCostUSD
        self.nextCursor = nextCursor
    }

    init(_ payload: TogetherBillingUsagePayload) {
        self.init(
            organizationID: payload.organizationID,
            billingPeriod: payload.billingPeriod,
            totalCostUSD: payload.windows.flatMap(\.lineItemCosts).reduce(0, +),
            nextCursor: payload.nextCursor
        )
    }
}

/// Typed projection of `GET /v1/billing/usage`. Decoding is lenient field by
/// field (a value of an unexpected shape reads as absent) so a schema drift in
/// one field never hides the month-to-date spend in the others; the document
/// itself must be a JSON object.
struct TogetherBillingUsagePayload: Decodable {
    struct APIError: Decodable {
        let message: String?

        init(from decoder: Decoder) throws {
            _ = try decoder.container(keyedBy: QuotaJSONKey.self)
            message = quotaLenientString(decoder, keys: "message", "msg", "error")
        }
    }

    struct Window: Decodable {
        struct LineItem: Decodable {
            let cost: Double?

            init(from decoder: Decoder) throws {
                cost = quotaLenientNumber(decoder, key: "cost")
            }
        }

        let lineItemCosts: [Double]

        init(from decoder: Decoder) throws {
            lineItemCosts = (quotaLenientValue([LineItem].self, decoder, key: "line_items") ?? []).compactMap(\.cost)
        }
    }

    let error: APIError?
    let organizationID: String?
    let billingPeriod: String?
    let nextCursor: String?
    let windows: [Window]

    init(from decoder: Decoder) throws {
        _ = try decoder.container(keyedBy: QuotaJSONKey.self)
        error = quotaLenientValue(APIError.self, decoder, key: "error")
        organizationID = quotaLenientString(decoder, keys: "organization_id", "organizationId")
        billingPeriod = quotaLenientString(decoder, keys: "billing_period", "billingPeriod")
        nextCursor = quotaLenientString(decoder, keys: "next_cursor", "nextCursor")
        windows = quotaLenientValue([Window].self, decoder, key: "data") ?? []
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
            return "Together has not enabled billing usage for this org. BurnBar will keep routing Llama and show harvested spend, not a remaining-credit window. \(TogetherRemainingCreditsMeter.fullUnsupportedMessage)"
        case .unauthorized:
            return "Together rejected this API key. Reconnect a Together / Llama key to refresh usage meters."
        case .rateLimited:
            return "Together rate-limited the billing usage request. Retry shortly to refresh the Llama usage meter."
        case .malformed(let message):
            return message
        }
    }
}
