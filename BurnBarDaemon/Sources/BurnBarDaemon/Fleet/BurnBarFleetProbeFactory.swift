import BurnBarCore
import Foundation

/// Builds the default per-agent probe set for the daemon.
///
/// All ten roster agents are served by real per-agent probes: seven signal
/// probes (claude-code, grok-cli, factory-droid, grok-bot, hermes, codex,
/// pi), the partial-confidence cursor probe, and typed unsupported probes
/// for kimi/gemini-cli.
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
            case .grokBot:
                probes[agentID] = BurnBarFleetGrokBotProbe(agentID: agentID, rootPath: rootPath)
            case .hermes:
                probes[agentID] = BurnBarFleetHermesProbe(agentID: agentID, rootPath: rootPath)
            case .codex:
                probes[agentID] = BurnBarFleetCodexProbe(agentID: agentID, rootPath: rootPath)
            case .pi:
                probes[agentID] = BurnBarFleetPiProbe(agentID: agentID, rootPath: rootPath)
            case .cursor:
                probes[agentID] = BurnBarFleetCursorProbe(agentID: agentID, rootPath: rootPath)
            case .kimi:
                probes[agentID] = BurnBarFleetUnsupportedProbe(
                    agentID: agentID,
                    rootPath: rootPath,
                    note: "No live signal is claimed for Kimi; typed unsupported row "
                        + "(probe plan in BURNBAR_FLEET_SIGNALS.md)."
                )
            case .geminiCLI:
                probes[agentID] = BurnBarFleetUnsupportedProbe(
                    agentID: agentID,
                    rootPath: rootPath,
                    note: "No live signal is claimed for Gemini CLI; typed unsupported row "
                        + "(probe plan in BURNBAR_FLEET_SIGNALS.md)."
                )
            case .unknown:
                probes[agentID] = BurnBarFleetUnsupportedProbe(
                    agentID: agentID,
                    rootPath: rootPath,
                    note: "Unknown roster id; typed unsupported row."
                )
            }
        }

        return probes
    }
}
