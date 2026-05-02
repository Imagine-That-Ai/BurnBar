import Foundation

/// Canonical mapping of every supported agent provider to its log parser.
///
/// Extracted from `UsageAggregator` so the provider list is discoverable,
/// testable, and extensible without touching the aggregation orchestrator.
enum ParserRegistry {
    static func defaultParsers() -> [AgentProvider: any LogParser] {
        [
            .factory: FactoryDroidParser(),
            .claudeCode: ClaudeCodeParser(),
            .copilot: CopilotParser(),
            .aider: AiderParser(),
            .cursor: CursorParser(),
            .codex: CodexParser(),
            .zai: ModelFilterParser(modelPattern: "zai", provider: .zai),
            .minimax: ModelFilterParser(modelPattern: "minimax", provider: .minimax),
            .kimi: KimiParser(),
            .cline: ClineFormatParser(provider: .cline, storagePaths: [
                "~/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/tasks",
            ]),
            .kiloCode: ClineFormatParser(provider: .kiloCode, storagePaths: [
                "~/Library/Application Support/Code/User/globalStorage/kilocode.kilo-code/tasks",
            ]),
            .rooCode: ClineFormatParser(provider: .rooCode, storagePaths: [
                "~/Library/Application Support/Code/User/globalStorage/rooveterinaryinc.roo-cline/tasks",
                "~/Library/Application Support/Code/User/globalStorage/roo-inc.roo-code/tasks",
            ]),
            .forgeDev: ForgeDevParser(),
            .augment: AugmentParser(),
            .hermes: HermesParser(),
            .geminiCLI: GeminiCLIParser(),
            .goose: GooseParser(),
            .windsurf: WindsurfParser(),
            .warp: WarpParser(),
        ]
    }
}
