@testable import OpenBurnBar

typealias AgentProvider = OpenBurnBar.AgentProvider
typealias TokenUsage = OpenBurnBar.TokenUsage
typealias UsageSource = OpenBurnBar.UsageSource

extension Optional where Wrapped == String {
    func contains(_ other: String) -> Bool {
        self?.contains(other) == true
    }
}

extension String {
    static var claudeCode: String { AgentProvider.claudeCode.rawValue }
    static var codex: String { AgentProvider.codex.rawValue }
    static var warp: String { AgentProvider.warp.rawValue }

    static var localCLI: String { ProviderQuotaSourceKind.localCLI.rawValue }
    static var localSession: String { ProviderQuotaSourceKind.localSession.rawValue }
    static var officialAPI: String { ProviderQuotaSourceKind.officialAPI.rawValue }
    static var unavailable: String { ProviderQuotaSourceKind.unavailable.rawValue }
}
