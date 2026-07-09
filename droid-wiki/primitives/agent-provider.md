# Agent provider

The `AgentProvider` enum defines every AI coding agent that OpenBurnBar can track.

## Purpose

Centralize metadata about supported agents so parsers, UI, and cost calculations can reference a single source of truth.

## Key abstractions

| Property | Type | Description |
|----------|------|-------------|
| `iconName` | `String` | SF Symbol name for the provider icon |
| `displayName` | `String` | Human-readable name |
| `logDirectory` | `String?` | Default log directory path (e.g., `~/.claude/projects`) |
| `filePattern` | `String?` | Glob pattern for session files (e.g., `*.jsonl`) |

## Supported agents

| Provider | Source directory | Confidence |
|----------|-----------------|------------|
| Claude Code | `~/.claude/projects/*.jsonl` | Exact |
| Factory Droid | `~/.factory/sessions/*.jsonl` | Exact |
| Junie (JetBrains) | `~/.junie/sessions/<id>/events.jsonl` + `index.jsonl` | Exact |
| Codex | `~/.codex/state_5.sqlite` + rollout JSONL | Estimated |
| Kimi | `~/.kimi/sessions/*.jsonl` | Estimated |
| Cursor | Cursor BYOK + local router | Exact |
| Gemini CLI | `~/.gemini/sessions/*.jsonl` | Estimated |
| Goose | `~/.goose/sessions/*.jsonl` | Estimated |
| Grok Build | `~/.grok/sessions/*.jsonl` | Estimated |
| Warp | `~/.warp/sessions/*.jsonl` | Estimated |
| Windsurf | `~/.windsurf/sessions/*.jsonl` | Estimated |
| Forge | `~/.forge/sessions/*.jsonl` | Estimated |
| Augment | `~/.augment/sessions/*.jsonl` | Estimated |
| Antigravity/Z.ai | Via Factory sessions | Estimated |
| Cline | `~/.cline/sessions/*.jsonl` | Estimated |
| Copilot | Planned | — |
| Aider | Planned | — |

## Adding a new provider

1. Add a case to the canonical `AgentProvider` enum in `OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/AgentProvider.swift` (set `bundledLogoName`, `iconName`, and membership in `swarmGlyphProviders` — test-enforced to cover `allCases`).
2. Set `logDirectory`, `filePattern`, `supportLevel`, and `dataConfidence` in the Mac-only extension `AgentLens/Models/AgentProvider.swift`.
3. Add brand colors to `DesignSystemColors.primary/accent(for:)` (`ThemePrimitives.swift`), the Mac duplicate in `AgentLens/Theme/DesignSystem.swift`, and `SwarmColorDriver.swift`.
4. Implement the `LogParser` protocol in `AgentLens/Services/LogParser/`.
5. Register the parser in `ParserRegistry.defaultParsers()` (`AgentLens/Services/UsageAggregation/ParserRegistry.swift`).
6. Add a `<Name>Logo.imageset` to `AgentLens/Resources/Assets.xcassets` and `OpenBurnBarMobile/Resources/Assets.xcassets`.
7. Add the provider to `all_known` in `tools/openburnbar-mcp/eligible_providers.json` (and `native_eligible` only if the daemon can natively resume its sessions).
8. Add tests in `AgentLensTests/Active/Parsers/` (inline temp-dir fixtures) and verify the provider-enumerating suites (`ProviderLogoViewTests`, `SwarmLogoShapeTests`, `CLIAgentEligibleProviderParityTests`).
9. If the agent is also a launchable CLI/chat runtime, add cases to `AssistantRuntimeID`, `CLIAgentRuntime`, `ChatBackendID`, and `SwitcherCLIProfileType`, then follow the compiler through the exhaustive switches.

## Related pages

- [Usage tracking](../features/usage-tracking.md)
- [macOS app](../apps/macos-app/index.md)
