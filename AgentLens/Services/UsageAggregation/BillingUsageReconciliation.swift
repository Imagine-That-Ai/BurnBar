import Foundation

/// API billing vs local log-parsed usage reconciliation helpers.
enum BillingUsageReconciliation {
    static let apiReconciliationSessionPrefix = "api-reconcile-"

    static func supplementalUsages(
        from records: [ProviderUsageRecord],
        existingUsages: [TokenUsage]
    ) -> [TokenUsage] {
        let calendar = Calendar.current
        return records.compactMap { record in
            guard let fallbackProvider = record.mappedProvider else { return nil }

            let windowStart = calendar.startOfDay(for: record.date)
            let windowEnd = calendar.date(byAdding: .day, value: 1, to: windowStart) ?? windowStart
            let window = windowStart...windowEnd
            let matchingLocalUsages = existingUsages.filter { usage in
                usage.intersects(dateRange: window) && usageMatches(record: record, usage: usage)
            }

            let localInput = matchingLocalUsages.reduce(0) { $0 + $1.inputTokens }
            let localOutput = matchingLocalUsages.reduce(0) { $0 + $1.outputTokens }
            let localCacheRead = matchingLocalUsages.reduce(0) { $0 + $1.cacheReadTokens }
            let localCacheWrite = matchingLocalUsages.reduce(0) { $0 + $1.cacheCreationTokens }
            let localCost = matchingLocalUsages.reduce(0.0) { $0 + $1.cost }

            let missingInput = max(record.inputTokens - localInput, 0)
            let missingOutput = max(record.outputTokens - localOutput, 0)
            let missingCacheRead = max(record.cacheReadTokens - localCacheRead, 0)
            let missingCacheWrite = max(record.cacheCreationTokens - localCacheWrite, 0)
            let missingCost = max(record.costUSD - localCost, 0)

            let costEpsilon = 1e-9
            guard missingInput > 0 || missingOutput > 0 || missingCacheRead > 0 || missingCacheWrite > 0 || missingCost > costEpsilon else {
                return nil
            }

            let candidateProviders = Set(matchingLocalUsages.map(\.provider))
            let targetProvider: AgentProvider
            if candidateProviders.count == 1, let only = candidateProviders.first {
                targetProvider = only
            } else {
                targetProvider = fallbackProvider
            }

            let modelKey = sanitizedModelKey(record.model)
            let providerKey = targetProvider.rawValue
                .lowercased()
                .replacingOccurrences(of: " ", with: "-")
            let sessionId = "\(apiReconciliationSessionPrefix)\(providerKey)-\(Int(windowStart.timeIntervalSince1970))-\(modelKey)"
            let projectName = matchingLocalUsages.isEmpty
                ? "\(record.providerName) API Reconciliation"
                : "\(targetProvider.displayName) · \(record.providerName) API Reconciliation"

            return TokenUsage(
                provider: targetProvider,
                sessionId: sessionId,
                projectName: projectName,
                model: record.model,
                inputTokens: missingInput,
                outputTokens: missingOutput,
                cacheCreationTokens: missingCacheWrite,
                cacheReadTokens: missingCacheRead,
                costUSD: missingCost,
                startTime: windowStart,
                endTime: windowStart,
                usageSource: .billingAPI,
                provenanceMethod: .billingAPI,
                provenanceConfidence: .exact
            )
        }
    }

    static func usageMatches(record: ProviderUsageRecord, usage: TokenUsage) -> Bool {
        switch record.mappedProvider {
        case .some(.minimax):
            let localKey = TokenExtractionUtility.normalizeModelKey(usage.model)
            let apiKey = TokenExtractionUtility.normalizeModelKey(record.model)
            if apiKey == "minimax" {
                return localKey.contains("minimax")
            }
            return localKey == apiKey || localKey.contains(apiKey) || (apiKey.contains("minimax") && localKey.contains("minimax"))
        case .some(.zai):
            let localKey = TokenExtractionUtility.normalizeModelKey(usage.model)
            let apiKey = TokenExtractionUtility.normalizeModelKey(record.model)
            if apiKey == "glm" || apiKey == "zai" || apiKey == "z.ai" {
                return localKey.contains("glm") || localKey.contains("zai")
            }
            return localKey == apiKey || localKey.contains(apiKey) || apiKey.contains(localKey)
        case .some(.copilot):
            return usage.provider == .copilot
        case .some(let provider):
            guard usage.provider == provider else {
                return false
            }

            let localKey = TokenExtractionUtility.normalizeModelKey(usage.model)
            let apiKey = TokenExtractionUtility.normalizeModelKey(record.model)
            return localKey == apiKey || localKey.contains(apiKey) || apiKey.contains(localKey)
        case .none:
            return false
        }
    }

    static func sanitizedModelKey(_ model: String) -> String {
        let raw = TokenExtractionUtility.normalizeModelKey(model)
        let allowed = raw.map { character -> Character in
            if character.isLetter || character.isNumber || character == "-" {
                return character
            }
            return "-"
        }
        let sanitized = String(allowed)
            .replacingOccurrences(of: "--", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return sanitized.isEmpty ? "model" : sanitized
    }
}
