import OpenBurnBarKernel

extension AgentProvider {
    /// Maps a fleet roster id onto the usage-surface provider used for
    /// display. Unknown/forward-compatible ids return nil.
    init?(fleetAgentID: BurnBarFleetAgentID) {
        switch fleetAgentID {
        case .claudeCode: self = .claudeCode
        case .factoryDroid: self = .factory
        case .codex: self = .codex
        case .hermes: self = .hermes
        case .grokBot, .grokCLI: self = .xAI
        case .pi: self = .piAgent
        case .cursor: self = .cursor
        case .kimi: self = .kimi
        case .geminiCLI: self = .geminiCLI
        case .unknown: return nil
        }
    }
}
