import Foundation
import OpenBurnBarKernel
import OpenBurnBarLogParsers

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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
public struct ClaudeQuotaAdapter: ProviderQuotaAdapter {
    public init() {}
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

    /// Token totals across the rolling Claude windows. Public so app and
    /// package tests can assert on the scan output.
    public struct JSONLTokenWindows {
        public let fiveHourTokens: Int
        public let sevenDayTokens: Int
        public let latestTimestamp: Date?
        public let filesScanned: Int
        /// Bytes actually read from transcript handles this scan. Exact cache
        /// hits contribute 0; resume-on-growth reads only the appended tail.
        public let bytesRead: Int

        public init(
            fiveHourTokens: Int,
            sevenDayTokens: Int,
            latestTimestamp: Date?,
            filesScanned: Int,
            bytesRead: Int = 0
        ) {
            self.fiveHourTokens = fiveHourTokens
            self.sevenDayTokens = sevenDayTokens
            self.latestTimestamp = latestTimestamp
            self.filesScanned = filesScanned
            self.bytesRead = bytesRead
        }
    }

    // MARK: - JSONL Scan Cache & Timestamp Parsing

    /// JSONL turn-timestamp parsing. Claude writes turn timestamps with
    /// fractional seconds (e.g. `2026-05-27T08:00:53.077Z`), which the
    /// *default* `ISO8601DateFormatter` rejects. The original per-line
    /// `ISO8601DateFormatter().date(from:)` therefore both (a) allocated an
    /// ICU-backed formatter for every assistant line — pure CPU burn that
    /// showed up as the hottest non-idle frame under load — and (b) returned
    /// `nil`, silently zeroing every JSONL token count.
    ///
    /// Delegates to `ThreadSafeISO8601DateFormatter.parse(_:)`, which tries
    /// fractional-seconds first and falls back to the plain internet-date-time
    /// format using a lock-guarded, process-lifetime formatter pair — no
    /// per-call allocation, and safe under the concurrent scans this adapter
    /// runs (a plain `static let ISO8601DateFormatter` would not be, since
    /// `ISO8601DateFormatter` is not thread-safe).
    /// Boundary-independent contribution of a single assistant turn: its
    /// timestamp and token total. Window membership (5-hour / 7-day) is applied
    /// at aggregation time, so cached contributions stay valid as the rolling
    /// windows slide.
    private struct JSONLContribution: Codable, Equatable, Sendable {
        let timestamp: Date
        let total: Int
    }

    /// Persisted facts-only cache entry for one Claude transcript.
    ///
    /// Only timestamp and token totals are persisted. No prompt, response,
    /// message body, model text, or raw JSONL bytes enter this cache.
    private struct JSONLQuotaCacheEntry: Codable, Equatable, Sendable {
        let signature: FileSignature
        let contributions: [JSONLContribution]
        let endedAtLineBoundary: Bool
        let headPrefixLength: Int
        let headPrefixSHA256: String
    }

    private static let jsonlQuotaCacheSchemaVersion = 1
    private static let jsonlHeadDigestSpan = 64
    private static let scanSerialization = Locked(())
    private static let inMemoryScanCache = Locked(
        ParserDiskCache<JSONLQuotaCacheEntry>.empty(schemaVersion: jsonlQuotaCacheSchemaVersion)
    )
    private static let persistedScanCaches = Locked(
        [String: ParserDiskCache<JSONLQuotaCacheEntry>]()
    )

