import Foundation
import OpenBurnBarKernel

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Remaining Gemini API / Vertex AI project quotas from Google Cloud.
///
/// Limits come from Service Usage `consumerQuotaMetrics`. Current usage comes
/// from Cloud Monitoring `serviceruntime.googleapis.com/quota/*`. Remaining is
/// `limit - used`. This is rate/allocation quota, not Verizon Gemini app
/// battery and not AI Studio-key remaining.
public struct GoogleCloudQuotaFetchResult: Equatable, Sendable {
    public let buckets: [ProviderQuotaBucket]
    public let statusMessage: String
    public let projectID: String
    public let hadAPIError: Bool

    public init(
        buckets: [ProviderQuotaBucket],
        statusMessage: String,
        projectID: String,
        hadAPIError: Bool
    ) {
        self.buckets = buckets
        self.statusMessage = statusMessage
        self.projectID = projectID
        self.hadAPIError = hadAPIError
    }
}

public struct GoogleCloudQuotaLimit: Equatable, Sendable {
    public enum Window: String, Sendable {
        case daily
        case minute
        case other
    }

    public enum Kind: String, Sendable {
        case tokens
        case requests
        case other
    }

    public let service: String
    public let metric: String
    public let displayName: String
    public let unit: String
    public let effectiveLimit: Double
    public let dimensions: [String: String]
    public let window: Window
    public let kind: Kind

    public init(
        service: String,
        metric: String,
        displayName: String,
        unit: String,
        effectiveLimit: Double,
        dimensions: [String: String],
        window: Window,
        kind: Kind
    ) {
        self.service = service
        self.metric = metric
        self.displayName = displayName
        self.unit = unit
        self.effectiveLimit = effectiveLimit
        self.dimensions = dimensions
        self.window = window
        self.kind = kind
    }
}

public struct GoogleCloudQuotaUsage: Equatable, Sendable {
    public let service: String
    public let metric: String
    public let location: String?
    public let used: Double

    public init(service: String, metric: String, location: String?, used: Double) {
        self.service = service
        self.metric = metric
        self.location = location
        self.used = used
    }
}

public enum GoogleCloudQuotaClient: Sendable {
    public static let serviceUsageHost = "https://serviceusage.googleapis.com"
    public static let monitoringHost = "https://monitoring.googleapis.com"
    public static let consoleURL = "https://console.cloud.google.com/iam-admin/quotas"
    public static let maxPages = 5
    public static let maxSelectedBuckets = 8

    public static func fetchRemaining(
        identity: GoogleCloudQuotaIdentity,
        session: URLSession,
        now: Date = Date()
    ) async -> GoogleCloudQuotaFetchResult {
        var limits: [GoogleCloudQuotaLimit] = []
        var usages: [GoogleCloudQuotaUsage] = []
        var errors: [String] = []

        for service in [
            GoogleCloudQuotaCredentialResolver.generativeLanguageService,
            GoogleCloudQuotaCredentialResolver.vertexService
        ] {
            switch await fetchLimits(identity: identity, service: service, session: session) {
            case .success(let page):
                limits.append(contentsOf: page)
            case .failure(let message):
                errors.append(message)
            }
        }

        switch await fetchUsage(
            identity: identity,
            session: session,
            metricType: "serviceruntime.googleapis.com/quota/allocation/usage",
            start: now.addingTimeInterval(-26 * 60 * 60),
            end: now
        ) {
        case .success(let points):
            usages.append(contentsOf: points)
        case .failure(let message):
            errors.append(message)
        }

        switch await fetchUsage(
            identity: identity,
            session: session,
            metricType: "serviceruntime.googleapis.com/quota/rate/net_usage",
            start: now.addingTimeInterval(-15 * 60),
            end: now
        ) {
        case .success(let points):
            usages.append(contentsOf: points)
        case .failure(let message):
            errors.append(message)
        }

        let buckets = selectBuckets(limits: limits, usage: usages)
        if !buckets.isEmpty {
            let services = Set(buckets.compactMap { $0.meta?["gcpService"] }).sorted()
            let serviceLabel = services.isEmpty
                ? "Gemini API / Vertex"
                : services.joined(separator: " and ")
            return GoogleCloudQuotaFetchResult(
                buckets: buckets,
                statusMessage: "Remaining \(serviceLabel) project quotas come from Google Cloud Service Usage and Cloud Monitoring for project \(identity.projectID).",
                projectID: identity.projectID,
                hadAPIError: false
            )
        }

        if !errors.isEmpty {
            return GoogleCloudQuotaFetchResult(
                buckets: [],
                statusMessage: errors.joined(separator: " "),
                projectID: identity.projectID,
                hadAPIError: true
            )
        }

        if limits.isEmpty {
            return GoogleCloudQuotaFetchResult(
                buckets: [],
                statusMessage: "Google Cloud authenticated for project \(identity.projectID), but no Gemini API or Vertex consumer quota metrics were visible. Enable generativelanguage.googleapis.com or aiplatform.googleapis.com and grant Service Usage Consumer plus Monitoring Viewer.",
                projectID: identity.projectID,
                hadAPIError: false
            )
        }

        return GoogleCloudQuotaFetchResult(
            buckets: [],
            statusMessage: "Google Cloud listed quota limits for project \(identity.projectID), but none were Gemini / Vertex remaining meters with a usable numeric cap.",
            projectID: identity.projectID,
            hadAPIError: false
        )
    }

