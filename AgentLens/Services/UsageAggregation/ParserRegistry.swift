import Foundation

/// Canonical mapping of every supported agent provider to its log parser.
///
/// Extracted from `UsageAggregator` so the provider list is discoverable,
/// testable, and extensible without touching the aggregation orchestrator.
/// Fail-closed bridge for parsers that have not implemented per-file options.
/// Governed or incremental calls are rejected before the wrapped parser can
/// read content, and the deferral freezes the provider watermark for retry.
private struct BoundedLegacyParserAdapter: LogParser {
    let parser: any LogParser
    var provider: AgentProvider { parser.provider }

    init(_ parser: any LogParser) {
        self.parser = parser
    }

    func parse() async throws -> ParseResult {
        try await parser.parse()
    }

    func parse(options: LogParseOptions) async throws -> ParseResult {
        if options.minimumFileModificationDate != nil || options.resourceGovernor != nil {
            options.resourceGovernor?.recordDeferredFile()
            throw ParserOptionsUnsupported(provider: provider)
        }

        let result = try await parser.parse()
        return options.includeConversationBodies
            ? result
            : ParseResult(usages: result.usages, conversations: [])
    }
}

/// Canonical mapping of every supported agent provider to its log parser.
/// Every legacy parser is wrapped fail-closed until it implements bounded,
/// options-aware enumeration and reads.
enum ParserRegistry {
    static func defaultParsers() -> [AgentProvider: any LogParser] {
        var parsers: [AgentProvider: any LogParser] = [:]
        parsers[.factory] = FactoryDroidParser()
        parsers[.claudeCode] = ClaudeCodeParser()
        parsers[.copilot] = BoundedLegacyParserAdapter(CopilotParser())
        parsers[.aider] = BoundedLegacyParserAdapter(AiderParser())
        parsers[.cursor] = BoundedLegacyParserAdapter(CursorParser())
        parsers[.cursorAgent] = CursorAgentParser()
        parsers[.codex] = LiftedCodexParser()
        parsers[.openCode] = BoundedLegacyParserAdapter(OpenCodeParser())
        parsers[.piAgent] = BoundedLegacyParserAdapter(PiAgentParser())
        parsers[.zai] = BoundedLegacyParserAdapter(ModelFilterParser(modelPattern: "zai", provider: .zai))
        parsers[.minimax] = BoundedLegacyParserAdapter(ModelFilterParser(modelPattern: "minimax", provider: .minimax))
        parsers[.kimi] = KimiParser()
        parsers[.xAI] = GrokParser()
        parsers[.cline] = ClineFormatParser(provider: .cline, storagePaths: clineStoragePaths())
        parsers[.kiloCode] = ClineFormatParser(provider: .kiloCode, storagePaths: kiloCodeStoragePaths())
        parsers[.rooCode] = ClineFormatParser(provider: .rooCode, storagePaths: rooCodeStoragePaths())
        parsers[.forgeDev] = ForgeDevParser()
        parsers[.augment] = AugmentParser()
        parsers[.hermes] = HermesParser()
        parsers[.geminiCLI] = GeminiCLIParser()
        parsers[.antigravity] = AntigravityParser()
        parsers[.goose] = GooseParser()
        parsers[.openClaw] = BoundedLegacyParserAdapter(OpenClawParser())
        parsers[.windsurf] = WindsurfParser()
        parsers[.warp] = WarpParser()
        parsers[.ollama] = BoundedLegacyParserAdapter(ModelFilterParser(modelPattern: "ollama", provider: .ollama))
        parsers[.junie] = BoundedLegacyParserAdapter(JunieParser())
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
