import GRDB

extension OpenBurnBarDatabase {
    /// Adds the product surface that executed a request. This remains separate
    /// from usageSource, which records how the usage row was ingested.
    static func registerExecutionSourceAttributionMigration(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v57_execution_source_attribution") { db in
            try db.alter(table: "token_usage") { t in
                t.add(column: "executionSourceID", .text).notNull().defaults(to: "unknown")
                t.add(column: "executionSourceName", .text).notNull().defaults(to: "Unknown")
                t.add(column: "executionSourceKind", .text).notNull().defaults(to: "unknown")
                t.add(column: "executionSourceConfidence", .text).notNull().defaults(to: "unknown")
            }

            // Provider-log rows are emitted by dedicated runtime parsers, so
            // the parser identity is durable historical evidence. Codex is
            // deliberately omitted: its rollout session_meta is required to
            // distinguish Codex CLI from Codex Desktop.
            try db.execute(sql: Self.executionSourceBackfillSQL)
            try db.create(
                index: "token_usage_execution_source_time_idx",
                on: "token_usage",
                columns: ["executionSourceID", "startTime"],
                ifNotExists: true
            )
        }
    }

    static let executionSourceBackfillSQL = """
        UPDATE token_usage
        SET executionSourceID = CASE provider
                WHEN 'Factory' THEN 'factory-droid'
                WHEN 'Claude Code' THEN 'claude-code'
                WHEN 'Copilot' THEN 'github-copilot'
                WHEN 'Aider' THEN 'aider'
                WHEN 'Cursor' THEN 'cursor'
                WHEN 'OpenCode' THEN 'opencode'
                WHEN 'Zai' THEN 'zai-cli'
                WHEN 'MiniMax' THEN 'minimax-cli'
                WHEN 'Kimi' THEN 'kimi-cli'
                WHEN 'Cline' THEN 'cline'
                WHEN 'Kilo Code' THEN 'kilo-code'
                WHEN 'Roo Code' THEN 'roo-code'
                WHEN 'Forge' THEN 'forge'
                WHEN 'Augment' THEN 'augment'
                WHEN 'Hermes' THEN 'hermes'
                WHEN 'Pi Agent' THEN 'pi-agent'
                WHEN 'Gemini CLI' THEN 'gemini-cli'
                WHEN 'Antigravity' THEN 'antigravity'
                WHEN 'Goose' THEN 'goose'
                WHEN 'OpenClaw' THEN 'openclaw'
                WHEN 'OpenClaude' THEN 'openclaude'
                WHEN 'OMP' THEN 'omp'
                WHEN 'Ollama' THEN 'ollama'
                WHEN 'Windsurf' THEN 'windsurf'
                WHEN 'Warp' THEN 'warp'
                WHEN 'xAI' THEN 'grok-build'
                WHEN 'Cursor Agent' THEN 'cursor'
                WHEN 'Junie' THEN 'junie'
                ELSE 'unknown'
            END,
            executionSourceName = CASE provider
                WHEN 'Factory' THEN 'Factory Droid'
                WHEN 'Claude Code' THEN 'Claude Code'
                WHEN 'Copilot' THEN 'GitHub Copilot'
                WHEN 'Aider' THEN 'Aider'
                WHEN 'Cursor' THEN 'Cursor'
                WHEN 'OpenCode' THEN 'OpenCode'
                WHEN 'Zai' THEN 'Z.ai CLI'
                WHEN 'MiniMax' THEN 'MiniMax CLI'
                WHEN 'Kimi' THEN 'Kimi CLI'
                WHEN 'Cline' THEN 'Cline'
                WHEN 'Kilo Code' THEN 'Kilo Code'
                WHEN 'Roo Code' THEN 'Roo Code'
                WHEN 'Forge' THEN 'Forge'
                WHEN 'Augment' THEN 'Augment'
                WHEN 'Hermes' THEN 'Hermes'
                WHEN 'Pi Agent' THEN 'Pi Agent'
                WHEN 'Gemini CLI' THEN 'Gemini CLI'
                WHEN 'Antigravity' THEN 'Antigravity'
                WHEN 'Goose' THEN 'Goose'
                WHEN 'OpenClaw' THEN 'OpenClaw'
                WHEN 'OpenClaude' THEN 'OpenClaude'
                WHEN 'OMP' THEN 'OMP'
                WHEN 'Ollama' THEN 'Ollama'
                WHEN 'Windsurf' THEN 'Windsurf'
                WHEN 'Warp' THEN 'Warp'
                WHEN 'xAI' THEN 'Grok Build'
                WHEN 'Cursor Agent' THEN 'Cursor'
                WHEN 'Junie' THEN 'Junie'
                ELSE 'Unknown'
            END,
            executionSourceKind = CASE
                WHEN provider IN ('Copilot', 'Cursor', 'Cline', 'Kilo Code', 'Roo Code', 'Augment', 'Windsurf', 'Cursor Agent', 'Junie') THEN 'ide'
                WHEN provider = 'Factory' THEN 'automation'
                WHEN provider IN ('OpenClaw', 'Ollama') THEN 'service'
                ELSE 'cli'
            END,
            executionSourceConfidence = 'derived_exact'
        WHERE usageSource = 'provider_log'
          AND executionSourceID = 'unknown'
          AND provider IN (
              'Factory', 'Claude Code', 'Copilot', 'Aider', 'Cursor', 'OpenCode',
              'Zai', 'MiniMax', 'Kimi', 'Cline', 'Kilo Code', 'Roo Code', 'Forge',
              'Augment', 'Hermes', 'Pi Agent', 'Gemini CLI', 'Antigravity', 'Goose',
              'OpenClaw', 'OpenClaude', 'OMP', 'Ollama', 'Windsurf', 'Warp', 'xAI',
              'Cursor Agent', 'Junie'
          )
        """
}
