# Seal all confirmed server-readable private-text leaks

Goal ID: `privacy-leak-remediation-2026-06-02`
Started: 2026-06-03T04:48:00Z
Parent goal: none
Mode: full
Ledger path: `.agent/runs/privacy-leak-remediation-2026-06-02/`

## Objective

Close every confirmed cloud-plaintext leak (Hermes Gateway, project_memory, dataExport, knowledge_repos, usage/budget project text, Pensieve), convert denylist rules to hasOnly, fix client regressions, make trust copy honest, expand scanner+tests+scrubber, and verify across all platforms

## Goal Mode Coupling

When creating or updating the matching `/goal`, include this ledger pointer in the goal objective:

`Maintain the agent-owned ledger at /Users/albertonunez/Documents/Windsurf/BurnBar/.agent/runs/privacy-leak-remediation-2026-06-02/ and keep implementation-notes.html current at checkpoints, before compaction, and before final handoff.`

## Finishing Criteria

Each confirmed leak from the 2026-06-02 adversarial review is closed with the real fix (seal or honest-label by design), plus rules, tests, docs, and verification:

- [todo] **P0 Hermes Gateway**: message/event `text`, `senderDisplayName`, attachment bytes + `fileName` are sealed E2E (or, if recon proves the server must read them, the feature is honestly labeled server_readable AND the `deviceOnly` registry/trust claim is corrected). No plaintext private text persists server-readable.
- [todo] **P1 project_memory_snapshots**: `projectDisplayName` sealed; doc id is opaque (no name-derived slug); list/get/upsert still work.
- [todo] **P1 dataExport**: field-allowlist / seal-aware export; never emits a plaintext private field.
- [todo] **P1 knowledge_repos**: repo identity sealed or keyed-hashed; **Pensieve** cloaking enforced (raw embeddings rejected) and legacy keyless dedup oracle removed/keyed.
- [todo] **P2 usage/budget project text**: sealed, or session_logs trust copy made honest that project names are server-visible via usage_spend (resolve coherence).
- [todo] **Rules**: `session_logs` manifest/chunk, `chat_threads`, `media_*` converted from denylist to strict `hasOnly()` allowlists; gateway sealed-field rule added.
- [todo] **Client regressions fixed**: iOS approve/cancel (`liveSummary`), merge (`synthesisSummary`), rename (`customTitle`) write sealed; Android `ThreadInboxStore` reads sealed `cli_sessions`.
- [todo] **Scanner**: covers project_memory/gateway/knowledge/media and adds a semantic `hasOnly()` check (not string-presence only).
- [todo] **Scrubber + migration**: covers gateway/relay/text_snippets/project_memory legacy plaintext; an idempotent backfill story (not a manual dry-run) is documented.
- [todo] **Honesty**: registry.json + regenerated gen/* + website trust + docs match enforced reality; byte-lock tests pass.
- [todo] **Validation** (must pass): `node scripts/privacy/scan-chat-cloud-plaintext.mjs`; `npm --prefix functions run build`; `npm --prefix functions run test:firestore-rules`; `npm --prefix functions run test:agent-notifications`; `npm --prefix packages/data-domains test`; `cd android && ./gradlew :app:compileDebugKotlin --no-daemon`; targeted Swift cloud-sync tests via `./scripts/test-openburnbar-app.sh`. Plus a fresh adversarial re-scan confirming the named leaks are closed.
- [todo] Keep `implementation-notes.html` current; link bulky proof from `evidence/`.

## Escape Hatch

Pause, ask the user, or mark a scoped item `[blocked]` / `[incomplete]` if:
- validation contradicts the goal
- the goal requires a scope change
- the agent is looping without measurable progress
- the next step risks deleting or rewriting durable memory
- the PRD and actual repo disagree
- the ledger itself contaminates validation

