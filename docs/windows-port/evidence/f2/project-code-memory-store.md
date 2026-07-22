# Windows project-code memory store evidence

**Date:** 2026-07-13
**Lane:** F2 Pensieve watcher + project-code memory store

Ledger row: f2-project-code-memory-store

## What this proves

The Windows project-code watcher has a live durable metadata store with restart
hydration, bounded reference/call-edge persistence, and a versioned semantic
chunk/vector index. It does not persist source text.

## What is implemented

- `ProjectCodeMemoryStore` opens a local SQLite database through the same
  provider initialization seam as the Windows SQLCipher storage layer. The app
  passes its protected storage passphrase so metadata is encrypted at rest.
- The schema mirrors the macOS project-code metadata contract: project identity,
  file manifest, artifacts, symbols, references, call edges, semantic chunks,
  versioned vectors, and index checkpoints.
- Index refresh is atomic. A completed watcher/parser pass replaces the
  project rows in one transaction, records parser mode/truncation, and keeps
  SHA-1 Git-blob and SHA-256 content hashes for every readable artifact.
- A restart loads the durable checkpoint and symbols before falling back to the
  legacy JSON metadata file. `code.status` reports durable-store availability
  and bounded artifact/symbol/reference/call-edge/chunk/vector/storage counters.
  The companion plane exposes bounded `code.call_graph` traversal (depth 1-3)
  and `code.semantic_search` over versioned vectors. Deterministic
  96-dimensional embeddings remain the offline default; the app can select the
  protected OpenAI provider and stores its model-derived dimensions/version
  without mixing vector generations.
- Code is chunked with the macOS 2,400-character / 240-character-overlap
  contract. When Tree-sitter ranges are available, nested symbol spans are
  merged into AST-aware chunks; bounded line-aware slicing covers gaps and
  oversized symbols. The versioned deterministic embedding identity is stored
  beside each vector, and query results return only file-relative offsets and
  hashes; source is read later only by an explicit context-pack request.
- Only metadata and hashes are persisted. Source is read transiently during
  reference extraction and is never inserted into the SQLite database.
- The inventory includes the macOS extension set (`m/mm/h/hpp/c/cc/cpp`, JSON,
  Markdown, YAML, and the managed-language families). Tree-sitter-backed files
  use the parser; formats without a bundled grammar use bounded lexical
  fallback rather than disappearing from the index.
- The app composes the store by default at
  `%LOCALAPPDATA%\\OpenBurnBar\\project-code-memory.sqlite`; deployments can
  override it with `OPENBURNBAR_PROJECT_MEMORY_PATH`.
- The Projects page persists a user-selected folder and consumes the app-owned
  `ProjectCodeMemoryService`, so the visible surface and companion operations
  share one encrypted checkpoint rather than maintaining a page-local index.
  JSON fallback metadata is keyed by the selected root and stored under
  `%LOCALAPPDATA%\OpenBurnBar\ProjectCode\indexes`, outside the repository.
- The lexical inventory, symbol pass, and durable artifact pass share a
  deterministic traversal that skips file and directory reparse points. A
  nested junction cannot redirect indexing outside the selected workspace.

## Validation

```text
dotnet test windows/tests/presentation/OpenBurnBar.App.Presentation.Tests.csproj --no-restore
```

Result: **778 passed, 0 failed, 0 skipped** in the full presentation suite.

The durable-store test proves two-file artifact/index persistence, lexical
reference and call-edge persistence, bounded call-graph traversal, checkpoint
restart hydration, and absence of source text in the database bytes. The
companion managed-runtime suite covers the new operation routing.

## Boundary

This evidence promotes the Windows watcher + durable metadata-store,
parser-backed AST chunking, bounded semantic-index trigger, and local provider
selection. The selectable deterministic/OpenAI contract matches macOS; macOS
BGE is unbundled and NaturalLanguage is a separate memory fallback. It does not
claim physical Windows performance/accessibility, live provider acceptance,
staging cloud flows, advanced Computer Use/media safety, or Store/update
certification.
