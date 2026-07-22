import Foundation

/// Renders the daily morning brief artifact.
///
/// Plan §5.3 — the daily brief is a push-sized distillation of the
/// verdict: headline + 3 bullets + ring deltas. It never exceeds
/// one notification's payload budget.
public struct MorningBriefRenderer: Sendable {

    public init() {}

    public func render(verdict: InsightVerdict) -> CadenceArtifact {
        let pushBody = verdict.bullets.prefix(2).map { "• " + $0.claim }.joined(separator: "\n")

        return CadenceArtifact(
            cadence: .daily,
            verdict: verdict,
            payload: .push(
                title: verdict.headline,
                body: pushBody.isEmpty ? verdict.headline : pushBody,
                deepLink: "openburnbar://insights/today"
            ),
            provenance: verdict.provenance
        )
    }
}
