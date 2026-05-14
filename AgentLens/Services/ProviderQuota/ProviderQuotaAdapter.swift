import Foundation
import SQLite3


protocol ProviderQuotaAdapter: Sendable {
    func fetch(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot
}

struct ProviderQuotaAdapterContext {
    let appPaths: OpenBurnBarAppPaths
    let fileManager: FileManager
    let session: URLSession
    let environment: [String: String]
    let homeDirectoryURL: URL
    let dataStoreActor: DataStoreActor
    let snapshotStore: ProviderQuotaSnapshotStore
    let bridgeManager: ClaudeQuotaBridgeManager
    let miniMaxModeProvider: () -> MiniMaxQuotaMode
    let factoryPlanProvider: () -> FactoryQuotaPlanTier
    let claudeBridgeStatus: ClaudeQuotaBridgeStatus
    let codexRolloutScanCache: CodexRolloutScanCache
    let updateCodexRolloutScanCache: (CodexRolloutScanCache, Bool) -> Void
    let refreshClaudeBridgeStatus: () -> ClaudeQuotaBridgeStatus
    /// Optional explicit Claude OAuth credentials. Production uses
    /// `NoClaudeCredentialsReader` so OpenBurnBar never reads Claude
    /// Code's Keychain item or `.credentials.json` fallback.
    let claudeCredentialsReader: any ClaudeCredentialsReading

    /// Pre-resolved API keys (read from ProviderAPIKeyStore on the main actor before dispatch).
    let resolvedAPIKeys: [String: String?]
}

// All properties are value types (Sendable); no @unchecked needed.
extension ProviderQuotaAdapterContext: Sendable {}

extension ProviderQuotaAdapterContext {
    func withResolvedAPIKeys(_ resolvedAPIKeys: [String: String?]) -> ProviderQuotaAdapterContext {
        ProviderQuotaAdapterContext(
            appPaths: appPaths,
            fileManager: fileManager,
            session: session,
            environment: environment,
            homeDirectoryURL: homeDirectoryURL,
            dataStoreActor: dataStoreActor,
            snapshotStore: snapshotStore,
            bridgeManager: bridgeManager,
            miniMaxModeProvider: miniMaxModeProvider,
            factoryPlanProvider: factoryPlanProvider,
            claudeBridgeStatus: claudeBridgeStatus,
            codexRolloutScanCache: codexRolloutScanCache,
            updateCodexRolloutScanCache: updateCodexRolloutScanCache,
            refreshClaudeBridgeStatus: refreshClaudeBridgeStatus,
            claudeCredentialsReader: claudeCredentialsReader,
            resolvedAPIKeys: resolvedAPIKeys
        )
    }
}

extension ProviderQuotaAdapter {
    func unavailableSnapshot(
        for provider: AgentProvider,
        source: ProviderQuotaSourceKind,
        message: String
    ) -> ProviderQuotaSnapshot {
        ProviderQuotaSnapshot(
            provider: provider,
            fetchedAt: Date(),
            source: source,
            confidence: .unavailable,
            managementURL: nil,
            statusMessage: message,
            buckets: []
        )
    }
}

struct OpenAIQuotaAdapter: ProviderQuotaAdapter {
    func fetch(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot {
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

struct OpenCodeQuotaAdapter: ProviderQuotaAdapter {
    func fetch(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot {
        let authURL = context.homeDirectoryURL.appendingPathComponent(".local/share/opencode/auth.json")
        guard context.fileManager.fileExists(atPath: authURL.path) else {
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
        async let oneDayOutput = try? Self.runOpenCodeStats(days: 1, environment: context.environment)
        async let sevenDayOutput = try? Self.runOpenCodeStats(days: 7, environment: context.environment)
        async let thirtyDayOutput = try? Self.runOpenCodeStats(days: 30, environment: context.environment)
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

    private static func runOpenCodeStats(days: Int, environment: [String: String]) async throws -> String {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["opencode", "stats", "--days", String(days), "--models", "10"]
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
            let output = Pipe()
            let error = Pipe()
            process.standardOutput = output
            process.standardError = error
            try process.run()
            process.waitUntilExit()
            let stdout = output.fileHandleForReading.readDataToEndOfFile()
            let stderr = error.fileHandleForReading.readDataToEndOfFile()
            let stdoutText = String(data: stdout, encoding: .utf8) ?? ""
            let stderrText = String(data: stderr, encoding: .utf8) ?? ""
            return stdoutText + "\n" + stderrText
        }.value
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
        await Task.detached(priority: .utility) {
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

            var db: OpaquePointer?
            let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
            guard sqlite3_open_v2(dbURL.path, &db, flags, nil) == SQLITE_OK, let db else {
                return nil
            }
            defer { sqlite3_close(db) }
            sqlite3_busy_timeout(db, 2_000)

            let sql = """
            SELECT COALESCE(SUM(json_extract(data, '$.cost')), 0)
            FROM message
            WHERE json_extract(data, '$.role') = 'assistant'
              AND time_created >= (CAST(strftime('%s','now') AS INTEGER) * 1000 - 5 * 60 * 60 * 1000)
            """

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                return nil
            }
            defer { sqlite3_finalize(statement) }

            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return sqlite3_column_double(statement, 0)
        }.value
    }

    private static func totalCost(in output: String) -> Double? {
        let totalPattern = #"(?i)\bTotal\s+Cost\b[^$]*\$\s*([0-9]+(?:\.[0-9]+)?)"#
        if let value = firstMatch(pattern: totalPattern, in: output) {
            return value
        }
        return firstMatch(pattern: #"\$\s*([0-9]+(?:\.[0-9]+)?)"#, in: output)
    }

    private static func firstMatch(pattern: String, in output: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
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
