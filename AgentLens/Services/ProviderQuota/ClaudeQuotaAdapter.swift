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
///    injects Claude OAuth credentials from tests, route credential slots, or
///    intentionally configured CLI profiles. The provider-level production
///    default reader returns `nil`, so OpenBurnBar never reads Claude Code's
///    global Keychain item and cannot trigger a Keychain prompt.
/// 3. **JSONL token counting + plan cap** — sums real assistant-turn
///    tokens from `~/.claude/projects/**/*.jsonl`. If explicit OAuth
///    credentials were injected by tests, route credential slots, or CLI
///    profiles, their plan tier can annotate JSONL buckets with plan caps.
/// 4. **Plan-only snapshot** — only for explicitly injected credentials.
struct ClaudeQuotaAdapter: ProviderQuotaAdapter {
    private enum ScannerPolicy {
        static let maxLineBytes = 2 * 1024 * 1024
    }

    private enum StatuslinePolicy {
        /// Claude's status line payload is a live hook emission, not an
        /// authoritative long-lived cache. The 5h window moves even when
        /// OpenBurnBar is the only thing refreshing, so old hook output must
        /// not pin quota UI to stale percentages.
        static let maxSnapshotAge: TimeInterval = 15 * 60

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

    /// Token totals across the rolling Claude windows. Internal (not private)
    /// so `ClaudeQuotaJSONLScannerTests` can assert on the scan output.
    struct JSONLTokenWindows {
        let fiveHourTokens: Int
        let sevenDayTokens: Int
        let latestTimestamp: Date?
        let filesScanned: Int
    }

    // MARK: - JSONL Scan Cache & Timestamp Parsing

