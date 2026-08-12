import BurnBarCore
import Foundation

/// Resolves the declared probe root for each roster agent.
///
/// The probe-root override seam (required by the validation contract):
/// - `BURNBAR_FLEET_ROOTS_DIR` overrides the base directory for ALL agents
///   (each agent's root becomes `<override>/<agent-root-name>`);
/// - per-probe overrides win over the base override:
///   `BURNBAR_FLEET_ROOT_CLAUDE_CODE`, `BURNBAR_FLEET_ROOT_FACTORY_DROID`,
///   `BURNBAR_FLEET_ROOT_CODEX`, `BURNBAR_FLEET_ROOT_HERMES`,
///   `BURNBAR_FLEET_ROOT_GROK_BOT`, `BURNBAR_FLEET_ROOT_GROK_CLI`,
///   `BURNBAR_FLEET_ROOT_PI`, `BURNBAR_FLEET_ROOT_CURSOR`,
///   `BURNBAR_FLEET_ROOT_KIMI`, `BURNBAR_FLEET_ROOT_GEMINI_CLI`.
///
/// With no overrides, roots resolve to the real declared roots
/// (`~/.claude`, `~/.factory`, `~/.codex`, `~/.hermes`, `~/.grokbot`,
/// `~/.grok`, `~/.pi`, `~/.cursor`, `~/.kimi`, `~/.gemini`).
public struct BurnBarFleetRootResolver: Sendable {
    public static let environmentKeyBase = "BURNBAR_FLEET_ROOTS_DIR"

    /// The declared root directory name for each roster agent.
    public static func rootDirectoryName(for agentID: BurnBarFleetAgentID) -> String {
        switch agentID {
        case .claudeCode:
            return "claude"
        case .factoryDroid:
            return "factory"
        case .codex:
            return "codex"
        case .hermes:
            return "hermes"
        case .grokBot:
            return "grokbot"
        case .grokCLI:
            return "grok"
        case .pi:
            return "pi"
        case .cursor:
            return "cursor"
        case .kimi:
            return "kimi"
        case .geminiCLI:
            return "gemini"
        case .unknown:
            return "unknown"
        }
    }

    /// The per-probe override environment key for an agent, e.g.
    /// `BURNBAR_FLEET_ROOT_CLAUDE_CODE`.
    public static func environmentKey(for agentID: BurnBarFleetAgentID) -> String {
        let suffix: String
        switch agentID {
        case .claudeCode:
            suffix = "CLAUDE_CODE"
        case .factoryDroid:
            suffix = "FACTORY_DROID"
        case .codex:
            suffix = "CODEX"
        case .hermes:
            suffix = "HERMES"
        case .grokBot:
            suffix = "GROK_BOT"
        case .grokCLI:
            suffix = "GROK_CLI"
        case .pi:
            suffix = "PI"
        case .cursor:
            suffix = "CURSOR"
        case .kimi:
            suffix = "KIMI"
        case .geminiCLI:
            suffix = "GEMINI_CLI"
        case .unknown:
            suffix = "UNKNOWN"
        }
        return "BURNBAR_FLEET_ROOT_\(suffix)"
    }

    private let environment: [String: String]
    private let homeDirectory: URL

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
    }

    /// The resolved root path for an agent, honoring the override seam.
    public func rootPath(for agentID: BurnBarFleetAgentID) -> String {
        let trimmed = { (value: String?) -> String? in
            guard let value else { return nil }
            let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return result.isEmpty ? nil : result
        }

        if let perProbe = trimmed(environment[BurnBarFleetRootResolver.environmentKey(for: agentID)]) {
            return perProbe
        }

        if let base = trimmed(environment[BurnBarFleetRootResolver.environmentKeyBase]) {
            return URL(fileURLWithPath: base, isDirectory: true)
                .appendingPathComponent(BurnBarFleetRootResolver.rootDirectoryName(for: agentID), isDirectory: true)
                .path
        }

        return homeDirectory
            .appendingPathComponent(".\(BurnBarFleetRootResolver.rootDirectoryName(for: agentID))", isDirectory: true)
            .path
    }
}
