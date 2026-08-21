import Foundation
import OpenBurnBarKernel
import OpenBurnBarSQLiteReader

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// OpenAI, DeepSeek, and OpenCode quota adapters (lifted WS-C2 SEAM).

public struct OpenAIQuotaAdapter: ProviderQuotaAdapter {
    public init() {}
    public func fetch(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot {
        guard let apiKey = quotaNonEmpty(context.resolvedAPIKeys["openai"] ?? nil) else {
            return unavailableSnapshot(
                for: .openAI,
                source: .officialAPI,
                message: "Add an OpenAI organization admin API key to refresh recent usage."
            )
        }

        let now = Date()
        let start = now.addingTimeInterval(-24 * 60 * 60)
        var components = URLComponents(string: "https://api.openai.com/v1/organization/usage/completions")!
        components.queryItems = [
            URLQueryItem(name: "start_time", value: String(Int(start.timeIntervalSince1970))),
            URLQueryItem(name: "end_time", value: String(Int(now.timeIntervalSince1970))),
            URLQueryItem(name: "bucket_width", value: "1d")
        ]
        guard let url = components.url else {
            return unavailableSnapshot(for: .openAI, source: .officialAPI, message: "OpenAI usage URL could not be built.")
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await context.session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw QuotaServiceError.invalidResponse("OpenAI returned a non-HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw QuotaServiceError.httpStatus(provider: .openAI, code: http.statusCode)
        }

        let totals = try parseUsageTotals(from: data)
        return ProviderQuotaSnapshot(
            provider: .openAI,
            providerID: .openAI,
            fetchedAt: now,
            source: .officialAPI,
            confidence: .exact,
            managementURL: "https://platform.openai.com/usage",
            statusMessage: "OpenAI reports recent organization usage; hard quota limits are not exposed by this endpoint.",
            buckets: [
                ProviderQuotaBucket(
                    key: "tokens-24h",
                    label: "Tokens used in the last 24 hours",
                    windowKind: .rollingHours,
                    usedValue: Double(totals.tokens),
                    limitValue: nil,
                    remainingValue: nil,
                    usedPercent: nil,
                    resetsAt: nil,
                    unit: .tokens,
                    isEstimated: false
                ),
                ProviderQuotaBucket(
                    key: "requests-24h",
                    label: "Requests in the last 24 hours",
                    windowKind: .rollingHours,
                    usedValue: Double(totals.requests),
                    limitValue: nil,
                    remainingValue: nil,
                    usedPercent: nil,
                    resetsAt: nil,
                    unit: .requests,
                    isEstimated: false
                )
            ]
        )
    }

    private func parseUsageTotals(from data: Data) throws -> (tokens: Int, requests: Int) {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QuotaServiceError.invalidResponse("OpenAI usage payload was not a JSON object.")
        }
        let buckets = object["data"] as? [[String: Any]] ?? []
        var tokens = 0
        var requests = 0

        for bucket in buckets {
            let results = bucket["results"] as? [[String: Any]] ?? [bucket]
            for result in results {
                let input = result["input_tokens"] as? Int ?? 0
                let output = result["output_tokens"] as? Int ?? 0
                tokens += input + output
                requests += result["num_model_requests"] as? Int ?? 0
            }
        }

        return (tokens, requests)
    }
}

public struct DeepSeekQuotaAdapter: ProviderQuotaAdapter {
    public init() {}
    public func fetch(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot {
        guard let apiKey = resolveAPIKey(context: context) else {
            return unavailableSnapshot(
                for: .deepSeek,
                source: .officialAPI,
                message: "Add a DeepSeek API key to report credit balance."
            )
        }

        guard let url = balanceURL(context: context) else {
            return unavailableSnapshot(
                for: .deepSeek,
                source: .officialAPI,
                message: "DeepSeek balance URL could not be built."
            )
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await context.session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw QuotaServiceError.invalidResponse("DeepSeek returned a non-HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw QuotaServiceError.httpStatus(provider: .deepSeek, code: http.statusCode)
        }

        let object = try JSONSerialization.jsonObject(with: data)
        if let inlineError = inlineErrorMessage(from: object) {
            return unavailableSnapshot(for: .deepSeek, source: .officialAPI, message: inlineError)
        }

        guard let dictionary = object as? [String: Any] else {
            return unavailableSnapshot(
                for: .deepSeek,
                source: .officialAPI,
                message: "DeepSeek balance payload was not a JSON object."
            )
        }

        let isAvailable = dictionary["is_available"] as? Bool ?? dictionary["isAvailable"] as? Bool
        let buckets = balanceBuckets(from: dictionary)
        if isAvailable == false {
            return ProviderQuotaSnapshot(
                provider: .deepSeek,
                fetchedAt: Date(),
                source: .officialAPI,
                confidence: .unavailable,
                managementURL: "https://platform.deepseek.com/usage",
                statusMessage: "DeepSeek reports that this API balance is not available.",
                buckets: buckets
            )
        }

        guard !buckets.isEmpty else {
            return unavailableSnapshot(
                for: .deepSeek,
                source: .officialAPI,
                message: "DeepSeek returned a balance response, but no recognizable credit balance was found."
            )
        }

        return ProviderQuotaSnapshot(
            provider: .deepSeek,
            fetchedAt: Date(),
            source: .officialAPI,
            confidence: .exact,
            managementURL: "https://platform.deepseek.com/usage",
            statusMessage: "Credit balance fetched from DeepSeek.",
            buckets: buckets
        )
    }

    private func resolveAPIKey(context: ProviderQuotaAdapterContext) -> String? {
        quotaNonEmpty(context.resolvedAPIKeys["deepseek"] ?? nil)
            ?? quotaNonEmpty(context.resolvedAPIKeys["deep_seek"] ?? nil)
            ?? cursorConnectorKey(for: "provider.deepseek.apiKey", context: context)
            ?? quotaNonEmpty(context.environment["DEEPSEEK_API_KEY"])
    }

    private func balanceURL(context: ProviderQuotaAdapterContext) -> URL? {
        if let explicit = quotaNonEmpty(context.environment["DEEPSEEK_BALANCE_URL"]) {
            return URL(string: explicit)
        }
        let rawBase = quotaNonEmpty(context.environment["DEEPSEEK_API_BASE_URL"])
            ?? quotaNonEmpty(context.environment["DEEPSEEK_BASE_URL"])
            ?? "https://api.deepseek.com"
        guard var url = URL(string: rawBase) else { return nil }
        if url.lastPathComponent.caseInsensitiveCompare("v1") == .orderedSame {
            url.deleteLastPathComponent()
        }
        return url
            .appendingPathComponent("user", isDirectory: false)
            .appendingPathComponent("balance", isDirectory: false)
    }

    private func balanceBuckets(from dictionary: [String: Any]) -> [ProviderQuotaBucket] {
        let balanceInfos = dictionary["balance_infos"] as? [[String: Any]]
            ?? dictionary["balanceInfos"] as? [[String: Any]]
            ?? []

        return balanceInfos.compactMap { info in
            let currency = (FlexibleQuotaBucketNormalizer.string(in: info, keys: ["currency"]) ?? "credit")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            let total = FlexibleQuotaBucketNormalizer.number(in: info, keys: ["total_balance", "totalBalance"])
            let toppedUp = FlexibleQuotaBucketNormalizer.number(in: info, keys: ["topped_up_balance", "toppedUpBalance"])
            let granted = FlexibleQuotaBucketNormalizer.number(in: info, keys: ["granted_balance", "grantedBalance"])
            let balance = total ?? [toppedUp, granted].compactMap { $0 }.reduce(0.0, +)
            guard total != nil || toppedUp != nil || granted != nil else { return nil }

            let isUSD = currency == "USD" || currency == "$"
            return ProviderQuotaBucket(
                key: "deepseek-\(FlexibleQuotaBucketNormalizer.sanitizeKey(currency))-credit-balance",
                label: isUSD ? "Credit balance" : "\(currency) credit balance",
                windowKind: .lifetime,
                usedValue: nil,
                limitValue: nil,
                remainingValue: max(0, balance),
                usedPercent: nil,
                resetsAt: nil,
                unit: isUSD ? .currency : .count,
                isEstimated: false
            )
        }
    }

    private func inlineErrorMessage(from object: Any) -> String? {
        guard let dictionary = object as? [String: Any] else { return nil }
        if let error = dictionary["error"] as? [String: Any] {
            let message = FlexibleQuotaBucketNormalizer.string(in: error, keys: ["message", "msg", "error"])
                ?? "request failed"
            return "DeepSeek returned an API error: \(message)"
        }
        if let code = FlexibleQuotaBucketNormalizer.number(in: dictionary, keys: ["code", "status"]),
           Int(code.rounded()) != 0,
           Int(code.rounded()) != 200 {
            let message = FlexibleQuotaBucketNormalizer.string(in: dictionary, keys: ["message", "msg", "error"])
                ?? "code \(Int(code.rounded()))"
            return "DeepSeek returned an API error: \(message)"
        }
        return nil
    }

    private func cursorConnectorKey(for account: String, context: ProviderQuotaAdapterContext) -> String? {
        context.cursorConnectorCredential(for: account)
    }
}

public struct OpenCodeQuotaAdapter: ProviderQuotaAdapter {
    public init() {}
    public func fetch(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot {
        let authURL = context.homeDirectoryURL.appendingPathComponent(".local/share/opencode/auth.json")
        guard context.fileManager.fileExists(atPath: authURL.path) || Self.resolvedOpenCodeCredential(context) != nil else {
            return unavailableSnapshot(
                for: .openCode,
                source: .localCLI,
                message: "Sign in to OpenCode Go or connect an OpenCode self-hosted quota runner to track quota."
            )
        }

        async let fiveHourCost = Self.localFiveHourCost(
            homeDirectoryURL: context.homeDirectoryURL,
            environment: context.environment,
            fileManager: context.fileManager
        )
        async let oneDayOutput = try? Self.runOpenCodeStats(days: 1, context: context) // try?-ok(CLI usage, empty fallback)
        async let sevenDayOutput = try? Self.runOpenCodeStats(days: 7, context: context) // try?-ok(CLI usage, empty fallback)
        async let thirtyDayOutput = try? Self.runOpenCodeStats(days: 30, context: context) // try?-ok(CLI usage, empty fallback)
        let buckets = await Self.buckets(
            fiveHourCost: fiveHourCost,
            oneDay: oneDayOutput ?? "",
            sevenDay: sevenDayOutput ?? "",
            thirtyDay: thirtyDayOutput ?? "",
            environment: context.environment
        )
        return ProviderQuotaSnapshot(
            provider: .openCode,
            providerID: .openCode,
            fetchedAt: Date(),
            source: buckets.isEmpty ? .localCLI : .localSession,
            confidence: buckets.isEmpty ? .unavailable : .estimated,
            managementURL: "https://opencode.ai/docs/go/",
            statusMessage: buckets.isEmpty
                ? "OpenCode auth was detected, but the local CLI did not expose usable cost totals. A self-hosted runner can publish the same local estimate from your own environment."
                : "OpenCode uses exact local SQLite spend for the 5-hour bucket and CLI history for 7-day/monthly plan pressure. OpenCode does not expose hosted account quota refresh yet.",
            buckets: buckets
        )
    }

    private static func resolvedOpenCodeCredential(_ context: ProviderQuotaAdapterContext) -> String? {
        quotaNonEmpty(context.resolvedAPIKeys["opencode"] ?? nil)
            ?? quotaNonEmpty(context.resolvedAPIKeys["open_code"] ?? nil)
            ?? quotaNonEmpty(context.resolvedAPIKeys["opencode_auth_json"] ?? nil)
            ?? quotaNonEmpty(context.environment["OPENCODE_API_KEY"])
            ?? quotaNonEmpty(context.environment["OPENCODE_GO_API_KEY"])
    }

    /// Blocking `Process` work runs off the main actor (`nonisolated` `async`, SE-0338).
    private static func runOpenCodeStats(days: Int, context: ProviderQuotaAdapterContext) async throws -> String {
        let env = ProcessInfo.processInfo.environment.merging(context.environment) { _, new in new }
        let data = try context.cliExecutor.run(
            executable: "/usr/bin/env",
            arguments: ["opencode", "stats", "--days", String(days), "--models", "10"],
            environment: env
        )
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func buckets(
        fiveHourCost: Double?,
        oneDay: String,
        sevenDay: String,
        thirtyDay: String,
        environment: [String: String]
    ) -> [ProviderQuotaBucket] {
        [
            bucket(
                key: "opencode-5h-estimated",
                label: fiveHourCost == nil ? "5-hour limit (24h fallback)" : "5-hour limit",
                windowKind: .rollingHours,
                used: fiveHourCost ?? totalCost(in: oneDay),
                limit: positiveLimit(environment["OPENCODE_GO_5H_LIMIT"], fallback: 12),
                isEstimated: fiveHourCost == nil
            ),
            bucket(
                key: "opencode-7d-estimated",
                label: "7-day limit",
                windowKind: .rollingDays,
                used: totalCost(in: sevenDay),
                limit: positiveLimit(environment["OPENCODE_GO_WEEKLY_LIMIT"], fallback: 30),
                isEstimated: true
            ),
            bucket(
                key: "opencode-monthly-estimated",
                label: "Monthly limit",
                windowKind: .monthly,
                used: totalCost(in: thirtyDay),
                limit: positiveLimit(environment["OPENCODE_GO_MONTHLY_LIMIT"], fallback: 60),
                isEstimated: true
            )
        ].compactMap { $0 }
    }

    private static func bucket(
        key: String,
        label: String,
        windowKind: ProviderQuotaWindowKind,
        used: Double?,
        limit: Double,
        isEstimated: Bool
    ) -> ProviderQuotaBucket? {
        guard let used, limit > 0 else { return nil }
        return ProviderQuotaBucket(
            key: key,
            label: label,
            windowKind: windowKind,
            usedValue: used,
            limitValue: limit,
            remainingValue: max(0, limit - used),
            usedPercent: min(max((used / limit) * 100, 0), 100),
            resetsAt: nil,
            unit: .currency,
            isEstimated: isEstimated
        )
    }

    private static func localFiveHourCost(
        homeDirectoryURL: URL,
        environment: [String: String],
        fileManager: FileManager
    ) async -> Double? {
        // Blocking SQLite read runs off the main actor (`nonisolated` `async`, SE-0338).
        let dbURL: URL
        if let override = environment["OPENCODE_DB_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            dbURL = URL(fileURLWithPath: override)
        } else if let dataHome = environment["OPENCODE_DATA_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !dataHome.isEmpty {
            dbURL = URL(fileURLWithPath: dataHome).appendingPathComponent("opencode.db")
        } else if let xdgDataHome = environment["XDG_DATA_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !xdgDataHome.isEmpty {
            dbURL = URL(fileURLWithPath: xdgDataHome).appendingPathComponent("opencode/opencode.db")
        } else {
            dbURL = homeDirectoryURL.appendingPathComponent(".local/share/opencode/opencode.db")
        }

        guard fileManager.fileExists(atPath: dbURL.path) else { return nil }
        do {
            let reader = try SQLiteConnection.openReadOnly(path: dbURL.path)
            defer { reader.close() }
            let sql = """
            SELECT COALESCE(SUM(json_extract(data, '$.cost')), 0) AS total_cost
            FROM message
            WHERE json_extract(data, '$.role') = 'assistant'
              AND time_created >= (CAST(strftime('%s','now') AS INTEGER) * 1000 - 5 * 60 * 60 * 1000)
            """
            let rows = try reader.query(sql, arguments: [])
            return rows.first?.double("total_cost")
        } catch {
            return nil
        }
    }

    private static func totalCost(in output: String) -> Double? {
        let totalPattern = #"(?i)\bTotal\s+Cost\b[^$]*\$\s*([0-9]+(?:\.[0-9]+)?)"#
        if let value = firstMatch(pattern: totalPattern, in: output) {
            return value
        }
        return firstMatch(pattern: #"\$\s*([0-9]+(?:\.[0-9]+)?)"#, in: output)
    }

    private static func firstMatch(pattern: String, in output: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil } // try?-ok(literal regex pattern)
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        guard let match = regex.firstMatch(in: output, range: range),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: output) else {
            return nil
        }
        return Double(output[valueRange])
    }

    private static func positiveLimit(_ raw: String?, fallback: Double) -> Double {
        guard let raw, let value = Double(raw), value > 0 else { return fallback }
        return value
    }
}
