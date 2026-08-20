import Foundation
import OpenBurnBarLogParsers

/// Canonical mapping of every supported agent provider to its log parser.
///
/// Extracted from `UsageAggregator` so the provider list is discoverable,
/// testable, and extensible without touching the aggregation orchestrator.
/// Fail-closed bridge for parsers that have not implemented per-file options.
/// Governed or incremental calls are rejected before the wrapped parser can
/// read content, and the deferral freezes the provider watermark for retry.
private struct RegisteredLogParser: LogParser {
    let parser: any LogParser
    var provider: AgentProvider { parser.provider }

    init(_ parser: any LogParser) {
        self.parser = parser
    }

    func parse(options: LogParseOptions) async throws -> ParseResult {
        var governedOptions = options
        if governedOptions.resourceGovernor == nil {
            governedOptions.resourceGovernor = ParserResourceGovernor(limits: .unlimited)
        }
        let metrics = ParserPassMetrics()
        governedOptions.metrics = metrics
        var status = "succeeded"

        defer {
            let snapshot = metrics.snapshot()
            AppLogger.parser.info(
                "parser_pass_metrics",
                metadata: [
                    "provider": provider.rawValue,
                    "status": status,
                    "candidate_count": String(snapshot.candidateCount),
                    "metadata_stat_count": String(snapshot.metadataStatCount),
                    "content_read_count": String(snapshot.contentReadCount),
                    "content_read_bytes": String(snapshot.contentReadBytes),
                    "deferred_count": String(snapshot.deferredFileCount),
                    "deferred_byte_budget": String(snapshot.byteBudgetDeferredCount),
                    "deferred_metadata_unavailable": String(snapshot.metadataUnavailableDeferredCount),
                    "deferred_byte_count_overflow": String(snapshot.byteCountOverflowDeferredCount),
                    "deferred_content_read_failed": String(snapshot.contentReadFailedDeferredCount),
                    "elapsed_ms": String(format: "%.3f", snapshot.elapsedMilliseconds)
                ]
            )
        }

        do {
            return try await parser.parse(options: governedOptions)
        } catch let error as CancellationError {
            status = "cancelled"
            throw error
        } catch {
            status = "failed"
            throw error
        }
    }
}

/// Canonical mapping of every supported agent provider to its log parser.
/// Every legacy parser is wrapped fail-closed until it implements bounded,
/// options-aware enumeration and reads.
enum ParserRegistry {
    static func defaultParsers() -> [AgentProvider: any LogParser] {
        var parsers: [AgentProvider: any LogParser] = [:]
        parsers[.factory] = RegisteredLogParser(FactoryDroidParser())
        parsers[.claudeCode] = RegisteredLogParser(ClaudeCodeParser())
        parsers[.openClaude] = RegisteredLogParser(ClaudeCodeParser(provider: .openClaude))
        parsers[.copilot] = RegisteredLogParser(CopilotParser())
        parsers[.aider] = RegisteredLogParser(AiderParser())
        parsers[.cursor] = RegisteredLogParser(CursorParser())
        parsers[.cursorAgent] = RegisteredLogParser(CursorAgentParser())
        parsers[.codex] = RegisteredLogParser(LiftedCodexParser())
        parsers[.openCode] = RegisteredLogParser(OpenCodeParser())
        parsers[.piAgent] = RegisteredLogParser(PiAgentParser())
        parsers[.omp] = RegisteredLogParser(OMPParser())
        parsers[.zai] = RegisteredLogParser(ModelFilterParser(modelPattern: "zai", provider: .zai))
        parsers[.minimax] = RegisteredLogParser(ModelFilterParser(modelPattern: "minimax", provider: .minimax))
        parsers[.kimi] = RegisteredLogParser(KimiParser())
        parsers[.xAI] = RegisteredLogParser(GrokParser())
        parsers[.cline] = RegisteredLogParser(ClineFormatParser(provider: .cline, storagePaths: clineStoragePaths()))
        parsers[.kiloCode] = RegisteredLogParser(ClineFormatParser(provider: .kiloCode, storagePaths: kiloCodeStoragePaths()))
        parsers[.rooCode] = RegisteredLogParser(ClineFormatParser(provider: .rooCode, storagePaths: rooCodeStoragePaths()))
        parsers[.forgeDev] = RegisteredLogParser(ForgeDevParser())
        parsers[.augment] = RegisteredLogParser(AugmentParser())
        parsers[.hermes] = RegisteredLogParser(HermesParser())
        parsers[.geminiCLI] = RegisteredLogParser(GeminiCLIParser())
        parsers[.antigravity] = RegisteredLogParser(AntigravityParser())
        parsers[.goose] = RegisteredLogParser(GooseParser())
        parsers[.openClaw] = RegisteredLogParser(OpenClawParser())
        parsers[.windsurf] = RegisteredLogParser(WindsurfParser())
        parsers[.warp] = RegisteredLogParser(WarpParser())
        parsers[.ollama] = RegisteredLogParser(ModelFilterParser(modelPattern: "ollama", provider: .ollama))
        parsers[.junie] = RegisteredLogParser(JunieParser())
        parsers[.primeAgent] = RegisteredLogParser(PrimeAgentParser())
        parsers[.muse] = RegisteredLogParser(MuseParser())
        parsers[.fx] = RegisteredLogParser(FxParser())
        // MiMo quota is API-backed via Token Plan credentials. Do not attach it
        // to the shared Factory sessions tree, or Factory sessions can be counted
        // twice: once as Factory usage and again as MiMo local usage.
        return parsers
    }

    private static func clineStoragePaths() -> [String] {
        var paths: [String] = []
        paths.append("~/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/tasks")
        return paths
    }

    private static func kiloCodeStoragePaths() -> [String] {
        var paths: [String] = []
        paths.append("~/Library/Application Support/Code/User/globalStorage/kilocode.kilo-code/tasks")
        return paths
    }

    private static func rooCodeStoragePaths() -> [String] {
        var paths: [String] = []
        paths.append("~/Library/Application Support/Code/User/globalStorage/rooveterinaryinc.roo-cline/tasks")
        paths.append("~/Library/Application Support/Code/User/globalStorage/roo-inc.roo-code/tasks")
        return paths
    }
}
