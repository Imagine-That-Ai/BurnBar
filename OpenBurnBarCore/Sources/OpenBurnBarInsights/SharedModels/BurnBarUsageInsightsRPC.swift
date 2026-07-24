import Foundation
import OpenBurnBarKernel

/// Wire response for `daemon.usage.insights`.
///
/// `InsightAnalysisResult` is already privacy-bounded by `InsightDigestBuilder`;
/// keeping it inside this typed response makes the daemon the authority for
/// source IDs, citations, and platform provenance.
public struct BurnBarUsageInsightsResponse: Codable, Hashable, Sendable {
    public let usage: [BurnBarUsageEvent]
    public let analysis: InsightAnalysisResult
    public let sourceID: String
    public let sourceLabel: String

    public init(
        usage: [BurnBarUsageEvent],
        analysis: InsightAnalysisResult,
        sourceID: String,
        sourceLabel: String
    ) {
        self.usage = usage
        self.analysis = analysis
        self.sourceID = sourceID
        self.sourceLabel = sourceLabel
    }
}
