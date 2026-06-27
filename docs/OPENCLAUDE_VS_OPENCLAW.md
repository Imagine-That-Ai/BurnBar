# OpenClaude vs OpenClaw — two different products

OpenBurnBar supports **two separate, unrelated providers** whose names look alike.
They were briefly conflated in the codebase; this note exists so they never are again.

| | **OpenClaw** | **OpenClaude** |
|---|---|---|
| Repo | `github.com/openclaw/openclaw` | `github.com/Gitlawb/openclaude` |
| What it is | A personal **AI-assistant platform** (WhatsApp / Telegram / Slack / iMessage / ~20 channels) built in TypeScript | A **coding-agent CLI** — an open fork of Claude Code |
| CLI binary | `openclaw` (`openclaw gateway`, `openclaw onboard`) | `openclaude` |
| How BurnBar talks to it | **Gateway** — OpenAI-compatible HTTP at `127.0.0.1:18789` (`chatOpenClaw` → `OpenAICompatibleChatGatewayClient`) | **Spawned CLI** — runs the `openclaude` binary, Claude-Code protocol (`-p --output-format stream-json --model`), reusing the Claude process runner |
| Enum identity | `AgentProvider.openClaw` / `AssistantRuntimeID.openClaw` / `ChatBackendID.openclaw` / `CLIAgentRuntime.openClaw` | `…​.openClaude` (each with wire token `"openclaude"`) |
| Wire token | `"openclaw"` | `"openclaude"` |
| Logo | `OpenClawLogo` | `OpenClaudeLogo` (terracotta git-fork mark — it's a Claude *fork*) |
| Quota | `.unavailable` stub → `github.com/openclaw` | `.unavailable` stub → `github.com/Gitlawb/openclaude` |

## The bug this fixed

The `.openClaw` provider's **interactive launcher and mission planner used to spawn the
`openclaude` binary** with Claude-Code flags (`InteractiveTerminalLauncher`,
`CLIAgentMissionRequestListener+Planner`, `parseOpenClaude`) — i.e. OpenClaw's identity
(logo / gateway / quota URL `github.com/openclaw`) sat on top of OpenClaude's binary.

The split:
- **OpenClaude (new provider)** inherited the spawned-`openclaude` machinery: the
  interactive launcher (`openclaude --model`), the Claude-Code-style direct-launch mission
  block (reassigned from `ChatBackendID.openclaw.rawValue` → `ChatBackendID.openClaude.rawValue`),
  and the desktop chat stream `CLIBridge.chatOpenClaudeStream` (reuses `runClaude` since
  OpenClaude is Claude-protocol-compatible).
- **OpenClaw** keeps its real identity: its interactive launcher now runs the **`openclaw`**
  binary, and its chat stays on the OpenAI-compatible gateway (`:18789`). It no longer has a
  direct-CLI mission spawn (it's a gateway provider).

## Invariants (don't break these)

- `"openclaw"` and `"openclaude"` are **distinct stable wire tokens** persisted in
  UserDefaults / Firestore / relay URIs / Android DataStore. Renaming either is a migration.
  Locked by `OpenBurnBarCoreTests/OpenClaudeProviderTests` and `Plan2SharedModelsTests`.
- On **desktop**, OpenClaude behaves like the other spawned coding-CLIs
  (Codex / Claude / Droid / Forge / Cursor Agent): `.supported` / `.exact` usage parsing,
  logs at `~/.openclaude/sessions`, its own `chatModelOpenClaude` selection.
- On **mobile**, OpenClaude is a Mac-bridged CLI runtime (grouped with the CLI agents),
  whereas OpenClaw has its own mobile gateway discovery service (`OpenClawService`).

## Adding the next provider

A new `AgentProvider` / `ChatBackendID` / `AssistantRuntimeID` / `CLIAgentRuntime` case is
**compiler-enforced** across ~40–50 exhaustive switches. Add the enum case (with a stable
lowercased wire token), then follow the build errors. Spawned coding-CLIs should mirror
`cursorAgent`; gateway providers should mirror `openClaw` / `hermes`.
