# Windows project-code memory store evidence

**Date:** 2026-07-13
**Lane:** F2 Pensieve watcher + project-code memory store

Ledger row: f2-project-code-memory-store

## What this proves

The Windows project-code watcher has a live durable metadata store with restart
hydration and bounded reference/call-edge persistence. It does not persist
source text.

## What is implemented

- `ProjectCodeMemoryStore` opens a local SQLite database through the same
  provider initialization seam as the Windows SQLCipher storage layer. The app
  passes its protected storage passphrase so metadata is encrypted at rest.
- The schema mirrors the macOS project-code metadata contract: project identity,
  file manifest, artifacts, symbols, references, call edges, and index
  checkpoints.
- Index refresh is atomic. A completed watcher/parser pass replaces the
  project rows in one transaction, records parser mode/truncation, and keeps
  SHA-1 Git-blob and SHA-256 content hashes for every readable artifact.
- A restart loads the durable checkpoint and symbols before falling back to the
  legacy JSON metadata file. `code.status` reports durable-store availability
  and bounded artifact/symbol/reference/call-edge/storage counters. The
  companion plane exposes bounded `code.call_graph` traversal (depth 1-3).
- Only metadata and hashes are persisted. Source is read transiently during
  reference extraction and is never inserted into the SQLite database.
- The app composes the store by default at
  `%LOCALAPPDATA%\\OpenBurnBar\\project-code-memory.sqlite`; deployments can
  override it with `OPENBURNBAR_PROJECT_MEMORY_PATH`.

## Validation

```text
dotnet test windows/tests/presentation/OpenBurnBar.App.Presentation.Tests.csproj --no-restore
```

Result: **757 passed, 0 failed, 0 skipped**.

The durable-store test proves two-file artifact/index persistence, lexical
reference and call-edge persistence, bounded call-graph traversal, checkpoint
restart hydration, and absence of source text in the database bytes. The
companion managed-runtime suite covers the new operation routing.

## Boundary

This evidence promotes the Windows watcher + durable metadata-store trigger. It
does not claim full semantic chunk/embedding parity with the macOS daemon,
live LSP-host evidence, physical Windows performance/accessibility, staging
cloud flows, advanced Computer Use/media safety, or Store/update certification.
