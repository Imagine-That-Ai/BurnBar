# F2 evidence: Pensieve knowledge watcher

Date: 2026-07-14
WPD-0006 row: 18
Disposition: SUB-DONE (sealed live watcher)

## Production composition

`App.OnLaunched` now starts one lifecycle-owned `PensieveKnowledgeWatcher`
after protected configuration and CloudSync composition. It watches the same
source families as macOS:

- configured repo-docs (`OPENBURNBAR_PENSIEVE_REPO_DOCS_PATH`);
- configured notes (`OPENBURNBAR_PENSIEVE_NOTES_PATH`);
- settled Claude Code JSONL sessions under the current user's
  `.claude/projects` tree.

Repo-docs and notes are recursively reconciled on startup, after a debounced
file-system event, and every 15 minutes as a missed-event backstop. Session JSONL
is never ingested as knowledge by this service. A settled write creates only a
metadata sentinel so the separate BYO-inference memory hook can perform review
and extraction, matching the macOS privacy boundary.

The watcher obtains the 32-byte vault key from the existing current-user
protected configuration on every scan. An absent, malformed, or unavailable key
fails closed before any queue directory or payload is written. The watcher does
not receive Firebase credentials and cannot upload directly.

## Wire and privacy parity

The portable Windows implementation mirrors the Swift core and published
TypeScript device path:

- the 6 KiB UTF-8 chunk ceiling with bounded overlap and long-token handling;
- the shared eight-pattern secret redactor;
- deterministic 384-dimensional `hashing-bow-v1` embeddings;
- 24 HKDF-derived Householder reflections keyed by the vault key;
- vault-keyed `pensieve-dedup:content` and `pensieve-dedup:slug` HMACs;
- AES-256-GCM sealed chunk text and sealed metadata;
- the `commitKnowledgeBatch` queue shape, including its 800-vector batch cap,
  and shared
  `~/.openburnbar/pensieve-queue` sink.

Cross-language golden tests assert the Windows cloak to 12 decimal places
against committed TypeScript/Swift reference vectors. Cleartext chunk text and
source paths are absent from the serialized vector row; full source paths occur
only inside sealed metadata. Queue writes use a same-directory temporary file,
write-through flush, restrictive user-only mode on POSIX test hosts, and atomic
replace. Queue paths inside watched roots are rejected to prevent self-trigger
loops.

## Bounds and lifecycle

- Recursive scans skip hidden/reparse-point entries, cap each pass at 20,000
  files, and reject empty, non-UTF-8, or larger-than-16-MiB source files.
- Large documents are partitioned into independently content-addressed batches
  of at most 800 vectors, so every queue file passes the server callable bound.
- One semaphore serializes initial, file-event, manual, and backstop scans.
- The process-lifetime vector-ID dedupe set is capped at 65,536 entries; queue
  filenames remain content-addressed and server commits are idempotent.
- `Start` is idempotent. Partial watcher startup rolls back installed handles.
  App shutdown cancels and awaits debounce/backstop work before other local
  runtime state is released.
- The caller-owned vault-key buffer is cloned before use and the scan-local copy
  is zeroed after every pass.

## Verification

```text
dotnet test windows/tests/cloudsync-app/OpenBurnBar.App.CloudSync.Tests.csproj --no-restore -v:minimal
Passed: 80, Failed: 0, Skipped: 0

dotnet build windows/app/OpenBurnBar.App.CloudSync/OpenBurnBar.App.CloudSync.csproj --no-restore -v:minimal
Build succeeded: 0 warnings, 0 errors
```

The focused tests cover independent keyed-hash references, TS/Swift golden
vectors, norm/inner-product preservation, secret redaction, UTF-8 byte bounds,
slug normalization, seal/open round trips, absence of cleartext side channels,
settled-session sentinels, repeat-scan dedupe, missing-key refusal, caller key
ownership, queue/source separation, live debounced events, idempotent start, and
awaited shutdown.

On the macOS authoring host, the full app build compiles all portable
dependencies and then stops at the expected inability to execute the Windows
App SDK `XamlCompiler.exe`. Exact-head hosted Windows Fast/Full/Dist workflows
are the authoritative WinUI composition and packaging proof.
