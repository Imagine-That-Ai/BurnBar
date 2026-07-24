import Foundation
import OpenBurnBarKernel

/// The shared provider-to-quota-adapter dispatch table.
///
/// Keeping this table in the cross-platform quota target prevents the macOS
/// service and non-Apple consumers from silently drifting as providers are
/// added to `AgentProvider.quotaSignalProviders`. Providers without a stable
/// source are registered explicitly as unavailable instead of falling through
/// a generic "not implemented" branch.
public struct ProviderQuotaAdapterRegistry: Sendable {
    public enum Coverage: String, Codable, Sendable {
        case live
        case unavailable
    }

    public struct Entry: Sendable {
        public let provider: AgentProvider
        public let adapter: any ProviderQuotaAdapter
        public let coverage: Coverage

        public init(
            provider: AgentProvider,
            adapter: any ProviderQuotaAdapter,
            coverage: Coverage
        ) {
            self.provider = provider
            self.adapter = adapter
            self.coverage = coverage
        }
    }

    private let entriesByProvider: [AgentProvider: Entry]

    public init(entries: [Entry]) {
        var table: [AgentProvider: Entry] = [:]
        for entry in entries {
            table[entry.provider] = entry
        }
        self.entriesByProvider = table
    }

    public var providers: Set<AgentProvider> {
        Set(entriesByProvider.keys)
    }

    public func entry(for provider: AgentProvider) -> Entry? {
        entriesByProvider[provider]
    }

    public func adapter(for provider: AgentProvider) -> (any ProviderQuotaAdapter)? {
        entriesByProvider[provider]?.adapter
    }

    /// The canonical adapter table used by the macOS refresh actor and the
    /// cross-platform quota consumers. Keep unsupported quota signals explicit.
    public static let standard = ProviderQuotaAdapterRegistry(entries: [
        live(.codex, CodexQuotaAdapter()),
        live(.openCode, OpenCodeQuotaAdapter()),
        live(.omp, OMPQuotaAdapter()),
        live(.openAI, OpenAIQuotaAdapter()),
        live(.deepSeek, DeepSeekQuotaAdapter()),
        live(.claudeCode, ClaudeQuotaAdapter()),
        live(.copilot, CopilotQuotaAdapter()),
        live(.minimax, MiniMaxQuotaAdapter()),
        live(.zai, ZAIQuotaAdapter()),
        live(.factory, FactoryQuotaAdapter()),
        live(.cursor, CursorQuotaAdapter()),
        live(.warp, WarpQuotaAdapter()),
        live(.ollama, OllamaQuotaAdapter()),
        live(.kimi, KimiQuotaAdapter()),
        live(.antigravity, AntigravityQuotaAdapter()),
        live(.xAI, XAIQuotaAdapter()),
        live(.mimo, MimoQuotaAdapter()),
        unavailable(
            .cursorAgent,
            message: "Cursor Agent has no stable quota API; connect a self-hosted bridge to report it."
        ),
        unavailable(
            .openBurnBar,
            message: "OpenBurnBar hosted quota is refreshed by the cloud account service."
        )
    ])

    private static func live(
        _ provider: AgentProvider,
        _ adapter: any ProviderQuotaAdapter
    ) -> Entry {
        Entry(provider: provider, adapter: adapter, coverage: .live)
    }

    private static func unavailable(_ provider: AgentProvider, message: String) -> Entry {
        Entry(
            provider: provider,
            adapter: UnavailableQuotaAdapter(provider: provider, message: message),
            coverage: .unavailable
        )
    }
}

/// Explicit fail-closed adapter for a provider with no local/API quota source.
public struct UnavailableQuotaAdapter: ProviderQuotaAdapter {
    public let provider: AgentProvider
    public let message: String

    public init(provider: AgentProvider, message: String) {
        self.provider = provider
        self.message = message
    }

    public func fetch(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot {
        ProviderQuotaSnapshot(
            provider: provider,
            fetchedAt: Date(),
            source: .unavailable,
            confidence: .unavailable,
            managementURL: nil,
            statusMessage: message,
            buckets: []
        )
    }
}