    public func fetch(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot {
        let usesScopedConfig = Self.hasScopedClaudeConfig(environment: context.environment)
        let routeCredentialScope = Self.hasRouteCredentialScope(environment: context.environment)
        let switcherProfileScope = Self.hasSwitcherProfileScope(environment: context.environment)
        let accountScopedQuota = routeCredentialScope || switcherProfileScope
        let canUseLocalClaudeSessionForAccount = switcherProfileScope
            && Self.scopedClaudeProfileMatchesDefaultLogin(context: context)
        let workingCredentials = context.claudeCredentialsReader.load()
        let bridgeStatus = context.bridgeManager.refreshClaudeBridgeStatus()

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
            try? context.bridgeManager.installClaudeQuotaBridge() // try?-ok(install best-effort, falls through)
        }

        // Re-read bridge status after potential auto-install so the
        // status line below reflects reality.
        let postInstallStatus = bridgeStatus.state == .notInstalled
            ? context.bridgeManager.refreshClaudeBridgeStatus()
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
                fileManager: context.fileManager,
                cliExecutor: context.cliExecutor,
                quotaLogger: context.quotaLogger
            )
            let result = await fetcher.fetchRateLimits(
                credentials: credentials
            )
            // Round-trip the refreshed token back to the per-profile Keychain
            // item this account reads from. The fetcher refreshes an expired
            // access token in-memory for the live usage call, but without
            // persisting it the NEXT refresh tick re-reads the now-stale token
            // and must refresh again — and once the original refresh token is
            // rotated server-side, the stale copy can no longer refresh at all,
            // silently killing a second subscription after its access token
            // expires. Writing the rotated access+refresh tokens back keeps the
            // profile self-sufficient across expiry.
            if let refreshed = result.refreshedCredentials {
                persistRefreshedProfileCredential(refreshed, context: context)
            }
            if let rateLimits = result.rateLimits, !rateLimits.isEmpty {
                let buckets = claudeQuotaBuckets(from: rateLimits, context: context)
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
        if workingCredentials == nil || canUseLocalClaudeSessionForAccount,
           !accountScopedQuota || canUseLocalClaudeSessionForAccount,
           !usesScopedConfig || canUseLocalClaudeSessionForAccount,
           postInstallStatus.state == .ready,
           Self.isFreshStatuslineSnapshot(postInstallStatus.lastPayloadAt),
           let payload = try? context.snapshotStore.readJSONObject(from: context.appPaths.claudeStatuslineSnapshotURL), // try?-ok(quota snapshot, skip path)
           let rateLimitsDict = payload["rate_limits"] as? [String: Any] {
            let rateLimits = ClaudeRateLimits(from: rateLimitsDict)
            let buckets = claudeQuotaBuckets(from: rateLimits, context: context)
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

        // 3. Anthropic rate-limit header probe. The OAuth usage endpoint may
        //    fail for credentials that lack the `user:profile` scope (common on
        //    Pro/Max OAuth tokens). A 1-token probe against `/v1/messages`
        //    reads the `anthropic-ratelimit-unified-*` headers (Claude Max/Pro)
        //    or `anthropic-ratelimit-{requests,input-tokens,output-tokens}-*`
        //    headers (Console API keys) that Anthropic returns on every
        //    response. This is the authoritative per-account quota signal — it
        //    is keyed to the credential's organization, so each slot gets its
        //    own real numbers instead of collapsing to the single shared
        //    statusline hook payload.
        if let probeSnapshot = await headerProbeSnapshot(
            workingCredentials: workingCredentials,
            resolvedAPIKeys: context.resolvedAPIKeys,
            session: context.session,
            environment: context.environment,
            quotaLogger: context.quotaLogger
        ) {
            return probeSnapshot
        }

        // 4. JSONL-based token counting from local Claude project
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

        let jsonlWindows = (try? Self.scanJSONLTokenWindows( // try?-ok(no quota, zero fallback)
            homeDirectoryURL: context.homeDirectoryURL,
            fileManager: context.fileManager,
            environment: context.environment,
            cacheURL: context.appPaths.claudeQuotaJSONLCacheURL
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
        try? context.fileManager.createDirectory(at: parent, withIntermediateDirectories: true) // try?-ok(createDirectory best-effort)
        let envelope: [String: String] = [
            "attemptedAt": ThreadSafeISO8601DateFormatter.formatBasic(Date())
        ]
        if let data = try? JSONSerialization.data(withJSONObject: envelope) { // try?-ok(marker encode best-effort)
            try? data.write(to: url, options: [.atomic]) // try?-ok(marker write best-effort)
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
              let payload = try? context.snapshotStore.readJSONObject(from: context.appPaths.claudeStatuslineSnapshotURL), // try?-ok(quota snapshot, nil skip)
              let rateLimitsDict = payload["rate_limits"] as? [String: Any] else {
            return nil
        }

        let buckets = claudeQuotaBuckets(
            from: ClaudeRateLimits(from: rateLimitsDict),
            context: context
        )
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
        guard let credentials else { return .pro }
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
        return .pro
    }

    // MARK: - File Discovery

    /// Sum real assistant-turn token usage across the rolling 5-hour and
    /// 7-day windows from local Claude transcripts. Public so the app XCTest
    /// bundle can drive it against a temp directory.
    public static func scanJSONLTokenWindows(
        homeDirectoryURL: URL,
        fileManager: FileManager,
        environment: [String: String],
        now: Date = Date(),
        cacheURL: URL? = nil
    ) throws -> JSONLTokenWindows {
        try scanSerialization.withLock { _ in
            try scanJSONLTokenWindowsSerialized(
                homeDirectoryURL: homeDirectoryURL,
                fileManager: fileManager,
                environment: environment,
                now: now,
                cacheURL: cacheURL
            )
        }
    }

    private static func scanJSONLTokenWindowsSerialized(
        homeDirectoryURL: URL,
        fileManager: FileManager,
        environment: [String: String],
        now: Date,
        cacheURL: URL?
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
        var bytesRead = 0
        let cacheStore = cacheURL.map {
            ParserDiskCacheStore<JSONLQuotaCacheEntry>(
                cacheURL: $0,
                fileManager: fileManager,
                schemaVersion: jsonlQuotaCacheSchemaVersion,
                logLabel: "ClaudeQuotaAdapter"
            )
        }
        let cacheKey = cacheURL?.standardizedFileURL.path
        var parseCache: ParserDiskCache<JSONLQuotaCacheEntry>
        if let cacheStore, let cacheKey {
            parseCache = persistedScanCaches.withLock { caches in
                if let cached = caches[cacheKey] {
                    return cached
                }
                let loaded = parserAutoReleasePool {
                    cacheStore.load()
                }
                caches[cacheKey] = loaded
                return loaded
            }
        } else {
            parseCache = inMemoryScanCache.read()
        }
        var cacheMutated = false

        for (file, signature) in files {
            let path = file.standardizedFileURL.path
            let contributions: [JSONLContribution]
            if let cached = parseCache.fileEntries[path], cached.signature == signature {
                contributions = cached.contributions
            } else {
                guard let handle = try? FileHandle(forReadingFrom: file) else { continue } // try?-ok(skip unreadable file)
                defer { try? handle.close() } // try?-ok(handle teardown)
                let cached = parseCache.fileEntries[path]
                let head = headFingerprint(
                    handle: handle,
                    fileSize: signature.sizeBytes
                )
                bytesRead += head.bytesRead
                let canResume = cached.map {
                    $0.endedAtLineBoundary
                        && $0.signature.sizeBytes > 0
                        && $0.signature.sizeBytes < signature.sizeBytes
                        && $0.signature.modifiedAt <= signature.modifiedAt
                        && $0.headPrefixLength == head.length
                        && $0.headPrefixSHA256 == head.sha256
                } ?? false
                let startOffset = canResume ? UInt64(cached?.signature.sizeBytes ?? 0) : 0
                let parsed = parseFileContributions(
                    from: handle,
                    startOffset: startOffset,
                    maxBytes: max(signature.sizeBytes - Int64(startOffset), 0)
                )
                bytesRead += parsed.bytesRead
                contributions = (canResume ? cached?.contributions ?? [] : []) + parsed.contributions
                let entry = JSONLQuotaCacheEntry(
                    signature: signature,
                    contributions: contributions,
                    endedAtLineBoundary: parsed.endedAtLineBoundary,
                    headPrefixLength: head.length,
                    headPrefixSHA256: head.sha256
                )
                if entry != cached {
                    parseCache.fileEntries[path] = entry
                    cacheMutated = true
                }
            }

            filesScanned += 1
            for contribution in contributions {
                guard contribution.timestamp <= now else { continue }
                if contribution.total > 0 {
                    if contribution.timestamp >= fiveHoursAgo { fiveHourTokens += contribution.total }
                    if contribution.timestamp >= sevenDaysAgo { sevenDayTokens += contribution.total }
                }
                latestTimestamp = max(contribution.timestamp, latestTimestamp ?? .distantPast)
            }
        }

        let staleKeys = parseCache.fileEntries.compactMap { key, entry in
            entry.signature.modifiedAt < windowCutoffEpoch ? key : nil
        }
        if !staleKeys.isEmpty {
            parseCache.prune(staleKeys: staleKeys)
            cacheMutated = true
        }
        if cacheMutated {
            if let cacheStore, let cacheKey {
                persistedScanCaches.withLock { $0[cacheKey] = parseCache }
                parserAutoReleasePool {
                    cacheStore.persist(parseCache)
                }
            } else {
                inMemoryScanCache.write(parseCache)
            }
        }

        return JSONLTokenWindows(
            fiveHourTokens: fiveHourTokens,
            sevenDayTokens: sevenDayTokens,
            latestTimestamp: latestTimestamp,
            filesScanned: filesScanned,
            bytesRead: bytesRead
        )
    }

    /// Simulate a fresh process in focused tests without touching the
    /// persisted facts cache on disk.
    static func resetJSONLQuotaCacheMemoryForTesting(cacheURL: URL? = nil) {
        scanSerialization.withLock { _ in
            if let cacheURL {
                let cacheKey = cacheURL.standardizedFileURL.path
                _ = persistedScanCaches.withLock { $0.removeValue(forKey: cacheKey) }
            } else {
                persistedScanCaches.write([:])
                inMemoryScanCache.write(
                    .empty(schemaVersion: jsonlQuotaCacheSchemaVersion)
                )
            }
        }
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

    /// Writes a refreshed Claude OAuth credential back to the per-profile
    /// Keychain item the switcher account reads from, so the rotated
    /// access/refresh tokens survive across quota-refresh ticks and access-token
    /// expiry. Only fires for switcher-profile-scoped refreshes (those carry a
    /// `CLAUDE_CONFIG_DIR`); the global default-login path has no per-profile
    /// item to update and is left untouched. Best-effort: a write failure only
    /// means the next tick must refresh again, so it is logged, not surfaced.
    private func persistRefreshedProfileCredential(
        _ credentials: ClaudeOAuthCredentials,
        context: ProviderQuotaAdapterContext
    ) {
        guard let configDirectory = quotaNonEmpty(context.environment["CLAUDE_CONFIG_DIR"]) else {
            return
        }
        let service = ClaudeProfileScopedKeychain.service(forConfigDirectory: configDirectory)
        do {
            try context.secretStore.setString(
                credentials.routeCredentialStoragePayload(),
                for: NSUserName(),
                service: service
            )
        } catch {
            context.quotaLogSilentFailure("claude_profile_credential_refresh_writeback_failed: \(error)")
        }
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

        return scopedClaudeProfileMatchesDefaultLogin(
            snapshotStore: context.snapshotStore,
            profileStateURL: profileStateURL,
            defaultStateURL: defaultStateURL,
            quotaLogger: context.quotaLogger
        )
    }

    /// Decide whether the scoped switcher profile's `.claude.json` identity
    /// matches the default local login's. This gates `canUseLocalClaudeSessionForAccount`,
    /// which permits the scoped account card to reuse the *global* statusline
    /// session. A wrong `true` would surface another Claude account's quota on
    /// this card — cross-account leakage — so the decision FAILS CLOSED: any
    /// inability to read or parse either identity file returns `false` (no reuse).
    ///
    /// `readJSONObject` returns `nil` for an absent file (the common, benign
    /// "this profile or home has no `.claude.json`" case) and *throws* only for a
    /// real read/parse fault (corrupt JSON, permission denial). The benign-nil
    /// case stays quiet; a real fault is logged so the lost signal is observable,
    /// but it still denies reuse. The previous `try?` collapsed both into a
    /// silent `false`, hiding genuine faults.
    static func scopedClaudeProfileMatchesDefaultLogin(
        snapshotStore: any ProviderQuotaSnapshotPersisting,
        profileStateURL: URL,
        defaultStateURL: URL,
        quotaLogger: any QuotaLogger = NoOpQuotaLogger()
    ) -> Bool {
        let profileState: [String: Any]?
        let defaultState: [String: Any]?
        do {
            profileState = try snapshotStore.readJSONObject(from: profileStateURL)
            defaultState = try snapshotStore.readJSONObject(from: defaultStateURL)
        } catch {
            quotaLogger.log("claude_scoped_profile_identity_read_failed: \(error)")
            return false
        }

        guard let profileState, let defaultState else { return false }

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
            account["organizationUuid"] as? String
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
    ) -> [(url: URL, signature: FileSignature)] {
        var files: [(url: URL, signature: FileSignature)] = []
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

                guard let values = try? fileURL.resourceValues( // try?-ok(skip on stat failure)
                    forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
                ),
                    values.isRegularFile == true,
                    let modified = values.contentModificationDate else { continue }

                let modifiedEpoch = modified.timeIntervalSince1970
                guard modifiedEpoch >= cutoffEpoch else { continue }

                files.append((
                    fileURL,
                    FileSignature(
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

    private func claudeQuotaBuckets(
        from rateLimits: ClaudeRateLimits,
        context: ProviderQuotaAdapterContext
    ) -> [ProviderQuotaBucket] {
        ClaudeQuotaDomainCoreAdapter.buckets(
            from: rateLimits,
            environment: context.environment,
            quotaLogger: context.quotaLogger
        )
    }

    // MARK: - Rate-Limit Header Probe

    /// Extract the raw credential (OAuth bearer or Console API key) for the
    /// current account scope. Prefers the structured OAuth credentials
    /// injected by `accountContext`; falls back to resolved API keys for
    /// Console keys that did not parse as OAuth.
    private func rawProbeCredential(
        workingCredentials: ClaudeOAuthCredentials?,
        resolvedAPIKeys: [String: String?]
    ) -> String? {
        if let token = quotaNonEmpty(workingCredentials?.accessToken) {
            return token
        }
        let claudeKeyIdentifiers = ["Claude Code", "claude code", "claudecode", "claude_code"]
        return claudeKeyIdentifiers.compactMap { identifier in
            quotaNonEmpty(resolvedAPIKeys[identifier].flatMap { $0 })
        }.first
    }

    /// Probe Anthropic with a 1-token request and read the rate-limit headers
    /// from the response. Returns an authoritative per-account snapshot when
    /// the probe is healthy and headers are present; returns `nil` to fall
    /// through to the existing cascade.
    private func headerProbeSnapshot(
        workingCredentials: ClaudeOAuthCredentials?,
        resolvedAPIKeys: [String: String?],
        session: URLSession,
        environment: [String: String],
        quotaLogger: any QuotaLogger
    ) async -> ProviderQuotaSnapshot? {
        guard let rawCredential = rawProbeCredential(
            workingCredentials: workingCredentials,
            resolvedAPIKeys: resolvedAPIKeys
        ) else {
            return nil
        }

        let probe = AnthropicCredentialProbe(session: session)
        let result = await probe.probe(credential: rawCredential)

        guard result.isHealthy, !result.rateLimitHeaders.isEmpty else {
            return nil
        }

        let now = Date(timeIntervalSince1970: floor(result.probedAt.timeIntervalSince1970))
        return AnthropicRateLimitDomainCoreAdapter.snapshot(
            payload: result.rateLimitHeaderPayload,
            shape: result.shape,
            now: now,
            environment: environment,
            quotaLogger: quotaLogger
        ) {
            legacyHeaderProbeSnapshot(headers: result.rateLimitHeaders, shape: result.shape, now: now)
        }
    }

    func legacyHeaderProbeSnapshot(
        headers: AnthropicCredentialProbe.RateLimitHeaders,
        shape: AnthropicCredentialProbe.Shape,
        now: Date
    ) -> ProviderQuotaSnapshot? {
        var buckets: [ProviderQuotaBucket] = []

        if headers.hasUnifiedData {
            let limit = headers.unifiedTokensLimit
            let remaining = headers.unifiedTokensRemaining
            let usedPercent: Double? = {
                guard let limit, limit > 0, let remaining else { return nil }
                return max(0, min(((limit - remaining) / limit) * 100, 100))
            }()
            let resetsAt = headers.unifiedTokensResetSeconds.map { now.addingTimeInterval($0) }
            buckets.append(ProviderQuotaBucket(
                key: "claude-unified-header-probe",
                label: "5-hour unified window",
                windowKind: .rollingHours,
                usedValue: (limit != nil && remaining != nil) ? (limit! - remaining!) : nil,
                limitValue: limit,
                remainingValue: remaining,
                usedPercent: usedPercent,
                resetsAt: resetsAt,
                unit: .tokens,
                isEstimated: false
            ))
        }

        if headers.hasStandardData {
            func standardBucket(
                prefix: String,
                label: String,
                limit: Double?,
                remaining: Double?,
                resetSeconds: Double?
            ) -> ProviderQuotaBucket? {
                guard limit != nil || remaining != nil else { return nil }
                let usedPercent: Double? = {
                    guard let limit, limit > 0, let remaining else { return nil }
                    return max(0, min(((limit - remaining) / limit) * 100, 100))
                }()
                return ProviderQuotaBucket(
                    key: "claude-rate-limit-\(prefix)",
                    label: label,
                    windowKind: .custom,
                    usedValue: (limit != nil && remaining != nil) ? (limit! - remaining!) : nil,
                    limitValue: limit,
                    remainingValue: remaining,
                    usedPercent: usedPercent,
                    resetsAt: resetSeconds.map { now.addingTimeInterval($0) },
                    unit: prefix.contains("tokens") ? .tokens : .requests,
                    isEstimated: false
                )
            }
            buckets.append(contentsOf: [
                standardBucket(
                    prefix: "requests",
                    label: "Requests / minute",
                    limit: headers.requestsLimit,
                    remaining: headers.requestsRemaining,
                    resetSeconds: headers.requestsResetSeconds
                ),
                standardBucket(
                    prefix: "input-tokens",
                    label: "Input tokens / minute",
                    limit: headers.inputTokensLimit,
                    remaining: headers.inputTokensRemaining,
                    resetSeconds: headers.inputTokensResetSeconds
                ),
                standardBucket(
                    prefix: "output-tokens",
                    label: "Output tokens / minute",
                    limit: headers.outputTokensLimit,
                    remaining: headers.outputTokensRemaining,
                    resetSeconds: headers.outputTokensResetSeconds
                )
            ].compactMap { $0 })
        }

        guard !buckets.isEmpty else { return nil }

        let credentialKind = shape == .consoleAPIKey ? "Console API key" : "Claude plan"
        return ProviderQuotaSnapshot(
            provider: .claudeCode,
            fetchedAt: now,
            source: .officialAPI,
            confidence: .exact,
            managementURL: "https://claude.ai/settings/usage",
            statusMessage: "Claude quota from Anthropic rate-limit headers (\(credentialKind)). \(buckets.count) window(s) active.",
            buckets: buckets
        )
    }

    /// Stream a transcript line by line, returning the boundary-independent
    /// `(timestamp, total)` contribution of every assistant turn. The result is
    /// what the per-file cache stores; rolling-window summation happens in
    /// `scanJSONLTokenWindows` so cached values survive window movement.
    ///
    /// `startOffset` must land on a line boundary (0 or a previous parse that
    /// ended with a newline). Incomplete last lines are still flushed at EOF
    /// so a one-shot scan stays bit-identical; those files are not resumed.
    /// `maxBytes` pins the read to the signature captured during discovery, so
    /// a concurrent Claude append cannot be cached under an older file size.
    private static func parseFileContributions(
        from handle: FileHandle,
        startOffset: UInt64 = 0,
        maxBytes: Int64
    ) -> JSONLParseResult {
        try? handle.seek(toOffset: startOffset) // try?-ok(best-effort rewind)

        var contributions: [JSONLContribution] = []
        var currentLine = Data()
        currentLine.reserveCapacity(4 * 1024)
        var lineByteCount = 0
        var bytesRead = 0
        var endedAtLineBoundary = true
        var remainingBytes = max(maxBytes, 0)

        func flushCurrentLine() {
            if lineByteCount > 0, lineByteCount <= ScannerPolicy.maxLineBytes,
               let contribution = parserAutoReleasePool({
                   parseLineContribution(currentLine)
               }) {
                contributions.append(contribution)
            }
            currentLine.removeAll(keepingCapacity: true)
            lineByteCount = 0
        }

        while remainingBytes > 0 {
            var reachedReadEnd = false
            parserAutoReleasePool {
                let requestBytes = Int(min(remainingBytes, 256 * 1024))
                guard let chunk = try? handle.read(upToCount: requestBytes), !chunk.isEmpty else { // try?-ok(EOF/read end-of-stream)
                    flushCurrentLine()
                    reachedReadEnd = true
                    return
                }
                bytesRead += chunk.count
                remainingBytes -= Int64(chunk.count)
                if let last = chunk.last {
                    endedAtLineBoundary = last == 0x0A
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
                    endedAtLineBoundary = false
                }
            }
            if reachedReadEnd { break }
        }
        flushCurrentLine()

        return JSONLParseResult(
            contributions: contributions,
            bytesRead: bytesRead,
            endedAtLineBoundary: endedAtLineBoundary
        )
    }

    private struct JSONLParseResult {
        let contributions: [JSONLContribution]
        let bytesRead: Int
        let endedAtLineBoundary: Bool
    }

    private static func headFingerprint(
        handle: FileHandle,
        fileSize: Int64
    ) -> (length: Int, sha256: String, bytesRead: Int) {
        let length = Int(min(max(fileSize, 0), Int64(jsonlHeadDigestSpan)))
        guard length > 0 else {
            return (0, "", 0)
        }
        try? handle.seek(toOffset: 0) // try?-ok(head fingerprint best-effort)
        let data = handle.readData(ofLength: length)
        return (data.count, QuotaSHA256.hexDigest(data), data.count)
    }

    private static func parseLineContribution(_ data: Data) -> JSONLContribution? {
        guard !data.isEmpty else { return nil }

        guard data.containsAscii(#""type""#),
              data.containsAscii(#""usage""#) else {
            return nil
        }

        guard data.containsAscii(#""type":"assistant""#) else {
            return nil
        }

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], // try?-ok(skip malformed line)
              let type = obj["type"] as? String,
              type == "assistant",
              let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any] else {
            return nil
        }

        guard let tsText = obj["timestamp"] as? String,
              let timestamp = ClaudeJSONLTimestamp.parse(tsText) else {
            return nil
        }

        let input = (usage["input_tokens"] as? Int) ?? 0
        let output = (usage["output_tokens"] as? Int) ?? 0
        let total = max(0, input) + max(0, output)

        return JSONLContribution(timestamp: timestamp, total: total)
    }
}

enum ClaudeJSONLTimestamp {
    static func parse(_ text: String) -> Date? {
        if let contiguous = text.utf8.withContiguousStorageIfAvailable({
            parseCanonicalUTC($0)
        }),
            let parsed = contiguous {
            return parsed
        }
        return ThreadSafeISO8601DateFormatter.parse(text)
    }

    /// Claude's normal transcript timestamp is ASCII UTC
    /// `yyyy-MM-dd'T'HH:mm:ss[.fraction]Z`. Parsing that fixed layout directly
    /// avoids constructing ICU date-format state for every assistant turn.
    /// Less common but valid ISO-8601 variants fall back to the shared
    /// Foundation formatter in `parse(_:)`.
    static func parseCanonicalUTC(_ bytes: UnsafeBufferPointer<UInt8>) -> Date? {
        guard bytes.count >= 20,
              bytes[4] == 0x2D,
              bytes[7] == 0x2D,
              bytes[10] == 0x54,
              bytes[13] == 0x3A,
              bytes[16] == 0x3A else {
            return nil
        }

        func digit(_ index: Int) -> Int? {
            let value = bytes[index]
            guard value >= 0x30, value <= 0x39 else { return nil }
            return Int(value - 0x30)
        }

        func pair(_ index: Int) -> Int? {
            guard let first = digit(index), let second = digit(index + 1) else { return nil }
            return first * 10 + second
        }

        guard let y0 = digit(0),
              let y1 = digit(1),
              let y2 = digit(2),
              let y3 = digit(3),
              let month = pair(5),
              let day = pair(8),
              let hour = pair(11),
              let minute = pair(14),
              let second = pair(17) else {
            return nil
        }
        let year = y0 * 1_000 + y1 * 100 + y2 * 10 + y3
        guard year >= 1970,
              (1...12).contains(month),
              (1...daysInMonth(year: year, month: month)).contains(day),
              (0...23).contains(hour),
              (0...59).contains(minute),
              (0...59).contains(second) else {
            return nil
        }

        var fraction = 0.0
        var index = 19
        if bytes[index] == 0x2E {
            index += 1
            var divisor = 10.0
            var digits = 0
            while index < bytes.count, bytes[index] != 0x5A {
                guard digits < 9, let value = digit(index) else { return nil }
                // ISO8601DateFormatter on Darwin resolves fractional seconds
                // to milliseconds. Match that existing behavior exactly so
                // the fast path remains a drop-in replacement even when an
                // input happens to carry more than Claude's usual 3 digits.
                if digits < 3 {
                    fraction += Double(value) / divisor
                    divisor *= 10
                }
                digits += 1
                index += 1
            }
            guard digits > 0 else { return nil }
        }
        guard index == bytes.count - 1, bytes[index] == 0x5A else {
            return nil
        }

        let days = daysFromUnixEpoch(year: year, month: month, day: day)
        let seconds = days * 86_400
            + Int64(hour * 3_600)
            + Int64(minute * 60)
            + Int64(second)
        return Date(timeIntervalSince1970: Double(seconds) + fraction)
    }

    private static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2:
            let leap = year.isMultiple(of: 4)
                && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
            return leap ? 29 : 28
        case 4, 6, 9, 11:
            return 30
        default:
            return 31
        }
    }

    /// Howard Hinnant's civil-date conversion, offset to Unix epoch day zero.
    private static func daysFromUnixEpoch(year: Int, month: Int, day: Int) -> Int64 {
        let adjustedYear = year - (month <= 2 ? 1 : 0)
        let era = adjustedYear / 400
        let yearOfEra = adjustedYear - era * 400
        let adjustedMonth = month + (month > 2 ? -3 : 9)
        let dayOfYear = (153 * adjustedMonth + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return Int64(era * 146_097 + dayOfEra - 719_468)
    }
}

extension Data {
    func containsAscii(_ substring: String) -> Bool {
        guard let pattern = substring.data(using: .ascii) else { return false }
        return range(of: pattern) != nil
    }
}
