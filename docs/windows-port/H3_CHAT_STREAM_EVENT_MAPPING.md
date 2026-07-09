# H3 — Mac CLIBridge → Windows `ChatStreamEvent` mapping

**Phase:** H3 Chat F1 (authoring table; production driver lands after H2 ConPTY proof)  
**Mac source:** `AgentLens/Services/CLIBridge/CLIBridgeTypes.swift` — `CLIChatStreamEvent`  
**Windows consumer:** `windows/app/OpenBurnBar.App.Presentation/Chat/ChatStreamEvent.cs`  
**State machine:** `ChatSessionStateMachine` (`windows/app/OpenBurnBar.App.Presentation/Chat/`)

This table is the contract for a production `IChatStreamDriver` that adapts CLI
`stream-json` (and Hermes-compatible) backends into the portable chat surface.
ConPTY alone does **not** make `nav-chat` Real — events must reach
`ChatSurfaceViewModel` through this mapping.

## Event mapping

| Mac `CLIChatStreamEvent` | Windows `ChatStreamEvent` | Notes |
|---|---|---|
| `.text(String)` | `ChatStreamEvent.Text(Chunk)` | Token/delta append to assistant bubble |
| `.reasoning(String)` | `ChatStreamEvent.Reasoning(Chunk)` | Thinking/reasoning lane; may be collapsed in UI |
| `.refusal(String)` | `ChatStreamEvent.Refusal(Chunk)` | Safety/refusal surface |
| `.toolUse(name:detail:)` | `ChatStreamEvent.ToolUse(Name, Detail)` | Tool call start; detail = args delta/summary |
| `.toolResult(name:detail:)` | `ChatStreamEvent.ToolResult(Name, Detail)` | Tool completion payload |
| `.usage(CLIUsageSnapshot)` | `ChatStreamEvent.Usage(CliUsageSnapshot)` | Token rollup; machine merges successive totals |

## Usage snapshot fields

| Mac `CLIUsageSnapshot` | Windows `CliUsageSnapshot` |
|---|---|
| `inputTokens` | `InputTokens` |
| `outputTokens` | `OutputTokens` |
| `cacheCreationTokens` | `CacheCreationTokens` |
| `cacheReadTokens` | `CacheReadTokens` |
| `reasoningTokens` | `ReasoningTokens` |
| (derived) total | `TotalTokens` = input + output |

## Hermes / gateway intermediate (Mac)

Mac maps `HermesStreamEvent` → `CLIChatStreamEvent` in `CLIChatStreamEvent.init?(_ event: HermesStreamEvent)`:

| Hermes event | CLIChatStreamEvent |
|---|---|
| `.messageChunk` | `.text` |
| `.reasoningChunk` | `.reasoning` |
| `.refusalChunk` | `.refusal` |
| `.toolCallChunk` / `.toolCallFinished` | `.toolUse` |
| `.toolResult` | `.toolResult` |
| `.messageStop` (with usage) | `.usage` |
| `.longToolHint`, `.notice` | **dropped** (`nil`) |

Windows F1 drivers should either:

1. Parse CLI `stream-json` directly into `ChatStreamEvent`, or  
2. Parse Hermes-compatible events through an equivalent drop table before the state machine.

## Terminal / control outcomes (not stream events)

| Concept | Mac | Windows |
|---|---|---|
| Stream completed | settle outcome completed | `ChatStreamSettleOutcome.CompletedOutcome` |
| Stream failed | settle failed | `ChatStreamSettleOutcome.Failed(cancelled:)` |
| User cancel | cancelled flag | `Failed(cancelled: true)` + phase `Cancelled` |

## Production composition (target)

| Mode | Driver | Allowed when |
|---|---|---|
| Production, CLI configured | future `CliJsonChatStreamDriver` (H3) | Host has ConPTY/process + backend path |
| Production, unconfigured | `UnavailableChatStreamDriver` | Default today — honest guidance text |
| Sample / demo | `ScriptedChatStreamDriver` | `OPENBURNBAR_SAMPLE_MODE=1` only |

## Out of scope for F1 chat

- Full Hermes/Pi **local HTTP gateway** as product (F2 / WPD-0006 revive)
- Claiming `nav-chat` **Real** from ConPTY harness alone
- Scripted demo as production default

## Related tests

- `windows/tests/presentation/Chat/ChatSessionStateMachineTests.cs`
- `windows/tests/chat/ChatStreamDriverRuntimeTests.cs`
