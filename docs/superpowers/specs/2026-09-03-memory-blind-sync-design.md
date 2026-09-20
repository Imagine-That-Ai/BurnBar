# Memory Blind Sync — design

Status: design for review, 2026-09-03. Alberto's brief for the Pro program: "add pro features, cloud and big models, hosted using the user's quotas or OpenRouter or Vercel; super safe, intuitive, encrypted — we need to be blind to the data too; state of the art." The approved shape was **direct-to-provider inference plus blind encrypted sync**; the models half shipped as [Memory Pro](2026-09-02-memory-pro-models-design.md) (PR #2501). This spec is the sync half: the member's memories follow them across their own devices, and BurnBar cannot read a byte.

Companion plan: `docs/superpowers/plans/2026-09-03-memory-blind-sync.md`.

## 1. Goal

A memory the Memory MCP learns on one Mac becomes available on the member's other devices, with the server holding ciphertext and opaque routing metadata only. Off by default, entitlement-gated, and every failure degrades to today's local-only behaviour.

## 2. Non-goals

- **No new cryptography.** The envelope, per-device escrow, doc-id blinding and the Firestore contract exist and ship on macOS, Windows and in Rust. This spec reuses them exactly.
- **No plaintext to BurnBar** — including tags, entities, metadata, source refs, embeddings and project names, all of which are plaintext columns locally and must be sealed or HMAC'd before they travel.
- **No server-side merge.** The server is a ciphertext mailbox; it never orders, dedupes or resolves.
- **No secrets.** `memory_vault` rows never leave the device. The engine's daemon mirror already refuses secret, non-approved and expiring rows (`server.py:1886-1892`); that filter stands.
- **No new key material in the Python engine.** The engine gains no cryptographic capability and never sees a vault key.
- **No iOS client work.** Windows already reads this collection; wiring it is a follow-up.

## 3. The terrain (verified)

Two database files, three writers:

| | File | Written by | Memory content |
|---|---|---|---|
| **Engine store** | `openburnbar-memory.sqlite` (plain SQLite, mode 0600) | Python engine only | canonical: `memories.body_cipher` AES-GCM under a local file keyring, AAD `"{id}\|{project_id}\|body"` (`crypto.py:207-213`) |
| **Control plane** | `openburnbar.sqlite` (SQLCipher) | app (GRDB) and daemon | `agent_memories` rows; chat bodies in `memory_body_snapshots`; engine-mirrored rows carry only `body_redacted` |

The engine mirrors every approved, non-secret write to the daemon (`server.py:1901` → `daemon.memory.remember` → `agent_memories` upsert), recording the daemon id under `engine_meta` key `daemon_mirror:<memory_id>` (`engine.py:204-228`).

**Today nothing the engine writes ever syncs.** The daemon's insert omits `source_kind`, which defaults to `"code"` (`OpenBurnBarDatabase+MemoryMigrations.swift:9-11`), and the cloud lane replicates only `source_kind = 'chat'` (`ControlPlaneStore+MemoryForget.swift:116-132`). Same table, disjoint partition.

What the cloud lane does today, for chat rows only: seal `{schemaVersion, memoryID, text, kind, scope, confidence, citations, validFrom, updatedAt}` with `CloudVaultCrypto.sealBlob` under AAD `(uid, "memory_facts", docID, "sealedMemory")`, write it to `users/{uid}/memory_facts/{docID}` with `setData(merge: true)` where `docID = pensieveSlugHmac("memory-fact:<id>")`, alongside plaintext `uid, docID, schemaVersion, sourceKind, kind, reviewStatus, citationCount, validFrom, updatedAt, replicatedAt` and up to 50 keyed `sourceRefHmacs` (`KnowledgeSyncService.swift:501-663`). It is **upload only**; no Swift client reads the collection back.

Reusable without change: the envelope and key hierarchy (`CloudVaultCrypto`, P-256 escrow join, `MacCloudVaultKeyAccess.keyForWriting`), the rules contract at `firestore.rules:3206-3252`, read and delete permission for `memory_facts` granted by the per-user wildcard block (`firestore.rules:1941-1998`), the `CloudSyncDomain` scheduling slot, the existing opt-in toggle and fleet ceiling, the C# reader as a parity oracle, and the bidirectional watermark pattern in `AIInboxSyncService`.

## 4. Architecture

The engine gains no keys and the daemon gains no network. Plaintext crosses only the local unix socket the engine already uses, and rests only in SQLCipher.

```
Python engine ──memory-remember (source_kind=agent, body)──► control plane (SQLCipher)
                                                                      │  app seals with the vault key
                                                                      ▼
                                                          users/{uid}/memory_facts   (ciphertext)
                                                                      │  app opens with the vault key
                                                                      ▼
Python engine ◄── burnbar_memory_import ◄── inbox rows in the control plane
```

**Push.** The engine's existing mirror is widened: approved, non-secret rows are mirrored with `source_kind = 'agent'`, and their body is written to `memory_body_snapshots` exactly as a chat body is. The upload path then needs one change — its partition filter accepts `agent` as well as `chat` — and every engine memory rides the machinery that already works.

**Pull.** A new `MemoryCloudPullService` reads `users/{uid}/memory_facts` above a stored watermark, opens each envelope with the vault key, rejects any document whose AAD or keyed plaintext HMAC does not verify, and upserts the row into the control plane marked `origin = 'remote'`. This is the one genuinely new mechanism; it mirrors `AIInboxSyncService`'s watermark loop and the C# reader's decode.

