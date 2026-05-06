import Foundation
import OpenBurnBarCore

enum AppStoreScreenshotMode {
    static var isEnabled: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        let environment = ProcessInfo.processInfo.environment
        return arguments.contains("-OpenBurnBarAppStoreScreenshots")
            || environment["OPENBURNBAR_APP_STORE_SCREENSHOTS"] == "1"
    }

    static var route: String? {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-OpenBurnBarScreenshotRoute"),
           arguments.indices.contains(arguments.index(after: index)) {
            return arguments[arguments.index(after: index)].lowercased()
        }
        return ProcessInfo.processInfo.environment["OPENBURNBAR_SCREENSHOT_ROUTE"]?.lowercased()
    }
}

enum AppStoreScreenshotData {
    private static var now: Date { Date() }

    static var providerAccounts: [ProviderAccountDoc] {
        [
            account(
                id: "codex-hosted",
                providerID: .codex,
                label: "Hosted Codex",
                credentialKind: .session,
                storageScope: .serverPrivate,
                redactedLabel: "App Store entitlement",
                isDefault: true,
                sortKey: 0,
                lastRefreshAt: now.addingTimeInterval(-7 * 60)
            ),
            account(
                id: "claude-local",
                providerID: .claudeCode,
                label: "MacBook Pro",
                credentialKind: .session,
                storageScope: .localOnly,
                redactedLabel: "Local runner",
                isDefault: true,
                sortKey: 1,
                lastRefreshAt: now.addingTimeInterval(-12 * 60)
            ),
            account(
                id: "openai-team",
                providerID: .openAI,
                label: "OpenAI Team",
                credentialKind: .token,
                storageScope: .cloudRefreshable,
                redactedLabel: "sk-...42f1",
                sortKey: 2,
                lastRefreshAt: now.addingTimeInterval(-18 * 60)
            )
        ]
    }

    static var providerConnections: [ProviderConnectionDoc] {
        [
            ProviderConnectionDoc(
                provider: AgentProvider.codex.rawValue,
                status: .connected,
                lastValidatedAt: now.addingTimeInterval(-7 * 60),
                lastRefreshAt: now.addingTimeInterval(-7 * 60),
                credentialKind: .session,
                redactedLabel: "Hosted Codex"
            ),
            ProviderConnectionDoc(
                provider: AgentProvider.claudeCode.rawValue,
                status: .connected,
                lastValidatedAt: now.addingTimeInterval(-12 * 60),
                lastRefreshAt: now.addingTimeInterval(-12 * 60),
                credentialKind: .session,
                redactedLabel: "MacBook Pro"
            ),
            ProviderConnectionDoc(
                provider: AgentProvider.openAI.rawValue,
                status: .connected,
                lastValidatedAt: now.addingTimeInterval(-18 * 60),
                lastRefreshAt: now.addingTimeInterval(-18 * 60),
                credentialKind: .token,
                redactedLabel: "OpenAI Team"
            )
        ]
    }

    static var quotaSnapshots: [ProviderQuotaSnapshot] {
        [
            quotaSnapshot(
                provider: .codex,
                accountID: "codex-hosted",
                accountLabel: "Hosted Codex",
                storageScope: .serverPrivate,
                sourceKind: .provider,
                source: "Hosted on-demand refresh",
                confidence: .high,
                buckets: [
                    ProviderQuotaBucket(name: "Weekly messages", used: 147, limit: 300, remaining: 153, window: "rolling week"),
                    ProviderQuotaBucket(name: "Today", used: 6, limit: 30, remaining: 24, window: "daily")
                ],
                statusMessage: "Updated on demand from OpenBurnBar hosted sync."
            ),
            quotaSnapshot(
                provider: .claudeCode,
                accountID: "claude-local",
                accountLabel: "MacBook Pro",
                storageScope: .localOnly,
                sourceKind: .localCLI,
                source: "Self-hosted Mac runner",
                confidence: .medium,
                buckets: [
                    ProviderQuotaBucket(name: "Plan window", used: 82, limit: 100, remaining: 18, window: "rolling"),
                    ProviderQuotaBucket(name: "Fast lane", used: 21, limit: 40, remaining: 19, window: "daily")
                ],
                statusMessage: "Uploaded by the Mac runner after a manual refresh."
            ),
            quotaSnapshot(
                provider: .cursor,
                accountID: "cursor-team",
                accountLabel: "Cursor Team",
                storageScope: .cloudRefreshable,
                sourceKind: .officialAPI,
                source: "Cursor usage API",
                confidence: .high,
                buckets: [
                    ProviderQuotaBucket(name: "Included usage", used: 218, limit: 500, remaining: 282, window: "monthly", meta: ["unit": "currency"])
                ],
                statusMessage: "Healthy included-usage headroom."
            )
        ]
    }

