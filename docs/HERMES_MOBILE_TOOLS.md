# OpenBurnBar Mobile Tool Catalog

This is the authoring guide for the iOS-side **`MobileToolCatalog`** — the
set of tools the Hermes and Pi chat surfaces advertise to the upstream
LLM. Tool calls produced by the model are executed on-device, the
results are folded into the conversation as `role: "tool"` reply
messages, and a follow-up streaming turn is fired so the model can
deliver a natural-language answer that references the result.

The wire format is the OpenAI `/v1/chat/completions` `tools` /
`tool_calls` shape. Catalog descriptors are emitted verbatim in the
`tools` array, and the model's streamed `tool_calls[]` are parsed by
`HermesService` / `PiService` into the existing `HermesToolCall` /
`PiToolCall` records that the chat bubbles already render as pills.

## Where the moving parts live

| Path | Role |
| --- | --- |
| `OpenBurnBarMobile/Services/Tools/MobileToolCatalog.swift` | Protocol, registry, executor, result + error types, JSON Schema helpers. |
| `OpenBurnBarMobile/Services/Tools/BurnBarAtomOpenTool.swift` | `burnbar_atom_open` — navigate the iOS app to any BurnBar surface. |
| `OpenBurnBarMobile/Services/Tools/BurnBarHermesSessionsTool.swift` | `burnbar_hermes_sessions` — list recent assistant sessions on this device. |
| `OpenBurnBarMobile/Services/Tools/BurnBarRuntimeStatusTool.swift` | `burnbar_runtime_status` — honest snapshot of the active runtime + model. |
| `OpenBurnBarMobile/Services/HermesService.swift` | Advertises the catalog, parses tool_call deltas, and runs the multi-turn loop. |
| `OpenBurnBarMobile/Services/PiService.swift` | Sibling of Hermes; same catalog, same loop. |
| `OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/HermesAttachmentEncoder.swift` | Emits the wire-format `tool_calls` / `tool` messages on subsequent turns. |
| `OpenBurnBarMobileTests/Tools/` | Catalog + executor + Hermes loop tests. |

## Authoring a new tool — five steps

1. **Write a struct that conforms to `MobileTool`.** The protocol is
   `@MainActor` and `Sendable`. Tools are value types with no mutable
   state — they read from the `MobileToolContext` passed into
   `execute(...)`.

   ```swift
   @MainActor
   public struct BurnBarStreaksTool: MobileTool {
       public init() {}

       public static let name = "burnbar_streaks"
       public var displayName: String { "Show streaks" }
       public var description: String {
           "Return the user's current usage streak (consecutive days)."
       }
       public var parametersSchema: [String: Any] {
           MobileToolJSONSchema.object(
               properties: [:],
               required: [],
               description: "No arguments."
           )
       }

       public func execute(
           arguments: String,
           context: any MobileToolContext
       ) async throws -> String {
           // …read from context, build a JSON body, return it.
       }
   }
   ```

2. **Pick a name with the `burnbar_` prefix.** Tools registered by
   on-device code must not collide with anything the upstream Hermes
   server may inject. Names use `lower_snake_case` and stay stable —
   they're part of the catalog's wire contract.

3. **Describe the tool in prose.** The `description` is what the model
   sees in the upstream `function.description`. Be specific about
   *when* to call (and when *not* to call). Models that ship tools
   under-described over-fire them.

4. **Lock down the schema.** Use the `MobileToolJSONSchema` helpers so
   every tool's `parameters` looks consistent:
   ```swift
   MobileToolJSONSchema.object(
       properties: [
           "limit": MobileToolJSONSchema.integer(description: "...", minimum: 1, maximum: 50),
           "query": MobileToolJSONSchema.string(description: "...")
       ],
       required: ["limit"]
   )
   ```
   `additionalProperties` defaults to `false` so the model can't drift
   into invented arguments.

5. **Register it.** Add an instance to `MobileToolCatalog.default.tools`
   in `MobileToolCatalog.swift`. Order matches the wire array exactly
   — keep the catalog deterministic so logs / tests stay diffable.

## Return values

`execute(...)` returns a `String` body. Convention is **compact JSON**:

```swift
let payload: [String: Any] = [
    "opened": true,
    "atom_url": HermesAtomURL.encode(atom).absoluteString
]
let data = try JSONSerialization.data(withJSONObject: payload, options: [])
return String(data: data, encoding: .utf8) ?? "{}"
```

The executor wraps the body in
`MobileToolExecutionResult.truncatedForWire(_:)` so a single tool can
never blow through the model's context window. The 16 KB ceiling is
defined by `MobileToolExecutionResult.maxContentBytes`.

## Errors

Throw `MobileToolError` from inside `execute(...)`. The executor
catches it and emits a structured `{"error": "..."}` body so the model
can recover with a follow-up call.

| Case | Use it when… |
| --- | --- |
| `.invalidArguments(message)` | The streamed JSON didn't parse, or a required key is missing. |
| `.toolDisabled(name)` | The tool needs runtime state that isn't installed (e.g. no navigator). |
| `.executionFailed(message)` | The tool ran but couldn't fulfil the request — pass enough context for the model to pivot. |
| `.unknownTool(name)` | Reserved for the executor itself; tools won't raise this. |

Helpers like `stringArgument("foo", in: arguments)` on the `MobileTool`
protocol throw `.invalidArguments` for malformed bodies and return
`nil` (not error) when an optional key is absent.

## The multi-turn loop

The loop lives in `HermesService.runToolUseIterationIfNeeded(...)`
(Hermes) and `PiService.runStreamingLoop(...)` (Pi). At each upstream
turn:

1. The streaming response is parsed for `delta.tool_calls`.
2. Once the stream finishes, if `assistant.toolCalls` is non-empty:
   - Each call is executed via `MobileToolExecutor`.
   - The pill's `status` is updated to `"done"` (success) or
     `"failed"` (error).
   - A `role: .tool` message is appended to `messages` carrying the
     `tool_call_id` and the result body.
3. The service re-enters the streaming flow with the updated message
   history; the encoder serializes the prior assistant turn with its
   `tool_calls[]` array and the matching tool reply so the upstream
   API can pair them.
4. The loop stops when either:
   - The assistant turn produces no tool calls (final answer reached), or
   - `maxToolUseIterations` (5) is exhausted.

Tool reply messages are filtered out of the visible chat list
(`visibleMessages` in `HermesChatView` / `PiChatThreadView`) and are
**not** persisted to `MobileChatHistoryStore`. They're context for the
upstream model, not chat history the user reads.

## Wiring a navigator (for `burnbar_atom_open`)

The atom tool calls `context.atomNavigator?.open(atom)`. The chat view
installs the navigator on appear so the tool can drive the same
detail-sheet flow that an in-chat atom chip tap uses:

```swift
.onAppear {
    service.setToolAtomNavigator(atomRouter)
}
.onDisappear {
    service.setToolAtomNavigator(nil)
}
```

The service holds the navigator weakly so the chat view's lifetime
isn't extended.

## Testing

Tests live in `OpenBurnBarMobileTests/Tools/`:

- `MobileToolCatalogTests` — catalog + executor + JSON Schema helpers.
- `BurnBarAtomOpenToolTests` — atom tool round-trip + error paths.
- `HermesServiceToolUseLoopTests` — full multi-turn loop against a
  scripted SSE relay. The fake transport returns one event script per
  iteration, so tests assert both the navigation effect and the wire
  payload of the follow-up turn.

When you add a tool, mirror these three coverage axes (descriptor,
execution, integration) for it.
