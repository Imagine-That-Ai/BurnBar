import Foundation

/// Multi-source Claude quota adapter. Tries the cheapest, most current
/// data first and falls back gracefully while respecting the user's
/// credential boundary.
///
/// ## Collection cascade (May 2026)
///
/// 1. **Statusline bridge snapshot** — written by Claude's CLI on every
///    turn. Most current data when present; only works after the user
///    runs `claude` with the bridge installed.
/// 2. **Explicit OAuth `/api/oauth/usage`** — used only when a caller
///    injects Claude OAuth credentials. The production default reader
///    returns `nil`, so OpenBurnBar never reads Claude Code's Keychain
///    item or credentials file and cannot trigger a Keychain prompt.
/// 3. **JSONL token counting + plan cap** — sums real assistant-turn
///    tokens from `~/.claude/projects/**/*.jsonl`. If explicit OAuth
///    credentials were injected by tests/self-hosted integrations, their
///    plan tier can annotate JSONL buckets with plan caps.
/// 4. **Plan-only snapshot** — only for explicitly injected credentials.
struct ClaudeQuotaAdapter: ProviderQuotaAdapter {
    private enum ScannerPolicy {
        static let maxLineBytes = 2 * 1024 * 1024
    }

    /// Anthropic's published 5-hour / 7-day token allowances per plan
    /// tier as of May 2026 (post claude-code-warp doubling). Used to
    /// turn raw JSONL token counts into `usedPercent` values when the
    /// OAuth endpoint is unreachable.
    ///
    /// Source: https://support.claude.com/en/articles/11145838 +
    /// claudefa.st blog post "Claude Code Limits Doubled" (2026-05-10).
    private struct ClaudePlanCaps {
        let fiveHourTokens: Double
        let sevenDayTokens: Double
        static let pro = ClaudePlanCaps(fiveHourTokens: 220_000, sevenDayTokens: 880_000)
        // Max-5x baseline. Max-20x scales linearly via `rateLimitTier`.
        static let max5x = ClaudePlanCaps(fiveHourTokens: 880_000, sevenDayTokens: 7_700_000)
        static let max20x = ClaudePlanCaps(fiveHourTokens: 3_520_000, sevenDayTokens: 30_800_000)
    }

    private struct JSONLTokenWindows {
        let fiveHourTokens: Int
        let sevenDayTokens: Int
        let latestTimestamp: Date?
        let filesScanned: Int
    }

