# Project Code Memory Retention And Forget Policy

Project Code Memory is local-only by default. It indexes source files into the
daemon SQLite database after gitignore filtering, symlink/root checks, secret
scanning, and storage-budget enforcement.

## Local Retention

- Indexed source artifacts, chunks, FTS rows, symbols, references, call edges,
  manifests, diagnostics, and checkpoints are retained until the project is
  reindexed, forgotten, reset, or pruned by a storage-budget/reindex operation.
- Removed or renamed files are pruned on the next index run. Dependent chunks,
  FTS rows, symbols, references, call edges, and manifest rows are deleted with
  the artifact.
- Storage accounting includes source bytes, chunk text, FTS mirror/metadata
  estimate, and vector blobs where present. Incremental vacuum runs only when
  freelist/page metrics cross the local compaction policy.
- Secret-bearing files are rejected before persistence. Audit entries store
  labels only, never matched secret substrings.

## Local Forget

`burnbar_forget` / `memory.forget` hard-deletes the local memory row and writes a
label-only audit-chain event. Project code artifacts are removed by reindexing
or by resetting the local code index; source code plaintext is not uploaded by
local Project Code Memory.

## Hosted Code Sync

Hosted code sync is disabled by default. If it is enabled in a future release,
retention must be stricter than prose memory:

- Upload only device-sealed code chunks and sealed metadata.
- Require vault-keyed `projectHmac` and `slugHmac` identifiers.
- Reject raw source text, raw paths, raw content hashes, and public embedding
  vectors server-side.
- Provide a device-authed cloud forget that hard-deletes sealed code rows and
  cloaked vectors by project/chunk HMAC.
- Surface pending cloud deletes in doctor/status until a receipt is recorded.

Until that cloud hard-delete receipt path exists, hosted code sync remains
non-production.