    /// Shared, reused ISO8601 parsers. Claude writes turn timestamps with
    /// fractional seconds (e.g. `2026-05-27T08:00:53.077Z`), which the
    /// *default* `ISO8601DateFormatter` rejects. The previous per-line
    /// `ISO8601DateFormatter().date(from:)` therefore both (a) allocated an
    /// ICU-backed formatter for every assistant line — pure CPU burn that
    /// showed up as the hottest non-idle frame under load — and (b) returned
    /// `nil`, silently zeroing every JSONL token count. Reusing two configured
    /// formatters fixes the correctness bug and removes the allocation.
    private enum JSONLTimestamp {
        static let fractional: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }()
        static let plain: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return formatter
        }()
        static func date(from text: String) -> Date? {
            fractional.date(from: text) ?? plain.date(from: text)
        }
    }

    /// Per-file invalidation key: a transcript is unchanged iff both its
    /// modification time and byte size are unchanged. Mirrors
    /// `CodexRolloutFileSignature`.
    private struct JSONLFileSignature: Equatable {
        let modifiedAt: TimeInterval
        let sizeBytes: Int64
    }

    /// Boundary-independent contribution of a single assistant turn: its
    /// timestamp and token total. Window membership (5-hour / 7-day) is applied
    /// at aggregation time, so cached contributions stay valid as the rolling
    /// windows slide.
    private struct JSONLContribution {
        let timestamp: Date
        let total: Int
    }

    /// Process-lifetime, thread-safe cache of parsed per-file contributions.
    ///
    /// The Claude statusline watcher re-runs this scan on *every* hook write
    /// (constantly during an active Claude session), and the provider, account,
    /// and switcher-profile scopes each scan concurrently. Without a cache,
    /// every run re-reads and re-JSON-parses every in-window transcript on every
    /// core. With it, only the file Claude actually appended to is re-read;
    /// everything else is an O(lines) re-sum of cached numbers.
    ///
    /// Unlike `CodexRolloutScanCache` this is in-memory only (no disk
    /// persistence plumbed through `ProviderQuotaAdapterContext`): the
    /// modification-time window cutoff already keeps a cold first scan cheap, so
    /// the persisted variant's complexity isn't warranted here.
    private final class JSONLScanCache: @unchecked Sendable {
        private struct Entry {
            let signature: JSONLFileSignature
            let contributions: [JSONLContribution]
        }
        private let lock = NSLock()
        private var entries: [String: Entry] = [:]

        func contributions(forPath path: String, signature: JSONLFileSignature) -> [JSONLContribution]? {
            lock.lock(); defer { lock.unlock() }
            guard let entry = entries[path], entry.signature == signature else { return nil }
            return entry.contributions
        }

        func store(path: String, signature: JSONLFileSignature, contributions: [JSONLContribution]) {
            lock.lock(); defer { lock.unlock() }
            entries[path] = Entry(signature: signature, contributions: contributions)
        }

        /// Drop entries for transcripts that fell out of the widest rolling
        /// window. Pruning by absolute modification time (not by one scope's
        /// file set) keeps it safe when scopes scan concurrently: every scope
        /// derives the cutoff from the same `now`, so none evicts another
        /// scope's still-relevant entries.
        func pruneEntries(olderThan cutoffEpoch: TimeInterval) {
            lock.lock(); defer { lock.unlock() }
            entries = entries.filter { $0.value.signature.modifiedAt >= cutoffEpoch }
        }
    }

    private static let scanCache = JSONLScanCache()

    func fetch(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot {
        let usesScopedConfig = Self.hasScopedClaudeConfig(environment: context.environment)
        let routeCredentialScope = Self.hasRouteCredentialScope(environment: context.environment)
        let switcherProfileScope = Self.hasSwitcherProfileScope(environment: context.environment)
        let accountScopedQuota = routeCredentialScope || switcherProfileScope
        let canUseLocalClaudeSessionForAccount = switcherProfileScope
            && Self.scopedClaudeProfileMatchesDefaultLogin(context: context)
        let workingCredentials = context.claudeCredentialsReader.load()
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

        // Explicit Claude credentials belong to a specific configured
        // account. They must be queried before the global local statusline
        // bridge, otherwise one shared Claude hook payload can overwrite every
        // account card with the same stale percentage.
        if let credentials = workingCredentials, credentials.canCallUsageEndpoint(now: Date()) {
            let fetcher = ClaudeOAuthUsageFetcher(
                session: context.session,
                cacheURL: ClaudeOAuthUsageFetcher.scopedCacheURL(
                    baseURL: context.appPaths.claudeOAuthUsageCacheURL,
                    credentials: credentials
                ),
                fileManager: context.fileManager
            )
            let result = await fetcher.fetchRateLimits(
                credentials: credentials
            )
            if let rateLimits = result.rateLimits, !rateLimits.isEmpty {
                let buckets = claudeQuotaBuckets(from: rateLimits)
                if !buckets.isEmpty {
                    let freshness = result.sourceWasCache ? " (cached)" : ""
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

        // 1. Statusline bridge — most current when the CLI has fired
        //    at least once. Returns immediately if a fresh payload is
        //    available.
        if (workingCredentials == nil || canUseLocalClaudeSessionForAccount),
           (!accountScopedQuota || canUseLocalClaudeSessionForAccount),
           (!usesScopedConfig || canUseLocalClaudeSessionForAccount),
           postInstallStatus.state == .ready,
           Self.isFreshStatuslineSnapshot(postInstallStatus.lastPayloadAt),
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

        if workingCredentials == nil,
           !accountScopedQuota,
           claudeAPIBillingOverrideDetected(environment: context.environment) {
            if let staleSnapshot = staleStatuslineSnapshotIfAvailable(
                status: postInstallStatus,
                context: context,
                messagePrefix: "Stale last known Claude Code quota from the local status line JSON bridge. ANTHROPIC_API_KEY is set for this app process, so API billing may be active and OpenBurnBar cannot refresh Claude plan quota until Claude Code emits a fresh status line payload."
            ) {
                return staleSnapshot
            }

            return unavailableSnapshot(
                for: .claudeCode,
                source: .unavailable,
                message: "ANTHROPIC_API_KEY is set for this app process. Claude Code may be using API billing instead of a Claude plan, so OpenBurnBar will only report exact local CLI quota snapshots. Run a Claude Code CLI prompt to emit a fresh status line quota payload."
            )
        }

        // 2. Explicit OAuth `/api/oauth/usage`. Provider-level production
        //    injects `NoClaudeCredentialsReader`, while account/profile paths
        //    inject only credentials that were already configured for that
        //    exact account scope.
        // This path is handled before the statusline bridge so explicit
        // account snapshots cannot inherit another account's local hook data.

        // 3. JSONL-based token counting from local Claude project
        //    files. Real per-message tokens from
        //    `~/.claude/projects/**/*.jsonl`. When an explicit
        //    credential injection knows the plan tier, annotate the
        //    buckets with the published cap.
        if routeCredentialScope, workingCredentials != nil {
            return unavailableSnapshot(
                for: .claudeCode,
                source: .officialAPI,
                message: "No current Claude quota returned for this account's stored credential. OpenBurnBar will not reuse another Claude account's statusline, JSONL, or cache data."
            )
        }

        let jsonlWindows = (try? Self.scanJSONLTokenWindows(
            homeDirectoryURL: context.homeDirectoryURL,
            fileManager: context.fileManager,
            environment: context.environment
        )) ?? JSONLTokenWindows(fiveHourTokens: 0, sevenDayTokens: 0, latestTimestamp: nil, filesScanned: 0)

        if jsonlWindows.fiveHourTokens > 0 || jsonlWindows.sevenDayTokens > 0 {
            return makeJSONLSnapshot(jsonlWindows: jsonlWindows, credentials: workingCredentials, bridgeStatus: postInstallStatus)
        }

        if workingCredentials == nil,
           !accountScopedQuota,
           !usesScopedConfig,
           let staleSnapshot = staleStatuslineSnapshotIfAvailable(
            status: postInstallStatus,
            context: context,
            messagePrefix: "Stale last known Claude Code quota from the local status line JSON bridge. Refresh did not find a newer OAuth or local-session quota signal."
        ) {
            return staleSnapshot
        }

        // 4. Explicit credentials without current quota buckets. Do not render
        //    plan/account metadata as a quota bucket: a Max/Pro plan badge is
        //    not a lifetime allowance, and a context window is not a Claude
        //    subscription quota. Leave the card bucketless until Claude returns
        //    real rate-limit windows for this exact account.
        if let credentials = workingCredentials {
            if routeCredentialScope {
                return unavailableSnapshot(
                    for: .claudeCode,
                    source: .officialAPI,
                    message: "No current Claude quota returned for this account's stored credential. OpenBurnBar will not reuse another Claude account's statusline or cache data."
                )
            }
            return unavailableSnapshot(
                for: .claudeCode,
                source: .officialAPI,
                message: switcherProfileScope
                    ? "Claude \(credentials.planDisplayName) credential is signed in for this profile, but Anthropic did not return current quota buckets for it. OpenBurnBar will not reuse another Claude account's statusline, context window, or cache data."
                    : "Claude \(credentials.planDisplayName) credential is available, but Anthropic did not return current quota buckets. OpenBurnBar will not display plan metadata as quota."
            )
        }

        if accountScopedQuota {
            return unavailableSnapshot(
                for: .claudeCode,
                source: .unavailable,
                message: "No current Claude quota signal is available for this account. OpenBurnBar will not reuse another Claude account's statusline or cache data."
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

    private static func isFreshStatuslineSnapshot(
        _ lastPayloadAt: Date?,
        now: Date = Date()
    ) -> Bool {
        guard let lastPayloadAt else { return false }
        return now.timeIntervalSince(lastPayloadAt) <= StatuslinePolicy.maxSnapshotAge
    }

    private func staleStatuslineSnapshotIfAvailable(
        status: ClaudeQuotaBridgeStatus,
        context: ProviderQuotaAdapterContext,
        messagePrefix: String,
        now: Date = Date()
    ) -> ProviderQuotaSnapshot? {
        guard status.state == .ready,
              let lastPayloadAt = status.lastPayloadAt,
              !Self.isFreshStatuslineSnapshot(lastPayloadAt),
              let payload = try? context.snapshotStore.readJSONObject(from: context.appPaths.claudeStatuslineSnapshotURL),
              let rateLimitsDict = payload["rate_limits"] as? [String: Any] else {
            return nil
        }

        let buckets = claudeQuotaBuckets(from: ClaudeRateLimits(from: rateLimitsDict))
        guard !buckets.isEmpty else { return nil }

        let formatted = lastPayloadAt.formatted(date: .abbreviated, time: .shortened)
        return ProviderQuotaSnapshot(
            provider: .claudeCode,
            fetchedAt: lastPayloadAt,
            source: .localCLI,
            confidence: .estimated,
            managementURL: "https://code.claude.com/docs/en/statusline",
            statusMessage: "\(messagePrefix) Last payload: \(formatted).",
            buckets: buckets.map(Self.markBucketEstimated)
        )
    }

    private static func markBucketEstimated(_ bucket: ProviderQuotaBucket) -> ProviderQuotaBucket {
        ProviderQuotaBucket(
            key: bucket.key,
            label: bucket.label,
            windowKind: bucket.windowKind,
            usedValue: bucket.usedValue,
            limitValue: bucket.limitValue,
            remainingValue: bucket.remainingValue,
            usedPercent: bucket.usedPercent,
            resetsAt: bucket.resetsAt,
            unit: bucket.unit,
            isEstimated: true
        )
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

    /// Sum real assistant-turn token usage across the rolling 5-hour and
    /// 7-day windows from local Claude transcripts. Internal (not private) so
    /// `ClaudeQuotaJSONLScannerTests` can drive it against a temp directory.
    static func scanJSONLTokenWindows(
        homeDirectoryURL: URL,
        fileManager: FileManager,
        environment: [String: String],
        now: Date = Date()
    ) throws -> JSONLTokenWindows {
        let calendar = Calendar.current
        let fiveHoursAgo = calendar.date(byAdding: .hour, value: -5, to: now) ?? now
        let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: now) ?? now

        // A transcript's modification time is an upper bound on the timestamp of
        // any line it holds: Claude appends each turn the moment it is produced.
        // A file last written before the 7-day window opened therefore cannot
        // contribute to either the 5-hour or 7-day window, so it is skipped
        // without ever being opened. This is the single biggest win — stale
        // transcripts accumulate indefinitely (hundreds of MB) while only the
        // last week's files can ever matter.
        let windowCutoffEpoch = sevenDaysAgo.timeIntervalSince1970

        let files = findRecentJSONLFiles(
            in: claudeProjectDirectories(homeDirectoryURL: homeDirectoryURL, environment: environment),
            fileManager: fileManager,
            modifiedAtOrAfterEpoch: windowCutoffEpoch
        )

        var fiveHourTokens = 0
        var sevenDayTokens = 0
        var latestTimestamp: Date?
        var filesScanned = 0

        for (file, signature) in files {
            let path = file.standardizedFileURL.path
            let contributions: [JSONLContribution]
            if let cached = scanCache.contributions(forPath: path, signature: signature) {
                contributions = cached
            } else {
                guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
                defer { try? handle.close() }
                contributions = parseFileContributions(from: handle, now: now)
                scanCache.store(path: path, signature: signature, contributions: contributions)
            }

            filesScanned += 1
            for contribution in contributions {
                if contribution.total > 0 {
                    if contribution.timestamp >= fiveHoursAgo { fiveHourTokens += contribution.total }
                    if contribution.timestamp >= sevenDaysAgo { sevenDayTokens += contribution.total }
                }
                latestTimestamp = max(contribution.timestamp, latestTimestamp ?? .distantPast)
            }
        }

        scanCache.pruneEntries(olderThan: windowCutoffEpoch)

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
        quotaNonEmpty(environment["CLAUDE_CONFIG_DIR"]) != nil
            || quotaNonEmpty(environment["CLAUDE_CONFIG_PATH"]) != nil
    }

    private static func hasRouteCredentialScope(environment: [String: String]) -> Bool {
        quotaNonEmpty(environment["OPENBURNBAR_QUOTA_ACCOUNT_ID"]) != nil
    }

    private static func hasSwitcherProfileScope(environment: [String: String]) -> Bool {
        quotaNonEmpty(environment["OPENBURNBAR_QUOTA_SWITCHER_PROFILE_ID"]) != nil
    }

    /// A switcher profile may represent the same account as the default local
    /// Claude Code login. In that case the global statusline hook is not
    /// cross-account leakage; it is the account's live signal.
    private static func scopedClaudeProfileMatchesDefaultLogin(
        context: ProviderQuotaAdapterContext
    ) -> Bool {
        guard let profileDirectory = quotaNonEmpty(context.environment["CLAUDE_CONFIG_DIR"]) else {
            return false
        }

        let profileStateURL = URL(fileURLWithPath: profileDirectory, isDirectory: true)
            .appendingPathComponent(".claude.json", isDirectory: false)
        let defaultStateURL = context.homeDirectoryURL
            .appendingPathComponent(".claude.json", isDirectory: false)

        guard let profileState = try? context.snapshotStore.readJSONObject(from: profileStateURL),
              let defaultState = try? context.snapshotStore.readJSONObject(from: defaultStateURL) else {
            return false
        }

        let profileIdentity = claudeAccountIdentity(from: profileState)
        let defaultIdentity = claudeAccountIdentity(from: defaultState)
        guard !profileIdentity.isEmpty, !defaultIdentity.isEmpty else { return false }
        return !profileIdentity.isDisjoint(with: defaultIdentity)
    }

    private static func claudeAccountIdentity(from state: [String: Any]) -> Set<String> {
        guard let account = state["oauthAccount"] as? [String: Any] else { return [] }
        let candidates = [
            account["accountUuid"] as? String,
            account["emailAddress"] as? String,
            account["organizationUuid"] as? String,
        ]
        return Set(candidates.compactMap { value in
            quotaNonEmpty(value)?.lowercased()
        })
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

    /// Enumerate `*.jsonl` transcripts modified at or after `cutoffEpoch`,
    /// returning each with its `(modifiedAt, sizeBytes)` signature for cache
    /// invalidation. Files older than the cutoff are dropped here so they are
    /// never opened or read — see `scanJSONLTokenWindows`.
    private static func findRecentJSONLFiles(
        in directories: [URL],
        fileManager: FileManager,
        modifiedAtOrAfterEpoch cutoffEpoch: TimeInterval
    ) -> [(url: URL, signature: JSONLFileSignature)] {
        var files: [(url: URL, signature: JSONLFileSignature)] = []
        var seen = Set<String>()

        for directory in directories {
            guard fileManager.fileExists(atPath: directory.path) else { continue }
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            while let fileURL = enumerator.nextObject() as? URL {
                guard fileURL.pathExtension.lowercased() == "jsonl" else { continue }
                let path = fileURL.standardizedFileURL.path
                guard seen.insert(path).inserted else { continue }

                guard let values = try? fileURL.resourceValues(
                    forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
                ),
                    values.isRegularFile == true,
                    let modified = values.contentModificationDate else { continue }

                let modifiedEpoch = modified.timeIntervalSince1970
                guard modifiedEpoch >= cutoffEpoch else { continue }

                files.append((
                    fileURL,
                    JSONLFileSignature(
                        modifiedAt: modifiedEpoch,
                        sizeBytes: Int64(values.fileSize ?? 0)
                    )
                ))
            }
        }

        return files
    }

    // MARK: - Parsing

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

    /// Stream a transcript line by line, returning the boundary-independent
    /// `(timestamp, total)` contribution of every assistant turn. The result is
    /// what the per-file cache stores; rolling-window summation happens in
    /// `scanJSONLTokenWindows` so cached values survive window movement.
    private static func parseFileContributions(
        from handle: FileHandle,
        now: Date
    ) -> [JSONLContribution] {
        try? handle.seek(toOffset: 0)

        var contributions: [JSONLContribution] = []
        var currentLine = Data()
        currentLine.reserveCapacity(4 * 1024)
        var lineByteCount = 0

        func flushCurrentLine() {
            if lineByteCount > 0, lineByteCount <= ScannerPolicy.maxLineBytes,
               let contribution = parseLineContribution(currentLine, now: now) {
                contributions.append(contribution)
            }
            currentLine.removeAll(keepingCapacity: true)
            lineByteCount = 0
        }

        while true {
            guard let chunk = try? handle.read(upToCount: 256 * 1024), !chunk.isEmpty else {
                flushCurrentLine()
                break
            }

            var segmentStart = chunk.startIndex
            while let nl = chunk[segmentStart...].firstIndex(of: 0x0A) {
                currentLine.append(chunk[segmentStart..<nl])
                lineByteCount += chunk[segmentStart..<nl].count
                flushCurrentLine()
                segmentStart = chunk.index(after: nl)
            }

            if segmentStart < chunk.endIndex {
                currentLine.append(chunk[segmentStart..<chunk.endIndex])
                lineByteCount += chunk[segmentStart..<chunk.endIndex].count
            }
        }

        return contributions
    }

    private static func parseLineContribution(
        _ data: Data,
        now: Date
    ) -> JSONLContribution? {
        guard !data.isEmpty else { return nil }

        guard data.containsAscii(#""type""#),
              data.containsAscii(#""usage""#) else {
            return nil
        }

        guard data.containsAscii(#""type":"assistant""#) else {
            return nil
        }

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String,
              type == "assistant",
              let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any] else {
            return nil
        }

        guard let tsText = obj["timestamp"] as? String,
              let timestamp = JSONLTimestamp.date(from: tsText),
              timestamp <= now else {
            return nil
        }

        let input = (usage["input_tokens"] as? Int) ?? 0
        let output = (usage["output_tokens"] as? Int) ?? 0
        let total = max(0, input) + max(0, output)

        return JSONLContribution(timestamp: timestamp, total: total)
    }
}

extension Data {
    func containsAscii(_ substring: String) -> Bool {
        guard let pattern = substring.data(using: .ascii) else { return false }
        return range(of: pattern) != nil
    }
}
