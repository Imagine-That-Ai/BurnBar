# Linux Exact-Thread Chat Authority

This document defines the first daemon-authoritative Linux chat-history slice.
It closes synthetic production transcript history and exact-thread persistence;
it does not claim complete `LNX-CHAT-001` parity.

## Ownership

- `openburnbar.sqlite` remains the canonical local database on macOS and Linux.
- The daemon owns Linux chat reads and appends. The WebView never opens SQLite.
- `chat_threads` and `chat_messages` retain the macOS schema and timestamp
  representation. Existing macOS-created rows remain readable.
- SQLCipher key application happens before schema inspection or data access.
- Tauri exposes three narrow commands and forwards them to typed daemon RPCs.

## RPC contract

| Method | Purpose | Bound |
|---|---|---|
| `daemon.chat.thread.list` | List real non-empty threads, optionally searching stored message content | 1-100 threads; 512 UTF-8 query bytes |
| `daemon.chat.thread.get` | Read the exact requested thread in chronological order, or page older rows with a stable `(beforeTimestamp, beforeMessageID)` cursor | 1-500 messages per page; 2 MiB aggregate response content |
| `daemon.chat.message.append` | Append one caller-identified user, assistant, or system message | 48 KiB content; 256-byte thread/message IDs |

All timestamps cross IPC as UTC ISO 8601 strings. The daemon accepts the SQLite
date encodings already produced by GRDB and normalizes responses. Unknown roles,
invalid dates, oversized rows, schema drift, and corrupt data fail closed.

## Persistence invariants

1. A caller generates the thread and message UUIDs before persistence.
2. The user message commits before the gateway stream begins.
3. A non-empty assistant message commits only after successful stream completion.
4. Abort and error paths never persist an assistant completion.
5. Retrying an identical message ID is idempotent. Reusing it for different
   content, role, timestamp, backend, or thread returns a conflict.
6. A thread upsert and its message insert share one `BEGIN IMMEDIATE`
   transaction. Existing messages are never overwritten.
7. Thread search is derived from stored content, not usage or session metadata.
8. Synthetic transcript generation is available only in explicit fixture mode.
9. Long threads expose `hasMoreBefore` and the renderer loads older durable pages
   with the oldest loaded row as a deterministic cursor; no history is silently
   discarded at the per-response bound.

The renderer validates all daemon results again at the WebView boundary,
including bounded UTF-8 sizes, exact roles, canonical timestamps, same-thread
membership, and append-response identity.

## Failure behavior

- Missing database configuration returns RPC `unavailable`; the renderer does
  not silently substitute usage rows.
- Lock contention returns `unavailable` after a five-second SQLite busy timeout.
- An unknown thread returns an empty result with no invented summary.
- A failed ancillary summary refresh does not undo a committed turn or expose
  arbitrary error detail to renderer logs.
- Secure UUID generation is required for persistent IDs. The renderer fails
  instead of falling back to weak randomness.

## Remaining parity work

`LNX-CHAT-001` remains open for the shared provider/model catalog, full backend
breadth, attachment persistence and content policy, citations, tool approvals,
options, resume/export, reconnect reconciliation, and a Linux-native secondary
window/pop-out. `LNX-SESS-001` also remains open: activity/session transcripts
are a separate domain and must not be synthesized from chat or usage data.

## Verification

Run the focused contract and encrypted-database tests:

```bash
swift test --package-path OpenBurnBarCore --filter BurnBarChatThreadContractsTests
OPENBURNBAR_SKIP_CORE_SWIFT_TESTS=1 \
  OPENBURNBAR_DAEMON_SWIFT_FILTER=BurnBarChatThreadServiceTests \
  ./scripts/test-openburnbar-swift.sh
```

Run the Linux bridge, store, UI, and Rust contract suites:

```bash
cd apps/linux-desktop
npx tsc --noEmit
npm test
npm run build
cd src-tauri
cargo test --lib
```

Installed QA must additionally prove search, exact thread selection, new-thread
creation, restart recovery, duplicate retry, conflict rejection, cancellation,
gateway failure, locked/encrypted database handling, keyboard navigation, and
screen-reader announcements against the packaged daemon and WebView.
