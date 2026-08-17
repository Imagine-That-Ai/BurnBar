import OpenBurnBarKernel
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

/// The outcome of one probe run: the agent roll-up row, its probe-health
/// entry, and the bounded thread list for that CLI. The builder concatenates
/// threads across the roster; it never fabricates either.
public struct BurnBarFleetProbeResult: Sendable {
    public let agent: BurnBarFleetAgent
    public let health: BurnBarFleetProbeHealth
    public let threads: [BurnBarFleetThread]

    public init(
        agent: BurnBarFleetAgent,
        health: BurnBarFleetProbeHealth,
        threads: [BurnBarFleetThread] = []
    ) {
        self.agent = agent
        self.health = health
        self.threads = threads
    }
}
