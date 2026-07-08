# P04 — Chat / Hermes, tool cards, thinking view

**Wave 2 (after P01 establishes the polling/refresh idiom) · Route: `chat`.**

## Mission

The flagship surface: Hermes chat with streamed assistant output, tool-call cards with approval controls, thinking/reasoning disclosure, model strip, and thread history. First streamed token must record the `chat.firstToken.progress` perf sample through the existing bridge measurement (do not add a second sample with the same name).

## Read first

- README §1–§2 — especially the bridge-extension recipe.
- macOS oracle (large; read in this order): `AgentLens/Views/Chat/ChatPanel.swift`, `Components/ChatMessagesStream.swift`, `Components/ChatInputRow.swift`, `HermesToolCard.swift`, `HermesThinkingView.swift`, `HermesAtomComponents.swift`, `Components/HermesModelStrip.swift`, `Components/ChatHistoryRow.swift`, `ChatSessionController.swift` (state machine semantics).
- Prior evidence gap: `docs/linux-port/evidence/mission-001-provider-hermes/hermes-chat-live-proof.md` — the shell currently proves navigation only; this packet closes send→stream→render.
- Daemon: chat/Hermes RPC in `BurnBarDaemonServer+RPCClient.swift` and observability in `+RPCObservability.swift`.

## Data contract

1. Streaming over the AF_UNIX envelope: the Tauri side must forward stream events to the webview via `tauri::Emitter` events (`hermes://message-delta`, `hermes://tool-call`, `hermes://done`) — one Rust command `chat_send` starts the stream; the TS side subscribes with `@tauri-apps/api/event.listen`.
2. Message model: `{ id, role: 'user'|'assistant'|'tool', text, thinking?: string, toolCall?: { name, argsSummary, state: 'proposed'|'approved'|'denied'|'done', resultSummary? } }`.
3. Tool approvals round-trip through a `chat_tool_decision` command; the UI never auto-approves.
4. Fixture: a deterministic scripted stream (user → thinking → tool call → approval → result → assistant done) so all card states render without a daemon.
5. Offline: input disabled with honest copy; history (if cached) still readable.

## Files

- Create: `src/state/chatStore.ts` (threads, active stream reducer, approval actions); `src/surfaces/chat/` (`ChatSurface.tsx`, `MessageList.tsx`, `MessageBubble.tsx`, `ToolCard.tsx`, `ThinkingDisclosure.tsx`, `ModelStrip.tsx`, `ChatInput.tsx`, `HistoryList.tsx`); tests alongside.
- Modify: `SurfaceRouter.tsx` one line; `tauriBridge.ts` + `lib.rs` appends.
- Append: `app.css` `/* ---- P04 chat ---- */`.

## Build steps

1. Store first, UI second: reducer handling `delta/tool/done/error` events with an exhaustive switch; unit-test it with the fixture script before writing any component.
2. `MessageList`: newest at bottom, auto-scroll only when the user is already at bottom (track via scroll position, not a boolean flag reset).
3. `ToolCard`: name + args summary, Approve/Deny buttons (`.primary`/`.ghost`), state badge; approved/denied/done states collapse to a compact receipt row.
4. `ThinkingDisclosure`: collapsed by default, `aria-expanded` toggle, monospace body, never announced as live text.
5. `ChatInput`: textarea + send button; Enter submits, Shift+Enter newline — handlers on the textarea element only.
6. Streaming text renders as plain text v1 (markdown is a named follow-up; see master plan §5.2 pretext decision). No `dangerouslySetInnerHTML`, ever.

## Required states

Populated stream / Loading (waiting-for-first-token shimmer, reduced-motion safe) / Empty thread ("Start a conversation…") / Error (stream aborted banner + retry keeps partial transcript) / Offline (disabled input + `OfflineNotice`); plus tool-card sub-states (proposed/approved/denied/done).

## A11y / Perf / Tests

- New assistant messages announced via a single `aria-live="polite"` region that batches deltas (announce on `done` or sentence boundary, not per token).
- 60fps target while streaming: append deltas via store batching (`requestAnimationFrame`-coalesced or 50ms buffer); do not re-render the whole list per delta (memoized rows keyed by id).
- Tests: stream reducer (every event order permutation the fixture covers), approval round-trip, auto-scroll guard, disabled offline input, all five states.

## Done / Forbidden

README §4 + `chat.firstToken.progress` still recorded exactly once per boot/route (existing bridge path). Forbidden: `dangerouslySetInnerHTML`; auto-approving tools; per-token DOM writes without batching; inventing RPC method names.
