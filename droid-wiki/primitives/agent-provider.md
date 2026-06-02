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

1. Add a case to `AgentProvider` in `AgentLens/Models/AgentProvider.swift`.
2. Set `iconName`, `displayName`, `logDirectory`, and `filePattern`.
3. Implement `LogParser` protocol in `AgentLens/Services/LogParser/`.
4. Register the parser in `UsageAggregator`.
5. Add tests in `AgentLensTests/Active/`.

## Related pages

- [Usage tracking](../features/usage-tracking.md)
- [macOS app](../apps/macos-app/index.md)
