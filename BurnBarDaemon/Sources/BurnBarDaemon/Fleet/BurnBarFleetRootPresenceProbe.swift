import BurnBarCore
import Foundation

/// Default honest probe used for every roster agent until the per-agent
/// signal probes land. It checks the declared root (via the probe-root
/// override seam) and reports a typed row:
/// - root missing → `failed(reason: "Declared root missing: <path>")` health
///   and an `unknown`/`unsupported` row — never a fabricated live row;
/// - root present → `ok` health and an `unknown`/`unsupported` row with an
///   honest note that no live-signal probe is implemented for this agent yet.
///
/// This keeps the fixed ten-row roster complete and honest on empty roots
/// (VAL-FLEET-007) while the per-agent probes are built.
public struct BurnBarFleetRootPresenceProbe: BurnBarFleetProbe {
    public let agentID: BurnBarFleetAgentID
    public let rootPath: String

    public init(agentID: BurnBarFleetAgentID, rootPath: String) {
        self.agentID = agentID
        self.rootPath = rootPath
    }

    public func probe(now: Date) async -> BurnBarFleetProbeResult {
        let rootExists = FileManager.default.fileExists(atPath: rootPath)

        let healthState: BurnBarFleetProbeHealthState
        let note: String
        if rootExists {
            healthState = .ok
            note = "Declared root present; no live-signal probe implemented for this agent yet."
        } else {
            healthState = .failed(reason: "Declared root missing: \(rootPath)")
            note = "Declared root missing."
        }

        let agent = BurnBarFleetAgent(
            id: agentID,
            displayName: BurnBarFleetSnapshotBuilder.displayName(for: agentID),
            status: .unknown,
            confidence: .unsupported,
            note: note
        )
        let health = BurnBarFleetProbeHealth(
            agent: agentID,
            state: healthState,
            rootPath: rootPath,
            checkedAt: now
        )
        return BurnBarFleetProbeResult(agent: agent, health: health)
    }
}
