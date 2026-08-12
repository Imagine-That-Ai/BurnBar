import BurnBarCore
import Foundation

/// One probe for one declared roster agent. Probes are read-only: they read
/// declared roots and verify process existence (`kill -0`-style) only. The
/// snapshot builder runs every roster probe on each tick and merges the
/// results into the fixed ten-row snapshot.
public protocol BurnBarFleetProbe: Sendable {
    /// The roster agent this probe reports for.
    var agentID: BurnBarFleetAgentID { get }
    /// The declared root path for this agent (reported in probe-health rows).
    var rootPath: String { get }
    /// Runs the probe against the declared root, evaluating freshness against
    /// `now` so the builder controls the reference clock.
    func probe(now: Date) async -> BurnBarFleetProbeResult
}

/// The outcome of one probe run: the agent row plus its probe-health entry.
/// The builder merges these into the snapshot; it never fabricates either.
public struct BurnBarFleetProbeResult: Sendable {
    public let agent: BurnBarFleetAgent
    public let health: BurnBarFleetProbeHealth

    public init(agent: BurnBarFleetAgent, health: BurnBarFleetProbeHealth) {
        self.agent = agent
        self.health = health
    }
}
