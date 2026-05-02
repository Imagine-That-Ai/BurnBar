import Foundation

struct WarpQuotaAdapter: ProviderQuotaAdapter {
    func fetch(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot {
        let directory = context.homeDirectoryURL
            .appendingPathComponent("Library/Application Support/dev.warp.Warp-Stable", isDirectory: true)
        let logFiles = candidateLogFiles(in: directory, fileManager: context.fileManager)

        for file in logFiles.reversed() {
            guard let data = try? Data(contentsOf: file),
                  let content = String(data: data, encoding: .utf8) else {
                continue
            }

            for object in WarpParser.extractBodyJSONObjects(from: content).reversed() {
                if let bucket = findCreditBucket(in: object) {
                    return ProviderQuotaSnapshot(
                        provider: .warp,
                        fetchedAt: Date(),
                        source: .localSession,
                        confidence: bucket.isEstimated ? .estimated : .exact,
                        managementURL: "https://app.warp.dev/",
                        statusMessage: "Warp credit quota inferred from local Warp app telemetry.",
                        buckets: [bucket]
                    )
                }
            }
        }

        return ProviderQuotaSnapshot(
            provider: .warp,
            fetchedAt: Date(),
            source: logFiles.isEmpty ? .unavailable : .localSession,
            confidence: .unavailable,
            managementURL: "https://app.warp.dev/",
            statusMessage: "Warp credit quota was not found in local telemetry. Estimated token usage can still be tracked from Warp agent activity.",
            buckets: []
        )
    }

    private func candidateLogFiles(in directory: URL, fileManager: FileManager) -> [URL] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let files = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return files
            .filter { $0.lastPathComponent.hasPrefix("warp_network") && $0.pathExtension == "log" }
            .sorted {
                let lhs = ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                let rhs = ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                return lhs < rhs
            }
    }

    private func findCreditBucket(in value: Any) -> ProviderQuotaBucket? {
        if let dictionary = value as? [String: Any] {
            if let bucket = creditBucket(from: dictionary) {
                return bucket
            }
            for nested in dictionary.values {
                if let bucket = findCreditBucket(in: nested) {
                    return bucket
                }
            }
        } else if let array = value as? [Any] {
            for nested in array {
                if let bucket = findCreditBucket(in: nested) {
                    return bucket
                }
            }
        }
        return nil
    }

    private func creditBucket(from dictionary: [String: Any]) -> ProviderQuotaBucket? {
        guard dictionary.keys.contains(where: { $0.lowercased().contains("credit") || $0.lowercased().contains("budget") }) else {
            return nil
        }

        let used = number(in: dictionary, keys: [
            "credits_used", "creditsUsed", "credit_used", "creditUsed", "used_credits", "usedCredits",
            "monthly_credits_used", "monthlyCreditsUsed", "budget_used", "budgetUsed", "used",
        ])
        let limit = number(in: dictionary, keys: [
            "credits_limit", "creditsLimit", "credit_limit", "creditLimit", "monthly_credit_limit",
            "monthlyCreditLimit", "included_credits", "includedCredits", "budget_limit", "budgetLimit", "limit",
        ])
        let remaining = number(in: dictionary, keys: [
            "credits_remaining", "creditsRemaining", "credit_remaining", "creditRemaining", "remaining_credits",
            "remainingCredits", "budget_remaining", "budgetRemaining", "remaining",
        ])

        guard used != nil || limit != nil || remaining != nil else { return nil }

        let computedLimit: Double?
        if let limit {
            computedLimit = limit
        } else if let used, let remaining {
            computedLimit = used + remaining
        } else {
            computedLimit = nil
        }

        let computedUsed: Double?
        if let used {
            computedUsed = used
        } else if let computedLimit, let remaining {
            computedUsed = max(computedLimit - remaining, 0)
        } else {
            computedUsed = nil
        }

        let computedRemaining: Double?
        if let remaining {
            computedRemaining = remaining
        } else if let computedLimit, let computedUsed {
            computedRemaining = max(computedLimit - computedUsed, 0)
        } else {
            computedRemaining = nil
        }

        let usedPercent: Double? = {
            if let computedUsed, let computedLimit, computedLimit > 0 {
                return (computedUsed / computedLimit) * 100
            }
            return nil
        }()

        return ProviderQuotaBucket(
            key: "warp-monthly-credits",
            label: "Monthly credits",
            windowKind: .monthly,
            usedValue: computedUsed,
            limitValue: computedLimit,
            remainingValue: computedRemaining,
            usedPercent: usedPercent,
            resetsAt: date(in: dictionary, keys: ["resets_at", "resetsAt", "reset_at", "resetAt", "period_end", "periodEnd"]),
            unit: .count,
            isEstimated: used == nil || limit == nil
        )
    }

    private func number(in dictionary: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            guard let value = dictionary[key] else { continue }
            if let double = value as? Double { return double }
            if let int = value as? Int { return Double(int) }
            if let number = value as? NSNumber { return number.doubleValue }
            if let string = value as? String,
               let double = Double(string.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return double
            }
        }
        return nil
    }

    private func date(in dictionary: [String: Any], keys: [String]) -> Date? {
        for key in keys {
            guard let value = dictionary[key] else { continue }
            if let string = value as? String {
                if let date = ISO8601DateFormatter().date(from: string) {
                    return date
                }
                if let double = Double(string) {
                    return TimestampNormalizationUtility.date(fromEpoch: double)
                }
            } else if let double = value as? Double {
                return TimestampNormalizationUtility.date(fromEpoch: double)
            } else if let int = value as? Int {
                return TimestampNormalizationUtility.date(fromEpoch: Double(int))
            }
        }
        return nil
    }
}