    static var usageRollups: [UsageRollupDoc] {
        [
            rollup(window: .today, requests: 74, tokens: 412_800, cost: 18.74, multiplier: 1),
            rollup(window: .sevenDays, requests: 418, tokens: 2_814_000, cost: 126.40, multiplier: 7),
            rollup(window: .thirtyDays, requests: 1_882, tokens: 13_740_000, cost: 613.92, multiplier: 30),
            rollup(window: .ninetyDays, requests: 5_264, tokens: 38_270_000, cost: 1_719.30, multiplier: 90),
            rollup(window: .allTime, requests: 18_921, tokens: 142_860_000, cost: 6_284.44, multiplier: 365)
        ]
    }

    static var recentUsage: [TokenUsage] {
        [
            usage(
                provider: .codex,
                sessionID: "codex-quota-refresh",
                project: "Hosted quota sync",
                model: "gpt-5.4-codex",
                input: 34_200,
                output: 9_800,
                cost: 2.84,
                minutesAgo: 16,
                accountID: "codex-hosted",
                accountLabel: "Hosted Codex",
                accountSource: .serverPrivate,
                remote: true
            ),
            usage(
                provider: .claudeCode,
                sessionID: "claude-code-local-runner",
                project: "Mobile release polish",
                model: "claude-sonnet-4.5",
                input: 51_600,
                output: 14_900,
                cost: 3.76,
                minutesAgo: 42,
                accountID: "claude-local",
                accountLabel: "MacBook Pro",
                accountSource: .localOnly,
                remote: false
            ),
            usage(
                provider: .openAI,
                sessionID: "openai-routing-check",
                project: "Provider routing",
                model: "gpt-5.4",
                input: 22_400,
                output: 7_100,
                cost: 1.92,
                minutesAgo: 68,
                accountID: "openai-team",
                accountLabel: "OpenAI Team",
                accountSource: .cloudRefreshable,
                remote: true
            )
        ]
    }

    private static func account(
        id: String,
        providerID: ProviderID,
        label: String,
        credentialKind: CredentialKind,
        storageScope: ProviderAccountStorageScope,
        redactedLabel: String,
        isDefault: Bool = false,
        sortKey: Double,
        lastRefreshAt: Date
    ) -> ProviderAccountDoc {
        ProviderAccountDoc(
            id: id,
            providerID: providerID,
            label: label,
            status: .connected,
            credentialKind: credentialKind,
            storageScope: storageScope,
            redactedLabel: redactedLabel,
            isDefault: isDefault,
            sortKey: sortKey,
            lastValidatedAt: lastRefreshAt,
            lastRefreshAt: lastRefreshAt,
            createdAt: now.addingTimeInterval(-14 * 24 * 60 * 60),
            updatedAt: lastRefreshAt
        )
    }

    private static func quotaSnapshot(
        provider: AgentProvider,
        accountID: String,
        accountLabel: String,
        storageScope: ProviderAccountStorageScope,
        sourceKind: ProviderQuotaSourceKind,
        source: String,
        confidence: ProviderQuotaConfidence,
        buckets: [ProviderQuotaBucket],
        statusMessage: String
    ) -> ProviderQuotaSnapshot {
        ProviderQuotaSnapshot(
            id: "\(provider.providerID.rawValue)-\(accountID)",
            provider: provider.rawValue,
            providerID: provider.providerID,
            accountID: accountID,
            accountLabel: accountLabel,
            accountStorageScope: storageScope,
            sourceKind: sourceKind,
            sourceId: accountID,
            fetchedAt: now.addingTimeInterval(-7 * 60),
            source: source,
            confidence: confidence,
            statusMessage: statusMessage,
            buckets: buckets,
            updatedAt: now.addingTimeInterval(-7 * 60)
        )
    }

