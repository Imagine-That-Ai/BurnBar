import Foundation

/// Renders the annual "Year in Coding" recap artifact.
///
/// A vertical card-stack narrative with motion, designed to be
/// screenshotted and shared. Currently produces a push payload;
/// MP4 export and in-tab full-screen experience are future work.
public struct YearInCodingRenderer: Sendable {

    public init() {}

    public func render(verdict: InsightVerdict, allVerdicts: [InsightVerdict]) -> CadenceArtifact {
        var cards: [String] = []
        cards.append("🎆 YOUR YEAR IN CODING")
        cards.append(verdict.window.displayLabel)
        cards.append("")

        // Total spend card
        let totalSpend = allVerdicts.reduce(0.0) { $0 + ($1.rings.first { $0.identity == .spend }?.current ?? 0) }
        cards.append("💰 Total spend: $\(String(format: "%.2f", totalSpend))")

        // Top provider card (filter out "Unknown" so only real providers win)
        let providerMentions = Dictionary(grouping: allVerdicts.flatMap(\.bullets)) { bullet in
            bullet.citations.first { citation in
                if case .agent = citation.kind { return true }
                return false
            }?.label ?? "Unknown"
        }.filter { $0.key != "Unknown" }
        if let topProvider = providerMentions.max(by: { $0.value.count < $1.value.count }) {
            cards.append("🏆 Top provider: \(topProvider.key) (\(topProvider.value.count) mentions)")
        }

        // Sessions card
        let totalSessions = allVerdicts.reduce(0.0) { $0 + ($1.rings.first { $0.identity == .sessions }?.current ?? 0) }
        cards.append("🚀 Sessions logged: \(Int(totalSessions))")

        // Cache card
        let avgCache = allVerdicts.compactMap { $0.rings.first { $0.identity == .cache }?.current }.reduce(0, +) / Double(max(1, allVerdicts.count))
        cards.append("⚡ Avg cache hit: \(Int(avgCache))%")

        // Favorite insight (highest confidence, not lexicographic string comparison)
        if let favorite = allVerdicts.flatMap(\.bullets).max(by: { $0.confidence.numericOrder < $1.confidence.numericOrder }) {
            cards.append("💡 Top insight: \(favorite.claim)")
        }

        let body = cards.joined(separator: "\n\n")

        return CadenceArtifact(
            cadence: .annual,
            verdict: verdict,
            payload: .push(
                title: "Your Year in Coding",
                body: body,
                deepLink: "openburnbar://insights/year"
            ),
            provenance: verdict.provenance
        )
    }
}