    public static func parseConsumerQuotaMetrics(data: Data, service: String) throws -> (limits: [GoogleCloudQuotaLimit], nextPageToken: String?) {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QuotaServiceError.invalidResponse("Service Usage returned a non-object payload.")
        }
        let metrics = object["metrics"] as? [[String: Any]] ?? []
        var limits: [GoogleCloudQuotaLimit] = []
        for metricObject in metrics {
            let metric = stringValue(metricObject["metric"]) ?? ""
            let displayName = stringValue(metricObject["displayName"]) ?? metric
            let metricUnit = stringValue(metricObject["unit"]) ?? ""
            guard isGeminiRelevant(metric: metric, displayName: displayName, service: service) else {
                continue
            }
            let consumerLimits = metricObject["consumerQuotaLimits"] as? [[String: Any]] ?? []
            for limitObject in consumerLimits {
                let unit = stringValue(limitObject["unit"]) ?? metricUnit
                let buckets = limitObject["quotaBuckets"] as? [[String: Any]] ?? []
                if buckets.isEmpty {
                    if let value = numericValue(limitObject["effectiveLimit"]) ?? numericValue(limitObject["defaultLimit"]),
                       value > 0 {
                        limits.append(
                            makeLimit(
                                service: service,
                                metric: metric,
                                displayName: displayName,
                                unit: unit,
                                effectiveLimit: value,
                                dimensions: [:]
                            )
                        )
                    }
                    continue
                }
                for bucket in buckets {
                    guard let value = numericValue(bucket["effectiveLimit"]) ?? numericValue(bucket["defaultLimit"]),
                          value > 0 else {
                        continue
                    }
                    let dimensions = stringMap(bucket["dimensions"])
                    limits.append(
                        makeLimit(
                            service: service,
                            metric: metric,
                            displayName: displayName,
                            unit: unit,
                            effectiveLimit: value,
                            dimensions: dimensions
                        )
                    )
                }
            }
        }
        return (limits, stringValue(object["nextPageToken"]))
    }

    public static func parseTimeSeries(data: Data) throws -> [GoogleCloudQuotaUsage] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QuotaServiceError.invalidResponse("Cloud Monitoring returned a non-object payload.")
        }
        let series = object["timeSeries"] as? [[String: Any]] ?? []
        var usages: [GoogleCloudQuotaUsage] = []
        for item in series {
            let metricObject = item["metric"] as? [String: Any] ?? [:]
            let labels = stringMap(metricObject["labels"])
            let resource = item["resource"] as? [String: Any] ?? [:]
            let resourceLabels = stringMap(resource["labels"])
            let metric = labels["quota_metric"]
                ?? labels["quotaMetric"]
                ?? stringValue(metricObject["type"])
                ?? ""
            let service = resourceLabels["service"] ?? serviceFromMetric(metric)
            let location = resourceLabels["location"] ?? labels["location"] ?? resourceLabels["region"]
            let points = item["points"] as? [[String: Any]] ?? []
            guard let point = points.first,
                  let used = numericValue((point["value"] as? [String: Any]).flatMap { $0 } ) else {
                continue
            }
            usages.append(
                GoogleCloudQuotaUsage(
                    service: service,
                    metric: metric,
                    location: location,
                    used: used
                )
            )
        }
        return usages
    }

    public static func selectBuckets(
        limits: [GoogleCloudQuotaLimit],
        usage: [GoogleCloudQuotaUsage]
    ) -> [ProviderQuotaBucket] {
        var scored: [(score: Int, bucket: ProviderQuotaBucket, group: String)] = []
        for limit in limits where limit.effectiveLimit > 0 && limit.kind != .other {
            let used = matchingUsage(limit: limit, usage: usage) ?? 0
            let remaining = max(0, limit.effectiveLimit - used)
            let usedPercent = min(100, max(0, (used / limit.effectiveLimit) * 100))
            let bucket = ProviderQuotaBucket(
                key: bucketKey(for: limit),
                label: bucketLabel(for: limit),
                windowKind: limit.window == .daily ? .daily : (limit.window == .minute ? .custom : .custom),
                usedValue: used,
                limitValue: limit.effectiveLimit,
                remainingValue: remaining,
                usedPercent: usedPercent,
                resetsAt: nil,
                unit: limit.kind == .tokens ? .tokens : .requests,
                isEstimated: false
            )
            var meta = bucket.meta ?? [:]
            meta["gcpService"] = productLabel(for: limit.service)
            meta["gcpMetric"] = limit.metric
            meta["gcpWindow"] = limit.window.rawValue
            let grouped = ProviderQuotaBucket(
                name: bucket.key,
                used: bucket.used,
                limit: bucket.limit,
                remaining: bucket.remaining,
                window: bucket.window,
                meta: meta,
                resetsAt: nil
            )
            scored.append((
                score(limit: limit, used: used),
                grouped,
                "\(productLabel(for: limit.service))|\(limit.window.rawValue)|\(limit.kind.rawValue)"
            ))
        }

        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.bucket.label.localizedCompare(rhs.bucket.label) == .orderedAscending
        }

        var seenGroups = Set<String>()
        var selected: [ProviderQuotaBucket] = []
        for item in scored {
            if seenGroups.contains(item.group) { continue }
            seenGroups.insert(item.group)
            selected.append(item.bucket)
            if selected.count >= maxSelectedBuckets { break }
        }
        return selected
    }

    public static func isGeminiRelevant(metric: String, displayName: String, service: String) -> Bool {
        let hay = "\(metric) \(displayName)".lowercased()
        if hay.contains("tuning") || hay.contains("embedding") || hay.contains("batch prediction") {
            return false
        }
        if hay.contains("generate_content") || hay.contains("generate content") || hay.contains("generatecontent") {
            return true
        }
        if hay.contains("gemini") {
            return true
        }
        if service == GoogleCloudQuotaCredentialResolver.generativeLanguageService {
            return hay.contains("request") || hay.contains("token")
        }
        if service == GoogleCloudQuotaCredentialResolver.vertexService {
            return hay.contains("token") && (hay.contains("predict") || hay.contains("online"))
        }
        return false
    }

    static func classifyWindow(metric: String, displayName: String, unit: String) -> GoogleCloudQuotaLimit.Window {
        let hay = "\(metric) \(displayName) \(unit)".lowercased()
        if hay.contains("/d") || hay.contains("per day") || hay.contains("per_day") || hay.contains("daily") {
            return .daily
        }
        if hay.contains("/min") || hay.contains("per minute") || hay.contains("per_minute") || hay.contains("rpm") || hay.contains("tpm") {
            return .minute
        }
        return .other
    }

    static func classifyKind(metric: String, displayName: String, unit: String) -> GoogleCloudQuotaLimit.Kind {
        let hay = "\(metric) \(displayName) \(unit)".lowercased()
        if hay.contains("token") {
            return .tokens
        }
        if hay.contains("request") || hay.contains("call") {
            return .requests
        }
        return .other
    }

    private static func fetchLimits(
        identity: GoogleCloudQuotaIdentity,
        service: String,
        session: URLSession
    ) async -> Result<[GoogleCloudQuotaLimit], String> {
        var all: [GoogleCloudQuotaLimit] = []
        var pageToken: String?
        for _ in 0..<maxPages {
            var components = URLComponents(
                string: "\(serviceUsageHost)/v1beta1/projects/\(identity.projectID)/services/\(service)/consumerQuotaMetrics"
            )!
            var items = [
                URLQueryItem(name: "view", value: "FULL"),
                URLQueryItem(name: "pageSize", value: "200")
            ]
            if let pageToken {
                items.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            components.queryItems = items
            guard let url = components.url else {
                return .failure("Service Usage URL for \(service) could not be built.")
            }
            do {
                let (data, status) = try await authorizedGET(url, identity: identity, session: session)
                if let error = apiErrorMessage(status: status, data: data, projectID: identity.projectID, api: "Service Usage") {
                    return .failure(error)
                }
                let parsed = try parseConsumerQuotaMetrics(data: data, service: service)
                all.append(contentsOf: parsed.limits)
                pageToken = parsed.nextPageToken
                if pageToken == nil { break }
            } catch {
                return .failure("Service Usage request for \(service) failed: \(error.localizedDescription)")
            }
        }
        return .success(all)
    }

    private static func fetchUsage(
        identity: GoogleCloudQuotaIdentity,
        session: URLSession,
        metricType: String,
        start: Date,
        end: Date
    ) async -> Result<[GoogleCloudQuotaUsage], String> {
        var components = URLComponents(
            string: "\(monitoringHost)/v3/projects/\(identity.projectID)/timeSeries"
        )!
        let filter = """
        metric.type="\(metricType)" AND resource.type="consumer_quota" AND (resource.labels.service="\(GoogleCloudQuotaCredentialResolver.generativeLanguageService)" OR resource.labels.service="\(GoogleCloudQuotaCredentialResolver.vertexService)")
        """
        components.queryItems = [
            URLQueryItem(name: "filter", value: filter),
            URLQueryItem(name: "interval.startTime", value: ThreadSafeISO8601DateFormatter.formatBasic(start)),
            URLQueryItem(name: "interval.endTime", value: ThreadSafeISO8601DateFormatter.formatBasic(end)),
            URLQueryItem(name: "view", value: "FULL")
        ]
        guard let url = components.url else {
            return .failure("Cloud Monitoring URL could not be built.")
        }
        do {
            let (data, status) = try await authorizedGET(url, identity: identity, session: session)
            if let error = apiErrorMessage(status: status, data: data, projectID: identity.projectID, api: "Cloud Monitoring") {
                return .failure(error)
            }
            return .success(try parseTimeSeries(data: data))
        } catch {
            return .failure("Cloud Monitoring request failed: \(error.localizedDescription)")
        }
    }

    private static func authorizedGET(
        _ url: URL,
        identity: GoogleCloudQuotaIdentity,
        session: URLSession
    ) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(identity.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        return (data, status)
    }

    private static func apiErrorMessage(status: Int, data: Data, projectID: String, api: String) -> String? {
        guard !(200..<300).contains(status) else { return nil }
        let body = String(data: data, encoding: .utf8) ?? ""
        switch status {
        case 401:
            return "\(api) rejected the Google Cloud credentials for project \(projectID). Re-run `gcloud auth application-default login` or paste a fresh service account JSON."
        case 403:
            return "\(api) denied quota reads for project \(projectID). Grant Service Usage Consumer and Monitoring Viewer."
        case 404:
            return "\(api) did not find Gemini / Vertex quota for project \(projectID). Enable the APIs or check the project id."
        default:
            let snippet = body.replacingOccurrences(of: "\n", with: " ")
            let clipped = snippet.count > 160 ? String(snippet.prefix(160)) + "…" : snippet
            return "\(api) returned HTTP \(status) for project \(projectID)\(clipped.isEmpty ? "." : ": \(clipped)")"
        }
    }

    private static func makeLimit(
        service: String,
        metric: String,
        displayName: String,
        unit: String,
        effectiveLimit: Double,
        dimensions: [String: String]
    ) -> GoogleCloudQuotaLimit {
        GoogleCloudQuotaLimit(
            service: service,
            metric: metric,
            displayName: displayName,
            unit: unit,
            effectiveLimit: effectiveLimit,
            dimensions: dimensions,
            window: classifyWindow(metric: metric, displayName: displayName, unit: unit),
            kind: classifyKind(metric: metric, displayName: displayName, unit: unit)
        )
    }

    private static func matchingUsage(
        limit: GoogleCloudQuotaLimit,
        usage: [GoogleCloudQuotaUsage]
    ) -> Double? {
        let wantedLocation = limit.dimensions["region"]
            ?? limit.dimensions["location"]
            ?? limit.dimensions["zone"]
        let matches = usage.filter { point in
            guard point.metric == limit.metric || point.metric.hasSuffix(limit.metric) else {
                return false
            }
            if !point.service.isEmpty && point.service != limit.service {
                return false
            }
            if let wantedLocation, let pointLocation = point.location, !pointLocation.isEmpty {
                return pointLocation == wantedLocation
            }
            return true
        }
        return matches.map(\.used).max()
    }

    private static func score(limit: GoogleCloudQuotaLimit, used: Double) -> Int {
        var value = 0
        switch limit.window {
        case .daily: value += 100
        case .minute: value += 40
        case .other: value += 10
        }
        switch limit.kind {
        case .tokens: value += 30
        case .requests: value += 20
        case .other: value += 0
        }
        let hay = "\(limit.metric) \(limit.displayName)".lowercased()
        if hay.contains("generate_content") || hay.contains("generate content") {
            value += 25
        }
        if limit.dimensions.isEmpty || (limit.dimensions["location"] ?? limit.dimensions["region"]) == "global" {
            value += 10
        }
        if used > 0 {
            value += 5
        }
        return value
    }

    private static func bucketKey(for limit: GoogleCloudQuotaLimit) -> String {
        let product = limit.service.contains("aiplatform") ? "vertex" : "gemini-api"
        let location = (limit.dimensions["region"] ?? limit.dimensions["location"] ?? "global")
            .replacingOccurrences(of: "/", with: "-")
        return "gcp-\(product)-\(limit.kind.rawValue)-\(limit.window.rawValue)-\(location)"
    }

    private static func bucketLabel(for limit: GoogleCloudQuotaLimit) -> String {
        let product = productLabel(for: limit.service)
        let unit = limit.kind == .tokens ? "tokens" : "requests"
        let location = limit.dimensions["region"] ?? limit.dimensions["location"]
        let suffix = (location == nil || location == "global") ? "" : " (\(location!))"
        switch limit.window {
        case .daily:
            return "\(product) \(unit) remaining today\(suffix)"
        case .minute:
            return "\(product) \(unit) remaining this minute\(suffix)"
        case .other:
            return "\(product) \(limit.displayName) remaining\(suffix)"
        }
    }

    private static func productLabel(for service: String) -> String {
        service.contains("aiplatform") ? "Vertex AI" : "Gemini API"
    }

    private static func serviceFromMetric(_ metric: String) -> String {
        if metric.hasPrefix("aiplatform.") {
            return GoogleCloudQuotaCredentialResolver.vertexService
        }
        if metric.hasPrefix("generativelanguage.") {
            return GoogleCloudQuotaCredentialResolver.generativeLanguageService
        }
        return ""
    }

    private static func stringValue(_ raw: Any?) -> String? {
        guard let text = raw as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func stringMap(_ raw: Any?) -> [String: String] {
        guard let object = raw as? [String: Any] else { return [:] }
        var map: [String: String] = [:]
        for (key, value) in object {
            if let text = stringValue(value) {
                map[key] = text
            }
        }
        return map
    }

    private static func numericValue(_ raw: Any?) -> Double? {
        if let number = raw as? NSNumber {
            return number.doubleValue
        }
        if let value = raw as? Double {
            return value
        }
        if let value = raw as? Int {
            return Double(value)
        }
        if let text = raw as? String, let value = Double(text) {
            return value
        }
        if let object = raw as? [String: Any] {
            return numericValue(object["int64Value"])
                ?? numericValue(object["doubleValue"])
                ?? numericValue(object["effectiveLimit"])
        }
        return nil
    }
}
