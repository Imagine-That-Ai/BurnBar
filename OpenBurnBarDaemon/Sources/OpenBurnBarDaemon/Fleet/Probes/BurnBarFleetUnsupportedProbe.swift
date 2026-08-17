import OpenBurnBarKernel
import Foundation

/// Typed unsupported probe for roster agents with no live signal (kimi,
/// gemini-cli). The row is always `unknown`/`unsupported` with a documented
/// probe-plan note — never omitted, never presented as live (VAL-FLEET-015).
/// The declared root is still checked so probe-health reports the honest
/// root state (missing → `failed`, present → `ok`).
public struct BurnBarFleetUnsupportedProbe: BurnBarFleetProbe {
    public let agentID: BurnBarFleetAgentID
    public let rootPath: String
    /// Honest probe-plan note surfaced on the row.
    public let note: String

    public init(agentID: BurnBarFleetAgentID, rootPath: String, note: String) {
        self.agentID = agentID
        self.rootPath = rootPath
        self.note = note
    }

    public func probe(now: Date) async -> BurnBarFleetProbeResult {
        if let rootIssue = BurnBarFleetProbeSupport.rootAccessResult(
            agentID: agentID,
            rootPath: rootPath,
            now: now
        ) {
            return rootIssue
        }
        return BurnBarFleetProbeSupport.noEvidenceResult(
            agentID: agentID,
            rootPath: rootPath,
            now: now,
            note: note
        )
    }
}
