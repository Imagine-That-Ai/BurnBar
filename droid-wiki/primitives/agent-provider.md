# AgentProvider

Swift enum enumerating every AI provider OpenBurnBar can track. The canonical definition lives in `OpenBurnBarCore`; the macOS app re-exports it with additional Mac-only behaviors.

## Canonical location

```
OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/AgentProvider.swift
```

The macOS app file `AgentLens/Models/AgentProvider.swift` is a `typealias` + extension file. It re-exports the core type and adds `logDirectory`, `filePattern`, and `supportLevel` — macOS-only behaviors that the iOS target does not need.

## Each case carries

| Property | Type | Description |
|---|---|---|
| `rawValue` | `String` | Stable Codable key used in JSON-RPC, Firestore, and database |
| `displayName` | `String` | Human-readable label shown in UI |
| `iconName` | `String` | SF Symbol name for the provider icon |
| `bundledLogoName` | `String` | Asset catalog name for bundled provider logo (macOS) |
| `logDirectory` | `String` | Filesystem path (with `~` prefix) where the provider writes session logs (macOS only) |
| `filePattern` | `String` | Glob matched against `logDirectory` to discover session files (macOS only) |

## Known cases

| Case | Log directory | File pattern |
|---|---|---|
| `.factory` | `~/.factory/sessions` | `*.jsonl` |
| `.claudeCode` | `~/.claude/projects` | `*.jsonl` |
| `.codex` | `~/.codex` | `*.jsonl` |
| `.openCode` | `~/.local/share/opencode` | `*.jsonl` |
| `.cursor` | `~/.cursor/ai-tracking` | varies |
| `.copilot` | `~/.copilot/session-state` | varies |
| `.aider` | `~/.aider` | varies |
| `.cline` | `~/Library/Application Support/Code/…/saoudrizwan.claude-dev/tasks` | varies |
| `.kiloCode` | `~/Library/Application Support/Code/…/kilocode.kilo-code/tasks` | varies |
| `.rooCode` | `~/Library/Application Support/Code/…/rooveterinaryinc.roo-cline/tasks` | varies |
| `.kimi` | `~/.kimi/sessions` | `*.jsonl` |
| `.zai` | `~/.factory/sessions` | `*.jsonl` |
| `.minimax` | `~/.factory/sessions` | `*.jsonl` |
| `.hermes` | `~/.hermes/sessions` | `*.jsonl` |
| `.piAgent` | `~/.pi/sessions` | `*.jsonl` |
| `.forgeDev` | `~/.forge/sessions` | varies |
| `.augment` | `~/Library/Application Support/Code/…/augment.vscode-augment` | varies |
| `.geminiCLI` | `~/.gemini/tmp` | varies |
| `.antigravity` | `~/.gemini/antigravity-cli` | varies |
| `.cursorAgent` | `~/.cursor-agent/sessions` | varies |
| `.goose` | `~/.local/share/goose/sessions` | varies |
| `.openClaw` | `~/.openclaw/sessions` | varies |
| `.ollama` | `~/.ollama/logs` | varies |
| `.windsurf` | `~/Library/Application Support/Windsurf - Next/User/globalStorage` | varies |
| `.warp` | `~/Library/Application Support/dev.warp.Warp-Stable` | varies |
| `.xAI` | `~/.grok/sessions` | varies |
| `.openAI` / `.deepSeek` | `~/.codex` (reused; remote billing, not local logs) | non-matching glob |
| `.mimo` | `~/.codex` (reused; Token Plan API) | non-matching glob |

## Where it's used

- **Parsers** — every `LogParser` subclass returns an `AgentProvider` case from its `provider` property
- **UI** — `DesignSystem.Colors.primary(for:)` maps cases to brand accent colors
- **Routing** — `SwitcherDiscoveryService` uses `logDirectory` to watch for new session files
- **Firestore sync** — `provider.rawValue` is the Firestore `provider` field on `UsageEventDoc`
- **ProviderBrand** — `AgentLens/Models/ProviderBrand.swift` wraps a provider into a display bundle (logo, color, icon) for both the switcher surface and the daemon catalog surface

## ProviderBrand

`ProviderBrand` is a display-layer struct (not an enum) that can be built from an `AgentProvider`, a `BurnBarCatalogProvider`, or a raw provider ID string. It resolves bundled logo assets, accent color, and SF Symbol icon from whichever source is available.
