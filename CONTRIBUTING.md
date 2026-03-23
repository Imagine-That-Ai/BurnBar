# Contributing to BurnBar

## Project Structure

```
AgentLens/
  App/                          App entry point, menu bar setup (LSUIElement)
  Models/                       Data models (AgentProvider enum, TokenUsage, summaries)
  Services/
    DataStore.swift             GRDB-backed persistence
    UsageAggregator.swift       Orchestrates all parsers, stores results
    SettingsManager.swift       User preferences
    LogParser/
      LogParserProtocol.swift   LogParser protocol (provider + parse())
      ClaudeCodeParser.swift    Claude Code ~/.claude/projects/*.jsonl
      FactoryDroidParser.swift  Factory/Droid ~/.factory/sessions/*.jsonl
      KimiParser.swift          Kimi ~/.kimi/sessions/*.jsonl
      (Codex, Copilot, Aider, Cursor parsers are in UsageAggregator.swift)
  Theme/
    DesignSystem.swift          Color, typography, spacing, radius, animation tokens
    ProviderTheme.swift         Per-provider color mappings
    ThemeManager.swift          Theme state management
  Views/
    Dashboard/                  Main dashboard, per-provider detail, session detail
    Popover/                    Menu bar popover view
    Settings/                   Settings panel
```

## Adding a New Provider Parser

1. **Add a case to `AgentProvider`** in `AgentProvider.swift`:
   - Set `iconName` (SF Symbol), `displayName`, `logDirectory`, and `filePattern`

2. **Create a parser** conforming to the `LogParser` protocol:
   ```swift
   protocol LogParser: Sendable {
       var provider: AgentProvider { get }
       func parse() async throws -> [TokenUsage]
   }
   ```
   Return an empty array if the log directory doesn't exist. Don't throw for missing data.

3. **Register the parser** in `UsageAggregator.init()` by adding it to the `parsers` dictionary:
   ```swift
   self.parsers = [
       // ...existing parsers...
       .yourProvider: YourParser(),
   ]
   ```

4. **Add provider colors** in `DesignSystem.Colors`:
   - `primary(for:)` -- main provider color
   - `accent(for:)` -- secondary/highlight color
   - `chartPalette(for:)` -- array of 4 colors for charts

5. **Test with real log files.** Place sample logs in the expected directory and run a scan from the app.

## Coding Conventions

- **SwiftUI with `@Observable`** (not `ObservableObject`/`@Published`)
- **GRDB** for local persistence (not Core Data, not UserDefaults for structured data)
- **All styling through `DesignSystem` tokens** -- don't use raw colors, font sizes, or spacing values in views
- Parsers must be `Sendable` (they run in async contexts)
- Each parser handles missing directories gracefully (return `[]`, don't crash)

## How to Test

1. Build and run the app
2. Open Settings (gear icon in the popover)
3. Verify provider log paths are correct for your machine
4. Click the refresh button to scan
5. Check the dashboard for parsed sessions and cost totals
