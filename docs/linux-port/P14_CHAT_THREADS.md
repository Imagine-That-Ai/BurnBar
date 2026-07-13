# P-14 Linux Chat Threads

## Scope

This slice brings Linux chat history onto the macOS data contract. The daemon
is the only process that reads or writes the encrypted chat database; the
renderer receives bounded, typed results through Tauri and daemon RPC.

## Difference

Before this slice, Linux production chat history was derived from usage/session
rows and could show synthetic transcript content. macOS owns durable
`chat_threads` and `chat_messages` records, preserves caller-generated thread
and message identity, and restores exact history after restart. Linux now reads
the same schema and supports exact-thread search, chronological history, and
older-page retrieval. The remaining macOS chat surface is still broader: Linux
does not yet provide the complete provider/model catalog, attachment storage,
citations, approval controls, export/resume depth, or a secondary chat window.

## Why It Matters

Users need to trust that a selected conversation is the conversation they
created, not an approximation assembled from unrelated usage events. Durable
identity also makes retries safe, allows interrupted streams to recover without
inventing assistant text, and gives support tooling a deterministic audit trail.
Reading through the daemon keeps SQLCipher keys and schema details out of the
WebView and gives the same failure boundary as the macOS app.

## Recommended Solution

1. Keep `BurnBarChatThreadContracts` and `BurnBarRPCMethod` as the shared source
   of truth for list, get, and append requests/responses.
2. Use `BurnBarChatThreadService` for bounded SQLCipher reads and transactional,
   idempotent appends. Reject malformed identifiers, roles, dates, schema, and
   oversized content rather than falling back to synthetic history.
3. Expose only narrow Tauri commands. Translate the stable `(timestamp,
   messageID)` cursor for older pages and validate every response again in the
   renderer bridge.
4. Persist the user turn before starting a gateway stream and persist a
   non-empty assistant turn only after successful completion. Abort/error paths
   must leave no durable assistant completion.
5. Finish the remaining chat capabilities in follow-up packets: shared
   provider/model breadth, attachments, citations, approvals, options,
   export/resume, reconnect reconciliation, and a Linux-native pop-out pane.

**Priority:** High. Exact history is a prerequisite for a trustworthy chat
experience, but the feature is not by itself a full-parity release gate.

## Implementation Notes

- RPC methods: `daemon.chat.thread.list`, `daemon.chat.thread.get`, and
  `daemon.chat.message.append`.
- List is bounded to 1–100 threads and searches stored message content.
- Get is bounded to 1–500 messages and a 2 MiB aggregate response; it returns
  `hasMoreBefore` when an older page exists.
- Append limits content to 48 KiB and IDs to 256 bytes. The caller supplies a
  secure UUID and retries are idempotent; reusing an ID with changed fields is
  a conflict.
- SQLCipher key setup and schema checks happen before any query. Busy locks,
  missing configuration, corrupt rows, unknown roles, and schema drift return
  an explicit unavailable/corrupt error.
- Fixture transcripts remain available only in explicit fixture mode. They are
  never used to mask a missing live daemon/database.
- No transcript body export RPC exists yet; the Linux UI must keep export
  disabled rather than fabricate an export from snippets.

## QA Verification

### Automated

```bash
swift test --package-path OpenBurnBarCore --filter BurnBarChatThreadContractsTests
swift test --package-path OpenBurnBarDaemon --filter BurnBarChatThreadServiceTests
cd apps/linux-desktop
npx vitest run src/state/chatStore.test.ts src/bridgeRpcBehavior.test.ts \
  src/tauriBridge.test.ts src/surfaces/chat/ChatSurface.test.tsx --reporter=dot
npx tsc --noEmit
npm run build
cd src-tauri
cargo fmt -- --check
cargo test --lib
```

The focused suite must cover stable wire keys, real stored-content search,
chronological exact-thread reads, cursor pagination, idempotent duplicate
retries, conflict rejection, transaction rollback, response bounds, schema
failure, locked database handling, secure-ID failure, user-before-stream
ordering, and no assistant append on abort/error.

### Installed/manual

Against a packaged daemon and WebView, verify: create a thread, restart the
app, search and select an existing thread, load older pages repeatedly, retry a
message after a transport failure, cancel a stream, recover after daemon
restart, and exercise keyboard navigation plus Orca/AT-SPI announcements.
Confirm that missing/locked databases show an explicit unavailable state and
never display usage-derived or synthetic transcript rows. Record the package,
architecture, compositor, keyring, and daemon build receipt for each supported
Linux environment.