    func fetch(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot {
        let usesScopedConfig = Self.hasScopedClaudeConfig(environment: context.environment)
        let bridgeStatus = context.refreshClaudeBridgeStatus()

        // Auto-install the statusline bridge on the first refresh that
        // sees Claude Code present but no bridge configured. Silent —
        // no UI prompts. If installation fails (permissions, etc.) we
        // fall through to OAuth / JSONL paths so the user still gets
        // a usable snapshot.
        if !usesScopedConfig, shouldAutoInstallBridge(for: bridgeStatus, context: context) {
            // Record the attempt BEFORE installing so a thrown error
            // doesn't leave us in a retry loop. Worst case the user
            // can manually install via Settings.
            recordAutoInstallAttempt(in: context)
            try? context.bridgeManager.installClaudeQuotaBridge()
        }

        // Re-read bridge status after potential auto-install so the
        // status line below reflects reality.
        let postInstallStatus = bridgeStatus.state == .notInstalled
            ? context.refreshClaudeBridgeStatus()
            : bridgeStatus

        // 1. Statusline bridge — most current when the CLI has fired
        //    at least once. Returns immediately if a fresh payload is
        //    available.
        if !usesScopedConfig,
           postInstallStatus.state == .ready,
           let payload = try? context.snapshotStore.readJSONObject(from: context.appPaths.claudeStatuslineSnapshotURL),
           let rateLimitsDict = payload["rate_limits"] as? [String: Any] {
            let rateLimits = ClaudeRateLimits(from: rateLimitsDict)
            let buckets = claudeQuotaBuckets(from: rateLimits)
            if !buckets.isEmpty {
                let credentials = context.claudeCredentialsReader.load()
                let planSuffix = credentials.map { " · Plan: \($0.planDisplayName)" } ?? ""
                let statusMessage: String
                if claudeAPIBillingOverrideDetected(environment: context.environment) {
                    statusMessage = "Quota captured from Claude Code's local status line JSON bridge while API billing is also configured for this app process.\(planSuffix)"
                } else {
                    statusMessage = "Quota captured from Claude Code's local status line JSON bridge.\(planSuffix)"
                }
                return ProviderQuotaSnapshot(
                    provider: .claudeCode,
                    fetchedAt: postInstallStatus.lastPayloadAt ?? Date(),
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

        // 2. Explicit OAuth `/api/oauth/usage`. Production injects
        //    `NoClaudeCredentialsReader`, so this never reads Claude
        //    Code's third-party Keychain item or credentials file. That
        //    keeps refresh prompt-free and avoids surprise credential
        //    access.
        let workingCredentials = context.claudeCredentialsReader.load()
        if let credentials = workingCredentials, credentials.canCallUsageEndpoint(now: Date()) {
            let fetcher = ClaudeOAuthUsageFetcher(
                session: context.session,
                cacheURL: context.appPaths.claudeOAuthUsageCacheURL,
                fileManager: context.fileManager
            )
            let result = await fetcher.fetchRateLimits(
                credentials: credentials
            )
            if let rateLimits = result.rateLimits, !rateLimits.isEmpty {
                let buckets = claudeQuotaBuckets(from: rateLimits)
                if !buckets.isEmpty {
                    let freshness = result.sourceWasCache ? " (cached)" : ""
                    // Reflect refreshed plan info when the token was
                    // refreshed mid-call (rare, but the new pair may
                    // ship updated subscriptionType claims).
                    let plan = result.refreshedCredentials?.planDisplayName ?? credentials.planDisplayName
                    return ProviderQuotaSnapshot(
                        provider: .claudeCode,
                        fetchedAt: result.fetchedAt ?? Date(),
                        source: .officialAPI,
                        confidence: .exact,
                        managementURL: "https://claude.ai/settings/usage",
                        statusMessage: "Claude \(plan) quota from Anthropic OAuth usage endpoint\(freshness).",
                        buckets: buckets
                    )
                }
            }
        }

        // 3. JSONL-based token counting from local Claude project
        //    files. Real per-message tokens from
        //    `~/.claude/projects/**/*.jsonl`. When an explicit
        //    credential injection knows the plan tier, annotate the
        //    buckets with the published cap.
        let jsonlWindows = (try? Self.scanJSONLTokenWindows(
            homeDirectoryURL: context.homeDirectoryURL,
            fileManager: context.fileManager,
            environment: context.environment
        )) ?? JSONLTokenWindows(fiveHourTokens: 0, sevenDayTokens: 0, latestTimestamp: nil, filesScanned: 0)

        if jsonlWindows.fiveHourTokens > 0 || jsonlWindows.sevenDayTokens > 0 {
            return makeJSONLSnapshot(
                jsonlWindows: jsonlWindows,
                credentials: workingCredentials,
                bridgeStatus: postInstallStatus
            )
        }

        // 4. Plan-only snapshot for explicit credentials. This is not
        //    reached in production default mode because OpenBurnBar no
        //    longer discovers Claude credentials on its own.
        if let credentials = workingCredentials {
            let badgeBucket = ProviderQuotaBucket(
                key: "claude-plan-badge",
                label: "Plan: \(credentials.planDisplayName)",
                windowKind: .lifetime,
                usedValue: nil,
                limitValue: nil,
                remainingValue: nil,
                usedPercent: nil,
                resetsAt: nil,
                unit: .count,
                isEstimated: false
            )
            return ProviderQuotaSnapshot(
                provider: .claudeCode,
                fetchedAt: Date(),
                source: .localCLI,
                confidence: .estimated,
                managementURL: "https://claude.ai/settings/usage",
                statusMessage: "Claude \(credentials.planDisplayName) detected from explicitly supplied credentials. Run any Claude Code prompt to capture local rate-limit percentages.",
                buckets: [badgeBucket]
            )
        }

        // No bridge, no OAuth credentials, no JSONL — return unavailable.
        let fallbackMessage: String
        switch postInstallStatus.state {
        case .notInstalled, .invalidConfiguration:
            fallbackMessage = "Sign in to Claude Code or install the OpenBurnBar bridge to capture quota."
        case .disabledByHooks:
            fallbackMessage = postInstallStatus.detailText
        case .awaitingFirstPayload:
            fallbackMessage = "Bridge installed but no payload yet. Send any Claude Code prompt to capture local rate limits."
        case .ready:
            fallbackMessage = "Bridge installed but no rate-limit payload captured yet."
        }

        if jsonlWindows.filesScanned > 0 {
            return unavailableSnapshot(
                for: .claudeCode,
                source: .localSession,
                message: "\(jsonlWindows.filesScanned) JSONL file(s) scanned but no recent token activity found. Run any Claude Code prompt to refresh local usage data."
            )
        }

        return unavailableSnapshot(for: .claudeCode, source: .localCLI, message: fallbackMessage)
    }

    // MARK: - Auto-Install

    /// Returns true when the bridge is not installed AND Claude Code is
    /// clearly present (settings.json or projects dir exists) AND we
    /// haven't already tried to install it during this app lifetime.
    /// Silent auto-install removes the most common "Connect Claude"
    /// friction without ever prompting the user.
    ///
    /// The attempted-install marker prevents retry loops: if the
    /// install fails (e.g. settings.json is read-only or symlinked
    /// into a non-writable Time Machine snapshot), we don't keep
    /// hammering it on every refresh tick. The user can re-run the
    /// install manually via Settings.
    private func shouldAutoInstallBridge(
        for status: ClaudeQuotaBridgeStatus,
        context: ProviderQuotaAdapterContext
    ) -> Bool {
        guard status.state == .notInstalled else { return false }
        let fm = context.fileManager
        let home = context.homeDirectoryURL
        let claudeDir = home.appendingPathComponent(".claude", isDirectory: true)
        let settingsURL = claudeDir.appendingPathComponent("settings.json")
        let projectsURL = claudeDir.appendingPathComponent("projects", isDirectory: true)
        let claudePresent = fm.fileExists(atPath: settingsURL.path)
            || fm.fileExists(atPath: projectsURL.path)
        guard claudePresent else { return false }
        return !autoInstallAttemptMarkerExists(in: context)
    }

    private func autoInstallAttemptMarkerExists(in context: ProviderQuotaAdapterContext) -> Bool {
        context.fileManager.fileExists(atPath: autoInstallAttemptMarkerURL(in: context).path)
    }

    private func recordAutoInstallAttempt(in context: ProviderQuotaAdapterContext) {
        let url = autoInstallAttemptMarkerURL(in: context)
        let parent = url.deletingLastPathComponent()
        try? context.fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let envelope: [String: String] = [
            "attemptedAt": ISO8601DateFormatter().string(from: Date())
        ]
        if let data = try? JSONSerialization.data(withJSONObject: envelope) {
            try? data.write(to: url, options: [.atomic])
        }
    }

    private func autoInstallAttemptMarkerURL(in context: ProviderQuotaAdapterContext) -> URL {
        context.appPaths.claudeStatuslineSnapshotURL
            .deletingLastPathComponent()
            .appendingPathComponent("claude-bridge-auto-install-attempted.json")
    }

    // MARK: - JSONL → Plan-Capped Snapshot

    private func makeJSONLSnapshot(
        jsonlWindows: JSONLTokenWindows,
        credentials: ClaudeOAuthCredentials?,
        bridgeStatus: ClaudeQuotaBridgeStatus
    ) -> ProviderQuotaSnapshot {
        let now = Date()
        let calendar = Calendar.current
        let caps = inferredCaps(from: credentials)

        var buckets: [ProviderQuotaBucket] = []
        if jsonlWindows.fiveHourTokens > 0 {
            buckets.append(jsonlBucket(
                key: "claude-five-hour-jsonl",
                label: "5-hour window",
                windowKind: .rollingHours,
                used: jsonlWindows.fiveHourTokens,
                cap: caps?.fiveHourTokens,
                resetsAt: calendar.date(byAdding: .hour, value: 5, to: now)
            ))
        }
        if jsonlWindows.sevenDayTokens > 0 {
            buckets.append(jsonlBucket(
                key: "claude-seven-day-jsonl",
                label: "7-day window",
                windowKind: .rollingDays,
                used: jsonlWindows.sevenDayTokens,
                cap: caps?.sevenDayTokens,
                resetsAt: calendar.date(byAdding: .day, value: 7, to: now)
            ))
        }

        let confidence: ProviderQuotaConfidence = caps != nil ? .estimated : .exact
        let planSuffix = credentials.map { " · Plan: \($0.planDisplayName) (inferred caps)" } ?? ""
        let bridgeNudge = bridgeStatus.state == .ready
            ? ""
            : " Install OpenBurnBar's status line bridge for exact percentages."
        let message = "Token counts from \(jsonlWindows.filesScanned) local Claude project file(s).\(planSuffix)\(bridgeNudge)"

        return ProviderQuotaSnapshot(
            provider: .claudeCode,
            fetchedAt: jsonlWindows.latestTimestamp ?? Date(),
            source: .localSession,
            confidence: confidence,
            managementURL: "https://claude.ai/settings/usage",
            statusMessage: message,
            buckets: buckets
        )
    }

    private func jsonlBucket(
        key: String,
        label: String,
        windowKind: ProviderQuotaWindowKind,
        used: Int,
        cap: Double?,
        resetsAt: Date?
    ) -> ProviderQuotaBucket {
        let usedValue = Double(used)
        let usedPercent: Double? = cap.map { c in min(max(usedValue / c * 100, 0), 100) }
        let remaining: Double? = cap.map { max($0 - usedValue, 0) }
        return ProviderQuotaBucket(
            key: key,
            label: label,
            windowKind: windowKind,
            usedValue: usedValue,
            limitValue: cap,
            remainingValue: remaining,
            usedPercent: usedPercent,
            resetsAt: resetsAt,
            unit: .tokens,
            isEstimated: cap != nil
        )
    }

    /// Best-effort plan cap inference. Explicit OAuth payloads can carry
    /// `rateLimitTier` values (`default_claude_max_20x`,
    /// `default_claude_pro_5x`, etc.) that identify the multiplier; we
    /// map them to the Anthropic-published allowance. Returns `nil` when
    /// we can't recognize the tier — in that case the JSONL buckets
    /// render token counts only (still useful, just without percentages).
    private func inferredCaps(from credentials: ClaudeOAuthCredentials?) -> ClaudePlanCaps? {
        guard let credentials else { return nil }
        let tier = credentials.rateLimitTier.lowercased()
        let sub = credentials.subscriptionType.lowercased()
        let combined = tier + " " + sub
        if combined.contains("20x") || combined.contains("max_20") {
            return .max20x
        }
        if combined.contains("max") {
            return .max5x
        }
        if combined.contains("pro") {
            return .pro
        }
        return nil
    }

    // MARK: - File Discovery

    private static func scanJSONLTokenWindows(
        homeDirectoryURL: URL,
        fileManager: FileManager,
        environment: [String: String],
        now: Date = Date()
    ) throws -> JSONLTokenWindows {
        let calendar = Calendar.current
        let fiveHoursAgo = calendar.date(byAdding: .hour, value: -5, to: now) ?? now
        let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        let files = findJSONLFiles(
            in: claudeProjectDirectories(homeDirectoryURL: homeDirectoryURL, environment: environment),
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

    private static func claudeProjectDirectories(
        homeDirectoryURL: URL,
        environment: [String: String]
    ) -> [URL] {
        let scopedDirectories = scopedClaudeProjectDirectories(environment: environment)
        if !scopedDirectories.isEmpty {
            return scopedDirectories
        }

        var dirs: [URL] = []
        dirs.append(homeDirectoryURL.appendingPathComponent(".config/claude/projects", isDirectory: true))
        dirs.append(homeDirectoryURL.appendingPathComponent(".claude/projects", isDirectory: true))

        return dirs
    }

    private static func hasScopedClaudeConfig(environment: [String: String]) -> Bool {
        !scopedClaudeProjectDirectories(environment: environment).isEmpty
    }

    private static func scopedClaudeProjectDirectories(environment: [String: String]) -> [URL] {
        let rawValues = [
            environment["CLAUDE_CONFIG_DIR"],
            environment["CLAUDE_CONFIG_PATH"]
        ]

        var directories: [URL] = []
        var seen = Set<String>()
        for value in rawValues {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else {
                continue
            }

            for part in value.split(separator: ",") {
                let raw = String(part).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !raw.isEmpty else { continue }
                var url = URL(fileURLWithPath: raw)
                if url.pathExtension.lowercased() == "json" {
                    url.deleteLastPathComponent()
                }
                let projectURL = url.lastPathComponent == "projects"
                    ? url
                    : url.appendingPathComponent("projects", isDirectory: true)
                let path = projectURL.standardizedFileURL.path
                guard seen.insert(path).inserted else { continue }
                directories.append(projectURL)
            }
        }
        return directories
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

    /// Anthropic-published window keys for Claude Code. Names map to
    /// human labels and `ProviderQuotaWindowKind`. Adding a new label
    /// is a one-line change.
    private static let claudeWindowCandidates: [(key: String, label: String, kind: ProviderQuotaWindowKind)] = [
        ("five_hour", "5-hour window", .rollingHours),
        ("seven_day", "7-day window", .rollingDays),
        ("seven_day_sonnet", "7-day Sonnet window", .rollingDays),
        ("seven_day_opus", "7-day Opus window", .rollingDays),
        ("seven_day_oauth_apps", "7-day OAuth Apps window", .rollingDays),
    ]

    private func claudeQuotaBuckets(from rateLimits: ClaudeRateLimits) -> [ProviderQuotaBucket] {
        Self.claudeWindowCandidates.compactMap { key, label, windowKind in
            guard let window = rateLimits.window(named: key) else { return nil }
            guard window.usedPercentage != nil || window.remainingPercentage != nil else {
                return nil
            }
            return ProviderQuotaBucket(
                key: "claude-\(FlexibleQuotaBucketNormalizer.sanitizeKey(key))",
                label: label,
                windowKind: windowKind,
                usedValue: window.usedPercentage,
                limitValue: 100,
                remainingValue: window.remainingPercentage,
                usedPercent: window.usedPercentage,
                resetsAt: window.resetsAt,
                unit: .percent,
                isEstimated: false
            )
        }
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
