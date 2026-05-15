import Foundation

/// Canonical mapping of every supported agent provider to its log parser.
///
/// Extracted from `UsageAggregator` so the provider list is discoverable,
/// testable, and extensible without touching the aggregation orchestrator.
enum ParserRegistry {
    static func defaultParsers() -> [AgentProvider: any LogParser] {
        var parsers: [AgentProvider: any LogParser] = [:]
        parsers[.factory] = FactoryDroidParser()
        parsers[.claudeCode] = ClaudeCodeParser()
        parsers[.copilot] = CopilotParser()
        parsers[.aider] = AiderParser()
        parsers[.cursor] = CursorParser()
        parsers[.codex] = CodexParser()
        parsers[.zai] = ModelFilterParser(modelPattern: "zai", provider: .zai)
        parsers[.minimax] = ModelFilterParser(modelPattern: "minimax", provider: .minimax)
        parsers[.kimi] = KimiParser()
        parsers[.cline] = ClineFormatParser(provider: .cline, storagePaths: clineStoragePaths())
        parsers[.kiloCode] = ClineFormatParser(provider: .kiloCode, storagePaths: kiloCodeStoragePaths())
        parsers[.rooCode] = ClineFormatParser(provider: .rooCode, storagePaths: rooCodeStoragePaths())
        parsers[.forgeDev] = ForgeDevParser()
        parsers[.augment] = AugmentParser()
        parsers[.hermes] = HermesParser()
        parsers[.geminiCLI] = GeminiCLIParser()
        parsers[.goose] = GooseParser()
        parsers[.openClaw] = OpenClawParser()
        parsers[.windsurf] = WindsurfParser()
        parsers[.warp] = WarpParser()
        parsers[.ollama] = ModelFilterParser(modelPattern: "ollama", provider: .ollama)
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
