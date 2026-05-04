# Contributing to OpenBurnBar

## Repository layout (high level)

OpenBurnBar is more than the macOS app:

| Area | Path | Notes |
|------|------|--------|
| macOS app | `AgentLens/` | Menu bar UI, GRDB, parsers, dashboard |
| Shared contracts | `OpenBurnBarCore/` | App ↔ daemon wire types |
| Daemon + CLI | `OpenBurnBarDaemon/` | JSON-RPC daemon, `OpenBurnBarCLI`, mission control, runs |
| Editor extension | `extensions/openburnbar/` | Cursor / VS Code |
| MCP helper (optional) | `tools/openburnbar-mcp/` | Read-only SQLite bridge for MCP clients |

Canonical architecture: [docs/OPENBURNBAR_RELEASE_ARCHITECTURE.md](docs/OPENBURNBAR_RELEASE_ARCHITECTURE.md).  
Support tiers (core vs experimental vs quarantined tests): [README.md](README.md) and [AgentLensTests/README.md](AgentLensTests/README.md).

**AI coding agents** (Cursor, Claude Code, Codex, etc.): read **[AGENTS.md](AGENTS.md)** first — completion standard, testing and documentation expectations, and scope discipline. **[CLAUDE.md](CLAUDE.md)** mirrors the same bar for tools that prefer that filename.

## Project structure (app)

```
AgentLens/
  App/                          App entry point, menu bar setup (LSUIElement)
  Models/                       Data models (AgentProvider enum, TokenUsage, summaries)
  Services/
    DataStore.swift             GRDB-backed persistence
    UsageAggregator.swift       Orchestrates parsers, stores results
    SettingsManager.swift       User preferences
    LogParser/
      LogParserProtocol.swift   LogParser protocol (provider + parse())
      ClaudeCodeParser.swift    Claude Code ~/.claude/projects/*.jsonl
      FactoryDroidParser.swift  Factory/Droid ~/.factory/sessions/*.jsonl
      KimiParser.swift          Kimi ~/.kimi/sessions/*.jsonl
      UsageAggregatorParsers.swift  Extra log parsers (Copilot, Aider, Cursor, Codex, ModelFilter, …)
      ArtifactDiscoveryService.swift  Skill/agent doc discovery + projection queue
  Theme/
    DesignSystem.swift          Color, typography, spacing, radius, animation tokens
    ProviderTheme.swift         Per-provider color mappings
    ThemeManager.swift          Theme state management
  Views/
    Dashboard/                  Main dashboard, per-provider detail, session detail
    Popover/                    Menu bar popover view
    Settings/                   Settings panel
```

## Build and tests

- **Xcode project** is generated from **`project.yml`** (XcodeGen). After editing `project.yml`, run `xcodegen generate` if you maintain `OpenBurnBar.xcodeproj` locally.
- **Swift packages**: `swift test --package-path OpenBurnBarCore`, `swift test --package-path OpenBurnBarDaemon`.
- **App tests**: `./scripts/test-openburnbar-app.sh` runs **`OpenBurnBarTests` only** — the target compiles `AgentLensTests/Active/**` plus `AgentLensTests/Support/**`; anything under `AgentLensTests/Quarantine/**` is archival until fixed and moved back to `Active/`.

### Stale Xcode caches after shared-core migrations

After large `OpenBurnBarCore` migrations (new public types, fields, or
provider/account contracts), Xcode and SwiftPM occasionally hold stale
binary artifacts that surface as ghost errors like *"value of type 'X' has
no member 'Y'"* or XCFramework symbol mismatches between the macOS and
iOS targets. If the on-disk source clearly defines the missing member but
the build keeps failing, run:

```sh
./scripts/clear-xcode-caches.sh            # full reset (DerivedData + SwiftPM + device support)
./scripts/clear-xcode-caches.sh --dry-run  # preview the plan first
./scripts/clear-xcode-caches.sh --derived-only
./scripts/clear-xcode-caches.sh --packages
./scripts/clear-xcode-caches.sh --xcframeworks
```

Every cache the script touches is recreated by Xcode on the next build;
the operation is safe and idempotent.

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

## How to Test (manual)

1. Build and run the app
2. Open Settings (gear icon in the popover)
3. Verify provider log paths are correct for your machine
4. Click the refresh button to scan
5. Check the dashboard for parsed sessions and cost totals
