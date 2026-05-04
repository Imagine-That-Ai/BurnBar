import Foundation

struct ClaudeQuotaAdapter: ProviderQuotaAdapter {
    private enum ScannerPolicy {
        static let maxLineBytes = 2 * 1024 * 1024
    }

    private struct JSONLTokenWindows {
        let fiveHourTokens: Int
        let sevenDayTokens: Int
        let latestTimestamp: Date?
        let filesScanned: Int
    }

    func fetch(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot {
        let bridgeStatus = context.refreshClaudeBridgeStatus()

        // Try the status line bridge first (CLI-only, exact data)
        if bridgeStatus.state == .ready,
           let payload = try? context.snapshotStore.readJSONObject(from: context.appPaths.claudeStatuslineSnapshotURL),
           let rateLimits = payload["rate_limits"] as? [String: Any] {
            let buckets = claudeQuotaBuckets(from: rateLimits)
            if !buckets.isEmpty {
                let statusMessage: String
                if claudeAPIBillingOverrideDetected(environment: context.environment) {
                    statusMessage = "Quota captured from Claude Code's local status line JSON bridge while API billing is also configured for this app process."
                } else {
                    statusMessage = "Quota captured from Claude Code's local status line JSON bridge."
                }
                return ProviderQuotaSnapshot(
                    provider: .claudeCode,
                    fetchedAt: bridgeStatus.lastPayloadAt ?? Date(),
                    source: .localCLI,
                    confidence: .exact,
                    managementURL: "https://code.claude.com/docs/en/statusline",
                    statusMessage: statusMessage,
                    buckets: buckets
                )
            }
        }

        if claudeAPIBillingOverrideDetected(environment: context.environment) {
            return unavailableSnapshot(
                for: .claudeCode,
                source: .unavailable,
                message: "ANTHROPIC_API_KEY is set for this app process. Claude Code may be using API billing instead of a Claude plan, so OpenBurnBar will only report exact local CLI quota snapshots."
            )
        }

        // Try JSONL-based token counting from local Claude project files.
        // This reads real per-API-call token counts from ~/.claude/projects/**/*.jsonl
        // and gives exact token windows without requiring the statusline bridge.
        let jsonlWindows = (try? Self.scanJSONLTokenWindows(
            homeDirectoryURL: context.homeDirectoryURL,
            fileManager: context.fileManager
        )) ?? JSONLTokenWindows(fiveHourTokens: 0, sevenDayTokens: 0, latestTimestamp: nil, filesScanned: 0)

        if jsonlWindows.fiveHourTokens > 0 || jsonlWindows.sevenDayTokens > 0 {
            var jsonlBuckets: [ProviderQuotaBucket] = []
            let now = Date()
            let calendar = Calendar.current

            if jsonlWindows.fiveHourTokens > 0 {
                jsonlBuckets.append(ProviderQuotaBucket(
                    key: "claude-five-hour-jsonl",
                    label: "5-hour window",
                    windowKind: .rollingHours,
                    usedValue: Double(jsonlWindows.fiveHourTokens),
                    limitValue: nil,
                    remainingValue: nil,
                    usedPercent: nil,
                    resetsAt: calendar.date(byAdding: .hour, value: 5, to: now),
                    unit: .tokens,
                    isEstimated: false
                ))
            }
            if jsonlWindows.sevenDayTokens > 0 {
                jsonlBuckets.append(ProviderQuotaBucket(
                    key: "claude-seven-day-jsonl",
                    label: "7-day window",
                    windowKind: .rollingDays,
                    usedValue: Double(jsonlWindows.sevenDayTokens),
                    limitValue: nil,
                    remainingValue: nil,
                    usedPercent: nil,
                    resetsAt: calendar.date(byAdding: .day, value: 7, to: now),
                    unit: .tokens,
                    isEstimated: false
                ))
            }

            return ProviderQuotaSnapshot(
                provider: .claudeCode,
                fetchedAt: jsonlWindows.latestTimestamp ?? Date(),
                source: .localSession,
                confidence: .exact,
                managementURL: nil,
                statusMessage: "Token counts from \(jsonlWindows.filesScanned) local Claude project file(s). Install the CLI bridge for rate-limit percentages.",
                buckets: jsonlBuckets
            )
        }

        // No bridge or JSONL data — return unavailable, not an estimate.
        // Real Claude quota requires either the statusline bridge or local JSONL project files.
        let fallbackMessage: String
        switch bridgeStatus.state {
        case .notInstalled, .invalidConfiguration:
            fallbackMessage = bridgeStatus.detailText
        case .disabledByHooks:
            fallbackMessage = bridgeStatus.detailText
        case .awaitingFirstPayload:
            fallbackMessage = bridgeStatus.detailText
        case .ready:
            fallbackMessage = "Bridge installed but no rate-limit payload captured yet."
        }

        if jsonlWindows.filesScanned > 0 {
            return unavailableSnapshot(
                for: .claudeCode,
                source: .localSession,
                message: "\(jsonlWindows.filesScanned) JSONL file(s) scanned but no recent token activity found. Install the CLI bridge for real-time rate limits."
            )
        }

        return unavailableSnapshot(for: .claudeCode, source: .localCLI, message: fallbackMessage)
    }

    // MARK: - File Discovery

    private static func scanJSONLTokenWindows(
        homeDirectoryURL: URL,
        fileManager: FileManager,
        now: Date = Date()
    ) throws -> JSONLTokenWindows {
        let calendar = Calendar.current
        let fiveHoursAgo = calendar.date(byAdding: .hour, value: -5, to: now) ?? now
        let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        let files = findJSONLFiles(
            in: claudeProjectDirectories(homeDirectoryURL: homeDirectoryURL),
            fileManager: fileManager
        )

        var fiveHourTokens = 0
        var sevenDayTokens = 0
        var latestTimestamp: Date?
        var filesScanned = 0

        for file in files {
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            defer { try? handle.close() }
            filesScanned += 1
            let tokens = parseTokenWindows(
                from: handle,
                fiveHoursAgo: fiveHoursAgo,
                sevenDaysAgo: sevenDaysAgo,
                now: now
            )
            fiveHourTokens += tokens.fiveHour
            sevenDayTokens += tokens.sevenDay
            if let ts = tokens.latestTimestamp {
                latestTimestamp = max(ts, latestTimestamp ?? .distantPast)
            }
        }

        return JSONLTokenWindows(
            fiveHourTokens: fiveHourTokens,
            sevenDayTokens: sevenDayTokens,
            latestTimestamp: latestTimestamp,
            filesScanned: filesScanned
        )
    }

    private static func claudeProjectDirectories(homeDirectoryURL: URL) -> [URL] {
        var dirs: [URL] = []

        if let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !env.isEmpty {
            for part in env.split(separator: ",") {
                let raw = String(part).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !raw.isEmpty else { continue }
                let url = URL(fileURLWithPath: raw)
                if url.lastPathComponent == "projects" {
                    dirs.append(url)
                } else {
                    dirs.append(url.appendingPathComponent("projects", isDirectory: true))
                }
            }
        }

        dirs.append(homeDirectoryURL.appendingPathComponent(".config/claude/projects", isDirectory: true))
        dirs.append(homeDirectoryURL.appendingPathComponent(".claude/projects", isDirectory: true))

        return dirs
    }

    private static func findJSONLFiles(in directories: [URL], fileManager: FileManager) -> [URL] {
        var files: [URL] = []
        var seen = Set<String>()

        for directory in directories {
            guard fileManager.fileExists(atPath: directory.path) else { continue }
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            while let fileURL = enumerator.nextObject() as? URL {
                guard fileURL.pathExtension.lowercased() == "jsonl" else { continue }
                let path = fileURL.standardizedFileURL.path
                guard seen.insert(path).inserted else { continue }
                files.append(fileURL)
            }
        }

        return files
    }

    // MARK: - Parsing

    private struct FileTokens {
        let fiveHour: Int
        let sevenDay: Int
        let latestTimestamp: Date?
    }

    // MARK: - Claude Helpers

    private func claudeAPIBillingOverrideDetected(environment: [String: String]) -> Bool {
        quotaNonEmpty(environment["ANTHROPIC_API_KEY"]) != nil
    }

    private func claudeQuotaBuckets(from rateLimits: [String: Any]) -> [ProviderQuotaBucket] {
        let candidates: [(String, String, ProviderQuotaWindowKind)] = [
            ("five_hour", "5-hour window", .rollingHours),
            ("seven_day", "7-day window", .rollingDays),
            ("seven_day_sonnet", "7-day Sonnet window", .rollingDays),
            ("seven_day_opus", "7-day Opus window", .rollingDays),
            ("seven_day_oauth_apps", "7-day OAuth Apps window", .rollingDays),
        ]

        return candidates.compactMap { key, label, windowKind in
            guard let payload = rateLimits[key] as? [String: Any] else { return nil }
            let usedPercent = FlexibleQuotaBucketNormalizer.number(
                in: payload,
                keys: ["used_percentage", "usedPercent", "percentage"]
            )
            let remaining = remainingPercent(from: payload)
            guard usedPercent != nil || remaining != nil else { return nil }
            return ProviderQuotaBucket(
                key: "claude-\(FlexibleQuotaBucketNormalizer.sanitizeKey(key))",
                label: label,
                windowKind: windowKind,
                usedValue: usedPercent,
                limitValue: 100,
                remainingValue: remaining,
                usedPercent: usedPercent,
                resetsAt: FlexibleQuotaBucketNormalizer.date(
                    in: payload,
                    keys: ["resets_at", "reset_at", "resetTime"]
                ),
                unit: .percent,
                isEstimated: false
            )
        }
    }

    private func remainingPercent(from dictionary: [String: Any]) -> Double? {
        guard let used = FlexibleQuotaBucketNormalizer.number(
            in: dictionary,
            keys: ["used_percentage", "usedPercent", "percentage"]
        ) else {
            return nil
        }
        return max(0, 100 - used)
    }

    private static func parseTokenWindows(
        from handle: FileHandle,
        fiveHoursAgo: Date,
        sevenDaysAgo: Date,
        now: Date
    ) -> FileTokens {
        try? handle.seek(toOffset: 0)

        var fiveHour = 0
        var sevenDay = 0
        var latestTimestamp: Date?

        var currentLine = Data()
        currentLine.reserveCapacity(4 * 1024)
        var lineByteCount = 0

        while true {
            guard let chunk = try? handle.read(upToCount: 256 * 1024), !chunk.isEmpty else {
                if lineByteCount > 0 {
                    let tokens = parseLineTokens(currentLine, fiveHoursAgo: fiveHoursAgo, sevenDaysAgo: sevenDaysAgo, now: now)
                    fiveHour += tokens.fiveHour
                    sevenDay += tokens.sevenDay
                    if let ts = tokens.timestamp {
                        latestTimestamp = max(ts, latestTimestamp ?? .distantPast)
                    }
                }
                break
            }

            var segmentStart = chunk.startIndex
            while let nl = chunk[segmentStart...].firstIndex(of: 0x0A) {
                currentLine.append(chunk[segmentStart..<nl])
                lineByteCount += chunk[segmentStart..<nl].count

                if lineByteCount > 0, lineByteCount <= ScannerPolicy.maxLineBytes {
                    let tokens = parseLineTokens(currentLine, fiveHoursAgo: fiveHoursAgo, sevenDaysAgo: sevenDaysAgo, now: now)
                    fiveHour += tokens.fiveHour
                    sevenDay += tokens.sevenDay
                    if let ts = tokens.timestamp {
                        latestTimestamp = max(ts, latestTimestamp ?? .distantPast)
                    }
                }

                currentLine.removeAll(keepingCapacity: true)
                lineByteCount = 0
                segmentStart = chunk.index(after: nl)
            }

            if segmentStart < chunk.endIndex {
                currentLine.append(chunk[segmentStart..<chunk.endIndex])
                lineByteCount += chunk[segmentStart..<chunk.endIndex].count
            }
        }

        return FileTokens(
            fiveHour: fiveHour,
            sevenDay: sevenDay,
            latestTimestamp: latestTimestamp
        )
    }

    private struct LineTokens {
        let fiveHour: Int
        let sevenDay: Int
        let timestamp: Date?
    }

    private static func parseLineTokens(
        _ data: Data,
        fiveHoursAgo: Date,
        sevenDaysAgo: Date,
        now: Date
    ) -> LineTokens {
        guard !data.isEmpty else { return LineTokens(fiveHour: 0, sevenDay: 0, timestamp: nil) }

        guard data.containsAscii(#""type""#),
              data.containsAscii(#""usage""#) else {
            return LineTokens(fiveHour: 0, sevenDay: 0, timestamp: nil)
        }

        guard data.containsAscii(#""type":"assistant""#) else {
            return LineTokens(fiveHour: 0, sevenDay: 0, timestamp: nil)
        }

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String,
              type == "assistant",
              let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any] else {
            return LineTokens(fiveHour: 0, sevenDay: 0, timestamp: nil)
        }

        let timestamp: Date?
        if let tsText = obj["timestamp"] as? String {
            timestamp = ISO8601DateFormatter().date(from: tsText)
        } else {
            timestamp = nil
        }

        guard let ts = timestamp, ts <= now else {
            return LineTokens(fiveHour: 0, sevenDay: 0, timestamp: timestamp)
        }

        let input = (usage["input_tokens"] as? Int) ?? 0
        let output = (usage["output_tokens"] as? Int) ?? 0
        let total = max(0, input) + max(0, output)

        guard total > 0 else {
            return LineTokens(fiveHour: 0, sevenDay: 0, timestamp: ts)
        }

        let fiveHour = ts >= fiveHoursAgo ? total : 0
        let sevenDay = ts >= sevenDaysAgo ? total : 0

        return LineTokens(
            fiveHour: fiveHour,
            sevenDay: sevenDay,
            timestamp: ts
        )
    }
}

extension Data {
    func containsAscii(_ substring: String) -> Bool {
        guard let pattern = substring.data(using: .ascii) else { return false }
        return range(of: pattern) != nil
    }
}
