import BurnBarCore
import Foundation

/// Builds the default per-agent probe set for the daemon.
///
/// The three file/pid-based probes (claude-code, grok-cli, factory-droid)
/// are real signal probes; the remaining roster agents keep the honest
/// root-presence probe until their per-agent probes land (daemon-agent-probes-b).
public enum BurnBarFleetProbeFactory {
    /// Builds one probe per declared roster agent, resolving each root via
    /// the probe-root override seam.
    public static func makeDefaultProbes(
        rootResolver: BurnBarFleetRootResolver
    ) -> [BurnBarFleetAgentID: any BurnBarFleetProbe] {
        var probes: [BurnBarFleetAgentID: any BurnBarFleetProbe] = [:]

        for agentID in BurnBarFleetAgentID.declaredRoster {
            let rootPath = rootResolver.rootPath(for: agentID)
            switch agentID {
            case .claudeCode:
                probes[agentID] = BurnBarFleetClaudeCodeProbe(agentID: agentID, rootPath: rootPath)
            case .grokCLI:
                probes[agentID] = BurnBarFleetGrokCLIProbe(agentID: agentID, rootPath: rootPath)
            case .factoryDroid:
                probes[agentID] = BurnBarFleetFactoryDroidProbe(agentID: agentID, rootPath: rootPath)
            default:
                probes[agentID] = BurnBarFleetRootPresenceProbe(agentID: agentID, rootPath: rootPath)
            }
        }

        return probes
    }
}
