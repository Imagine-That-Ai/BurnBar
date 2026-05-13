import Foundation

/// Builds the shared LLM-safe analysis context from a platform snapshot.
public struct InsightAggregator: Sendable {
    public var digestBuilder: InsightDigestBuilder

    public init(digestBuilder: InsightDigestBuilder = InsightDigestBuilder()) {
        self.digestBuilder = digestBuilder
    }

    public func buildContext(
        snapshot: InsightDataSnapshot,
        filter: InsightFilter,
        includedDataSources: [String],
        priorRunSummaries: [String] = []
    ) throws -> InsightAnalysisContext {
        let digest = try digestBuilder.build(from: snapshot, filter: filter)
        let encodedBytes = Self.encodedBytes(digest)
        let evidence = Self.buildEvidenceIndex(from: digest)
        let truncated = Self.truncatedSources(digest: digest, sources: includedDataSources)
        let budget = InsightContextBudgetReport(
            encodedBytes: encodedBytes,
            estimatedPromptTokens: max(1, encodedBytes / 4),
            includedDataSources: includedDataSources,
            truncatedDataSources: truncated,
            truncationSummary: truncated.isEmpty
                ? "No truncation."
                : "Context was budgeted to \(InsightDigest.maxEncodedBytes) bytes; long-tail \(truncated.joined(separator: ", ")) data was summarized."
        )
        return InsightAnalysisContext(
            digest: digest,
            evidenceIndex: evidence,
            budgetReport: budget,
            priorRunSummaries: priorRunSummaries
        )
    }

    private static func encodedBytes(_ digest: InsightDigest) -> Int {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(digest))?.count ?? 0
    }

    private static func truncatedSources(digest: InsightDigest, sources: [String]) -> [String] {
        var out: [String] = []
        if digest.providers.count >= 8, sources.contains("provider_summaries") { out.append("provider_summaries") }
        if digest.models.count >= 12, sources.contains("model_summaries") { out.append("model_summaries") }
        if digest.daily.count >= 30, sources.contains("daily_points") { out.append("daily_points") }
        return out
    }

    private static func buildEvidenceIndex(from digest: InsightDigest) -> [InsightEvidence] {
        var evidence: [InsightEvidence] = []
        for provider in digest.providers.prefix(8) {
            let citation = InsightCitation(kind: .agent(provider: provider.id), label: provider.displayName)
            evidence.append(.init(
                id: "provider:\(provider.id)",
                citation: citation,
                source: "provider_summaries",
                summary: "\(provider.displayName): \(provider.sessionCount) sessions, \(provider.totalTokens) tokens, \(String(format: "$%.2f", provider.costUSD)).",
                numericValue: provider.costUSD
            ))
        }
        for model in digest.models.prefix(8) {
            let citation = InsightCitation(kind: .model(id: model.id), label: model.id)
            evidence.append(.init(
                id: "model:\(model.id)",
                citation: citation,
                source: "model_summaries",
                summary: "\(model.id): \(model.sessionCount) sessions, \(model.totalTokens) tokens, \(String(format: "$%.2f", model.costUSD)).",
                numericValue: model.costUSD
            ))
        }
        for quota in digest.quotaSnapshots.prefix(8) {
            let citation = InsightCitation(kind: .quota(provider: quota.providerID, bucket: quota.bucketName),
                                           label: "\(quota.providerID) \(quota.bucketName)")
            let numericValue: Double?
            if let limit = quota.limit, limit > 0 {
                numericValue = quota.used / limit
            } else {
                numericValue = nil
            }
            let limitText = quota.limit.map { String($0) } ?? "unknown"
            let item = InsightEvidence(
                id: "quota:\(quota.id)",
                citation: citation,
                source: "quota_snapshots",
                summary: "\(quota.providerID) \(quota.bucketName): \(quota.used) used of \(limitText).",
                numericValue: numericValue
            )
            evidence.append(item)
        }
        for point in digest.daily.sorted(by: { $0.costUSD > $1.costUSD }).prefix(5) {
            let day = ISO8601DateFormatter().string(from: point.day)
            let citation = InsightCitation(kind: .day(date: day), label: day.prefix(10).description)
            evidence.append(.init(
                id: "day:\(day)",
                citation: citation,
                source: "daily_points",
                summary: "\(day.prefix(10)): \(String(format: "$%.2f", point.costUSD)), \(point.totalTokens) tokens, \(point.sessionCount) sessions.",
                numericValue: point.costUSD
            ))
        }
        return evidence
    }
}
