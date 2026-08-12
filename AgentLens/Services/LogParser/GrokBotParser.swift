import Foundation

// MARK: - Grok Bot Parser

/// Grok Bot is a **live-signal-only** provider: its daemon state files
/// (`~/.grokbot/local-exec-daemon.json`, `local-exec-supervisor.json`) carry
/// process liveness and `inflightCount`, but no parseable token-usage history
/// exists (see docs/fleet/BURNBAR_FLEET_SIGNALS.md §5). Live signals are owned
/// by the fleet probes; the usage parser is an honest empty no-op.
///
/// Metadata honesty (VAL-PROV-008): `supportLevel == .unsupported` and
/// `dataConfidence == .unavailable` — never `supported`/`exact`, and no
/// TokenUsage rows are ever fabricated from the daemon state files.
final class GrokBotParser: LogParser, @unchecked Sendable {
    let provider: AgentProvider = .grokBot

    func parse() async throws -> ParseResult {
        // No parseable usage history exists for Grok Bot. The daemon state
        // files are live-signal inputs owned by the fleet probes (M1), not
        // usage logs — returning empty is the honest outcome.
        ParseResult(usages: [], conversations: [])
    }
}
