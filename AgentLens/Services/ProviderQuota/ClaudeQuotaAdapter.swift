import Foundation


struct ClaudeQuotaAdapter: ProviderQuotaAdapter {
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

        // Fallback: estimate from OpenBurnBar-tracked token usage (works for VS Code too)
        let tokenEstimate = await claudeTokenEstimate(dataStore: context.dataStore)
        if !tokenEstimate.isEmpty {
            return ProviderQuotaSnapshot(
                provider: .claudeCode,
                fetchedAt: Date(),
                source: .localSession,
                confidence: .estimated,
                managementURL: nil,
                statusMessage: "Estimated from OpenBurnBar session token tracking. Install the CLI bridge for exact rate-limit data.",
                buckets: tokenEstimate
            )
        }

        // No data at all
        let message: String
        switch bridgeStatus.state {
        case .notInstalled, .invalidConfiguration:
            message = bridgeStatus.detailText
        case .disabledByHooks:
            message = bridgeStatus.detailText
        case .awaitingFirstPayload:
            message = bridgeStatus.detailText
        case .ready:
            message = "Bridge installed but no rate-limit payload captured yet."
        }
        return unavailableSnapshot(for: .claudeCode, source: .localCLI, message: message)
    }

    // MARK: - Claude Helpers

    private func claudeTokenEstimate(dataStore: DataStore) async -> [ProviderQuotaBucket] {
        let now = Date()
        let calendar = Calendar.current
        let fiveHoursAgo = calendar.date(byAdding: .hour, value: -5, to: now) ?? now
        let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: now) ?? now

        let (fiveHourUsages, sevenDayUsages) = await MainActor.run {
            (
                dataStore.usages(for: .claudeCode, in: fiveHoursAgo...now),
                dataStore.usages(for: .claudeCode, in: sevenDaysAgo...now)
            )
        }

        let fiveHourTokens = Double(fiveHourUsages.reduce(0) { $0 + $1.totalTokens })
        let sevenDayTokens = Double(sevenDayUsages.reduce(0) { $0 + $1.totalTokens })

        guard fiveHourTokens > 0 || sevenDayTokens > 0 else { return [] }

        var buckets: [ProviderQuotaBucket] = []
        if fiveHourTokens > 0 {
            buckets.append(ProviderQuotaBucket(
                key: "claude-five-hour-estimate",
                label: "5-hour window",
                windowKind: .rollingHours,
                usedValue: fiveHourTokens,
                limitValue: nil,
                remainingValue: nil,
                usedPercent: nil,
                resetsAt: calendar.date(byAdding: .hour, value: 5, to: now),
                unit: .tokens,
                isEstimated: true
            ))
        }
        if sevenDayTokens > 0 {
            buckets.append(ProviderQuotaBucket(
                key: "claude-seven-day-estimate",
                label: "7-day window",
                windowKind: .rollingDays,
                usedValue: sevenDayTokens,
                limitValue: nil,
                remainingValue: nil,
                usedPercent: nil,
                resetsAt: calendar.date(byAdding: .day, value: 7, to: now),
                unit: .tokens,
                isEstimated: true
            ))
        }
        return buckets
    }

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
            let usedPercent = FlexibleQuotaBucketNormalizer.number(in: payload, keys: ["used_percentage", "usedPercent", "percentage"])
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
                resetsAt: FlexibleQuotaBucketNormalizer.date(in: payload, keys: ["resets_at", "reset_at", "resetTime"]),
                unit: .percent,
                isEstimated: false
            )
        }
    }

    private func remainingPercent(from dictionary: [String: Any]) -> Double? {
        guard let used = FlexibleQuotaBucketNormalizer.number(in: dictionary, keys: ["used_percentage", "usedPercent", "percentage"]) else {
            return nil
        }
        return max(0, 100 - used)
    }
}