**Down into the engine.** The engine already imports daemon rows exactly once (`_admin.py:340 import_legacy`). That becomes a supported path: `burnbar_memory_sync_pull` asks the daemon for remote-origin rows the engine has not applied, and `merge_remote` applies them under §5.

**Identity across the two id spaces.** The engine's `memory_id` is 128 random bits, globally unique. The daemon assigns its own id for `agent_memories`. The sealed payload therefore carries the **engine id** as `memoryID` and the doc id is `pensieveSlugHmac("memory-fact:<engine id>")`, so the same memory converges to the same document on every device regardless of local daemon ids; the existing `daemon_mirror:<memory_id>` map keeps the local join.

Failure posture: no Pro, no consent, no signed courier, no daemon, no Firebase or no vault key leaves rows mirrored locally and never drained. Nothing blocks a local write.

## 5. Merge semantics

No vector clocks. The engine's own columns already carry enough.

- **Convergence on the same fact.** `UNIQUE(project_id, scope, body_hash)` means a fact learned independently on two devices folds into a reinforcement of the first, exactly as a local duplicate does today.
- **Ordering.** Last-writer-wins on `updated_at`, tie-broken by `memory_id`, so every replica reaches the same answer.
- **Supersede and retire.** `valid_to`, `superseded_by` and `supersedes_json` travel inside the sealed payload. They reference engine memory ids, which are globally unique, so a chain resolves on any device; a reference to a memory that has not arrived yet is parked and re-resolved on the next merge rather than dropped.
- **Retirement is an update**, not a special message: a row with `valid_to` set converges like any other. Hard forgets keep the existing `memory_forget_receipts` channel.
- **Idempotence.** Records are keyed by `(memory_id, updated_at)`; re-applying a batch is a no-op. The engine keeps a `sync_state` table with the applied watermark.
- **Never merged:** secrets, quarantined and rejected rows, and rows whose `metadata.injectionLabels` is non-empty stay excluded from model paths on arrival exactly as they are locally.

## 6. Server contract change

Two field widenings in `firestore.rules:3206-3252`, nothing else:

- `sourceKind == "chat"` becomes `sourceKind in ["chat", "agent"]`.
- the `kind` allowlist gains the engine's kinds: `decision`, `architecture`, `procedure`, `gotcha`, `todo`.

The sealed-blob validator, the opaque doc id, the forbidden `text`/`body`/`citations`/`vector`/`embedding` fields and the Data Vault entitlement are untouched, so the blindness proof does not move. `kind` remains in the clear, as it is today, and is the only semantic leak; §8 records it.

One gap must close with this feature: `CloudVaultRotationRewrapWorker` covers `session_logs`, `cloud_search_documents` and `cloud_search_chunks` but **not** `memory_facts` (`CloudVaultRotationRewrapWorker.swift:205-271`). A vault-key rotation today would strand every memory document. `memory_facts` joins the rewrap set.

## 7. Consent and controls

No fourth switch. The existing "Back up approved memories" opt-in (`MemorySettings.approvedCloudBackupEnabled`, default off, ANDed with the Remote Config ceiling) starts covering engine memories, and gains one sub-toggle, "Sync memories to my other devices", which turns the pull half on. Both sit under the same Data Vault entitlement (Pro Max or Ultra) the rules already require. `docs/PRIVACY.md` gains a paragraph naming exactly what the server holds: a sealed blob, an opaque id, keyed source HMACs, a kind, a review status and three timestamps.

## 8. Measured quality

| Metric | Target |
|---|---|
| Plaintext fields in an uploaded document | exactly the rules allowlist, asserted field-by-field so a new field fails the test |
| Convergence on a three-replica simulation (add, update, supersede, retire, conflicting edits) | identical active set on every replica |
| Re-applying an inbox batch | byte-identical store |
| Sync with the daemon absent, Firebase absent, consent off, or entitlement absent | zero network calls, zero local behaviour change |
| Secrets, quarantined rows, injection-labelled bodies leaving the device | 0, asserted adversarially |
| Vault-key rotation with memories present | every memory document rewrapped, none stranded |

## 9. Rollback

Additive throughout: one mirror field, one body snapshot, one pull service, one engine merge path, one settings sub-toggle, two widened rule fields, one collection added to the rewrap set. No migration destroys data.

**The app half is a plain revert.** Reverting it leaves ciphertext nothing reads and inbox rows nothing drains.

**The Python half of THIS bump is roll-forward-only.** `ENGINE_SCHEMA_VERSION` goes 1 → 2, and the v1 engine's version gate refuses any store stamped newer *at open* — so reverting the engine half does not degrade a store that has already run v2, it fails every memory operation on it. That check lives in the shipped v1 engine and cannot be changed retroactively; the only recovery is to roll forward again, or to point `OPENBURNBAR_MEMORY_DB_PATH` at a different store. **This is a named risk of PR 2 and belongs in its PR body.**

The v2 engine closes it for every future bump: a store stamped newer than the running engine now opens with a warning when the newer schema only ADDED tables and columns (everything this engine reads is still present), and is refused only when something it reads is gone (`memory_engine/store.py::ensure_schema`, `_newer_store_is_additive_only`; `tests/test_store_migrations.py::test_open_tolerates_a_newer_store_whose_extra_objects_are_additive`). A tolerated store keeps its own newer stamp, so the newer engine takes it back unharmed. A future bump that REMOVES a table or column is therefore still not revertable and must say so.