    private static func rollup(
        window: RollupWindowKey,
        requests: Int,
        tokens: Int,
        cost: Double,
        multiplier: Int
    ) -> UsageRollupDoc {
        let safeMultiplier = max(multiplier, 1)
        return UsageRollupDoc(
            windowKey: window,
            totals: RollupTotals(requests: requests, tokens: tokens, costUsd: cost),
            providerSummaries: [
                RollupProviderSummary(
                    provider: AgentProvider.codex.rawValue,
                    providerID: AgentProvider.codex.providerID,
                    totalRequests: max(1, requests * 42 / 100),
                    totalTokens: max(1, tokens * 46 / 100),
                    totalCost: cost * 0.44
                ),
                RollupProviderSummary(
                    provider: AgentProvider.claudeCode.rawValue,
                    providerID: AgentProvider.claudeCode.providerID,
                    totalRequests: max(1, requests * 34 / 100),
                    totalTokens: max(1, tokens * 33 / 100),
                    totalCost: cost * 0.36
                ),
                RollupProviderSummary(
                    provider: AgentProvider.openAI.rawValue,
                    providerID: AgentProvider.openAI.providerID,
                    totalRequests: max(1, requests * 24 / 100),
                    totalTokens: max(1, tokens * 21 / 100),
                    totalCost: cost * 0.20
                )
            ],
            accountSummaries: providerAccounts.map { account in
                RollupProviderAccountSummary(
                    providerID: account.providerID,
                    accountID: account.id,
                    accountLabel: account.label,
                    storageScope: account.storageScope,
                    totalRequests: max(1, requests / 3),
                    totalTokens: max(1, tokens / 3),
                    totalCost: cost / 3
                )
            },
            modelSummaries: [
                RollupModelSummary(model: "gpt-5.4-codex", provider: AgentProvider.codex.rawValue, requests: max(1, requests / 3), tokens: max(1, tokens * 40 / 100), cost: cost * 0.40),
                RollupModelSummary(model: "claude-sonnet-4.5", provider: AgentProvider.claudeCode.rawValue, requests: max(1, requests / 3), tokens: max(1, tokens * 34 / 100), cost: cost * 0.36),
                RollupModelSummary(model: "gpt-5.4", provider: AgentProvider.openAI.rawValue, requests: max(1, requests / 4), tokens: max(1, tokens * 26 / 100), cost: cost * 0.24)
            ],
            deviceSummaries: [
                RollupDeviceSummary(deviceId: "MacBook Pro", requests: max(1, requests * 62 / 100), tokens: max(1, tokens * 58 / 100)),
                RollupDeviceSummary(deviceId: "iPad Pro", requests: max(1, requests * 24 / 100), tokens: max(1, tokens * 27 / 100)),
                RollupDeviceSummary(deviceId: "iPhone", requests: max(1, requests * 14 / 100), tokens: max(1, tokens * 15 / 100))
            ],
            dailyPoints: dailyPoints(totalCost: cost, days: min(safeMultiplier, 14)),
            computedAt: now.addingTimeInterval(-5 * 60),
            schemaVersion: 1
        )
    }

    private static func dailyPoints(totalCost: Double, days: Int) -> [RollupDailyPoint] {
        let count = max(days, 7)
        return (0..<count).map { index in
            let dayOffset = count - index - 1
            let variance = 0.72 + (Double((index * 17) % 36) / 100.0)
            let value = (totalCost / Double(count)) * variance
            return RollupDailyPoint(
                date: Calendar.current.date(byAdding: .day, value: -dayOffset, to: now) ?? now,
                value: value
            )
        }
    }

    private static func usage(
        provider: AgentProvider,
        sessionID: String,
        project: String,
        model: String,
        input: Int,
        output: Int,
        cost: Double,
        minutesAgo: TimeInterval,
        accountID: String,
        accountLabel: String,
        accountSource: ProviderAccountStorageScope,
        remote: Bool
    ) -> TokenUsage {
        let end = now.addingTimeInterval(-minutesAgo * 60)
        return TokenUsage(
            provider: provider,
            sessionId: sessionID,
            projectName: project,
            model: model,
            inputTokens: input,
            outputTokens: output,
            costUSD: cost,
            startTime: end.addingTimeInterval(-18 * 60),
            endTime: end,
            createdAt: end,
            usageSource: remote ? .providerLog : .daemon,
            sourceDeviceName: remote ? "OpenBurnBar hosted sync" : "MacBook Pro",
            isRemote: remote,
            providerID: provider.providerID,
            providerAccountID: accountID,
            providerAccountLabel: accountLabel,
            providerAccountSource: accountSource,
            provenanceMethod: remote ? .cloudSync : .daemonBridge,
            provenanceConfidence: .highConfidenceEstimate,
            estimatorVersion: "screenshot-demo"
        )
    }
}
