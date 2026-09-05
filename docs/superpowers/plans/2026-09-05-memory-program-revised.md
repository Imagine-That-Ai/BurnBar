# Memory program — revised plan (post-audit), 2026-09-05

Supersedes `2026-09-05` draft "memory program plan (under audit)". Revised against the
adversarial audit of that draft and against the head of PR #2519
(`feat/memory-blind-sync-pull`, frozen at `e4b8f8abf1`). Every `file:line` below is that
SHA unless marked `(main)`.

Audit disposition for all 23 findings: **Appendix A**. What #2519 already ships (do not
re-implement): **Appendix B**.

---

## Goal

Finish the memory program end to end on top of what #2519 already landed: close the
remaining sync-correctness holes, make memory visible and trustworthy in the app, widen
capture without weakening honesty guarantees, add team/org memory, and bring Linux and
operators along. Twenty items, five phases (A–E), sequenced so each phase is shippable on
its own.

The draft's Slice 0 ("land blind-sync PR2") is deleted: it is PR #2519 and it is built.
The program now starts by *verifying* #2519's review wave landed, not by rebuilding it.

## Success Criteria

- A memory edited on two devices offline converges to one body with no resurrection of
  forgotten rows and no order dependence — including across a stale-push overwrite and a
  timestamp tie.
- Every user-visible memory can answer: its revisions, which device wrote it, when it last
  helped, and why it was recalled.
- New capture paths (collectors, importer, on-demand extraction) land quarantined or
  labelled; nothing silent enters the approved set, and nothing quarantined leaves the
  device — including to the embedding provider.
- Team memory reuses the blind envelope; the server never holds a team key or plaintext.
  The two semantics the design cannot hide (join-reads-history, leave-protects-future-only)
  are stated in the spec and in the UI.
- Linux **enforces** the same memory + egress gates as macOS — not merely compiles —
  and refuses to serve the gateway until it does. Operators can see last pull, applied,
  rejected, parked, skipped, and marker age, for **both** watermarks.

## Context And Current Facts

Written against PR #2519, not `main`. The draft's opening claim ("verified: no
`merge_remote` or `sync_state` exists anywhere under `tools/openburnbar-mcp/`") is false at
this SHA and is withdrawn.

**Engine — merge and convergence exist.**
- `merge_remote` ships: `tools/openburnbar-mcp/memory_engine/_sync.py:496` (the file is 962
  new lines).
- `sync_state` is a real table — `user_id`, `applied_updated_at`, `applied_memory_id`,
  `applied_count`, `merged_at` — at `memory_engine/store.py:193-199`, behind
  `SCHEMA_MIGRATIONS` v2 (`store.py:275-284`); `ENGINE_SCHEMA_VERSION` is already 1→2.
  Additive-newer-store tolerance is implemented at `store.py:267-336`
  (`_newer_store_is_additive_only`).
- The engine schema half is **roll-forward-only**:
  `docs/superpowers/specs/2026-09-03-memory-blind-sync-design.md` §9 (rewritten in this PR)
  — "*A future bump that REMOVES a table or column is therefore still not revertable*".
- Alias resolution exists as a **namespace, not a table**: `memory_alias:<foreign_id>` in
  `engine_meta`, written at `_sync.py:161-176`, resolved via `_alias_target`
  (`_sync.py:178-190`) and `_local_memory_id` (`:192-218`), purged with the row at
  `_read.py:1086-1089`.
- Forget receipts exist, keyed **both** ways: `forget_receipt:<memory_id>` and
  `forget_identity:<convergence key>` at `_sync.py:134-165`; `sync_identity:<key>` at
  `:296`; `sync_mark:<memory_id>` at `:229-255`.
- Receipt check already precedes chain check in `_decide_remote_fact`
  (`_sync.py:610-632`); re-remember lifts the receipt (`:617-620`, test
  `tests/test_memory_blind_sync.py:446`).
- Fork/parked-supersede handling already ships: `_update_remote_row` aliases on a body
  clash, retires the loser into the holder with `replacement=holder`, and reinforces
  (`_sync.py:698-716`), under LWW against the applied `sync_mark` (`:641-664`).
- The three-replica convergence simulation the draft called "highest-risk validation, run
  it before any Slice 1 PR opens" **already exists and passes**:
  `tests/test_memory_blind_sync.py:174`
  `test_three_replicas_converge_on_an_identical_active_set`, plus 32 siblings.
- `body_hash` has **no divergence**. `memories.body_hash` is `sha256_hex(body.lower())` at
  all three write sites — `_write.py:544`→`:825`, `_read.py:824`→`:910`, `_sync.py:463`.
  `_admin.py:420` (`:413` on main) writes the **daemon-mirror** hash into `engine_meta` key
  `daemon_mirror:<id>` (`engine.py:220-233`), a separate namespace, consistently
  non-lowered at `server.py:2075` and `server.py:2172`.
- `history(memory_id)` is **unscoped by project** (`_read.py:1169-1173`).
- The engine's recall `why` block already ships: `_read.py:226-236` builds `lexicalRank`,
  `bm25`, `semanticRank`, `cosine`, `salience`, `recency`, `rerankScore`, `reranker`, and
  `_read.py:257` (`item.update(extra)`) returns it on every hit.
- Doctor (`_admin.py:536`; `:529` on main; findings `:555-600`) covers aux-secret exposure,
  undecryptable rows and gate corpus — and **no** sync ledger: no `sync_state`, no
  receipts, no aliases.

**Envelope — payload v2 shipped.**
- `MemoryCloudFactPayload.currentSchemaVersion = 2`
  (`AgentLens/Services/CloudSync/KnowledgeSyncService.swift:511`); v2 fields at `:509-546`
  are `validTo`, `supersededBy`, `tags`, `bodyHash`, `projectID`, `engineScope`, all
  optional so a v1 payload still decodes.
- Doc id is `pensieveSlugHmac("memory-fact:<engine id>")`
  (`KnowledgeSyncService.swift:669`); AAD is `(uid, "memory_facts", docID,
  "sealedMemory")` (`:687-692`).
- Rules pin the plaintext key set (`firestore.rules:3207-3224`, block 3206-3258), the kind
  allowlist with **no retire kind** (`:3239`), and `reviewStatus == "approved"` on every
  write (`:3241`). `sealedMemory.schemaVersion >= 2` (`:3247`) is the **CloudVault envelope**
  version (`validCloudSealedBlob`, `firestore.rules:1098-1128`, `>= 1 && <= 10`), *not* the
  payload version — the payload version lives inside the ciphertext and rules cannot see
  it. That is why a payload-field change needs no rules change.
- **Both readers refuse anything newer than their own maximum.** Swift:
  `MemoryCloudPullService.swift:427-429`
  (`payload.schemaVersion <= MemoryCloudFactPayload.currentSchemaVersion` else
  `.unsupportedSchema`), and `.failure` is the *freezing* case (`:236-240` sets
  `watermarkFrozen`, `:290-296` caps the cursor strictly below). Python:
  `memory_engine/constants.py:79` `REMOTE_PAYLOAD_SCHEMA_MAX = 2`, `_sync.py:341-350`
  returns `PAYLOAD_TOO_NEW` with `ack=False` → parked forever.
- The Windows codec still writes **payload v1**
  (`windows/app/OpenBurnBar.App.CloudSync/MemoryCloudFactCodec.cs:36`, `:53`) and
  `DecodeAuthority` (`:66-81`) drops `validTo` and `supersededBy` — so a Windows device
  opening a v2 retired Mac fact materialises it as **active**.

**Transport, consent, enforcement.**
- Forget already has a correct cloud channel: `KnowledgeSyncService.swift:601-618` writes
  `users/{uid}/memory_forget_receipts` then deletes the fact document; the collection and
  its rules exist at `firestore.rules:3263-3300` (`memoryIdHmac` / `sourceRefHmac`).
  Retired rows are excluded from upload by design
  (`ControlPlaneStore+MemoryForget.swift:227`, `memory.validTo == nil`).
- The pull reads only `memory_facts` today (`MemoryCloudPullService.swift:195-201`), with a
  single-timestamp watermark (`:195-199`) and a full-page tie guard (`:330-341`). The
  Codex fix wave in flight on #2519 replaces that with a **composite `(updatedAt,
  documentID)` cursor**, a **per-document rejection ledger** so a permanently-invalid
  document stops pinning the first page, and a **second pass over
  `memory_forget_receipts`** — the receipt channel A2 then builds on. Treat all three as
  *verify landed*, not as work.
- Consent is enforced daemon-side by a marker with a max age:
  `BurnBarProjectCodeMemoryStore+SyncInbox.swift:63`,
  `deviceSyncConsentMarkerMaxAge = 2 * 600`, documented as 2 ×
  `BehaviorSettings.refreshInterval`. The Codex fix wave moves the refresher onto its **own
  5-minute cadence** independent of `BackgroundCadenceCoordinator`'s stretched interval, so
  the marker's validity no longer rides a cadence that can stretch 5× while the app is
  inactive.
- Withdrawal is **generation-guarded**: `MemoryDeviceSyncInboxGuard.swift:46-48, 124, 140,
  220` — withdrawal advances a per-store generation inside its own transaction, every
  publish reads that generation before it captures scope, and publishes marker + rows in
  one transaction that commits only if the generation still matches.
- There are **two** watermarks. The engine's `sync_state` (`store.py:193-199`, advanced at
  `_sync.py:930-960`) and the app's `remote_sync_watermarks` with a `memory_facts` kind
  (`RemoteSyncWatermarkStore.swift:16, 49`). They are independent; withdrawing consent
  deletes unapplied inbox rows (`ControlPlaneStore+MemorySyncInbox.swift:210-224`) and the
  fix wave must rewind the transport watermark with them.
- Quarantined remote bodies are **embedded off-device today**: `_write_remote_row` calls
  the provider unconditionally at `_sync.py:767` before consulting `review_status` (already
  `"quarantined"` when `fact.injection` is non-empty, `_sync.py:466`); with
  `GatewayEmbeddingProvider` that is a network call through the daemon gateway
  (`embeddings.py:196-202`). Fixed on #2519 — verify landed.
- The inbox tool response still carries other projects' bodies:
  `server.py:3100-3107` (list deliberately not narrowed by `projectID`), bodies returned at
  `server.py:3218`. Fixed on #2519 — verify landed.

**Platform.**
- `BurnBarMemoryEgressEnforcer.swift` is portable (129 lines, `import Foundation` +
  `import OpenBurnBarEngine`, no `#if os`). The Linux **build break is one argument**:
  `OpenBurnBarDaemonServer.swift:695` passes `memoryEgress:` unguarded (the surrounding
  `#if os(Linux)` block ends at `:679`) and
  `Linux/OpenBurnBarHTTPGatewayServerLinux.swift:142-155` has no such parameter.
- But the Linux gateway is a **separate 1816-line socket server** (`#if os(Linux)` at `:1`)
  sharing none of the Darwin route pipeline, which imports Apple-only `Network`
  (`OpenBurnBarHTTPGatewayServer+RoutePipeline.swift:1-4`). Darwin's enforcement surface is
  `+RoutePipeline.swift:111-126` (evaluate/deny), `:209-222` (record), `:750-762` (denial
  response), `+Connection.swift:163-164` (token validation). None of it exists on Linux.

**App and settings.**
- `MemorySettings.approvedCloudBackupEnabled` defaults off (`MemorySettings.swift:35`).
- The fleet-ceiling precedent is **closed-until-resolved, with no max-age**:
  `MemorySettings.swift:257-270` (`hasResolvedUsageRemoteConfig` — "the gates are
  structurally held CLOSED until an RC value has actually been applied"), `:274-286`
  (`applyUsageRemoteConfig`, fed Firebase's active cached config before any network call),
  gates at `:531-583`.
- Every escrow construct is **intra-account**: `users/{uid}/escrow_public_keys`,
  `escrow_devices`, `escrow_envelopes`, `escrow_grants`, all gated by
  `ownsUserNamespace(userId)` (`firestore.rules:15, 1402, 2644-2646, 3467-3470`; publisher
  `SessionLogSyncService+VaultKeyPublishing.swift:25-60`). There is no roster, no
  cross-uid read path, and no authority that can assert team membership.
- Review inbox exists but names no gate
  (`AgentLens/Views/Memory/MemoryReviewInboxModel.swift` — no verdict/reason plumbing).
- Resume briefings sit behind explicit plaintext-read consent (`server.py:4875-4879`).
- Two rankers: engine RRF (`_read.py:216-224`) and daemon
  `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/ProjectCodeMemory/BurnBarMemoryRanking.swift`.

**Website.**
- The copy-gate pattern is live and in CI: `website/package.json:18`
  (`test:pricing-copy`), chained into `verify` at `:61`, run by `website-ci.yml:59`.
  Siblings: `test-router-copy.mjs`, `test-trust-copy.mjs`, `test-approved-hero-copy.mjs`,
  `test-demo-telemetry-copy.mjs`. `/pricing` is **already gated**; `/providers` and
  `/security` are not (`website/src/pages/providers.astro`, `security.astro`).

## Constraints And Non-goals

Standing constraints from the blind-sync plan carry over, corrected:

- No new cryptography primitives. No plaintext to the server — tags, entities, metadata,
  source refs, embeddings and project names stay sealed or HMAC'd. Every lever fail-closed.
- Python adds no dependencies. `ruff==0.15.17` (`fast-feedback.yml:718`). **CI runs pytest
  on 3.11 only** (`.github/workflows/agent-tools-ci.yml:44`); 3.12 is a local courtesy run,
  not a gate. Do not present "3.12 + 3.11" as a gate.
- SwiftLint strict. The Xcode project is generated: `xcodegen generate --spec project.yml`;
  never hand-register a file in the pbxproj.
- Commit trailer is **`Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`** (HEAD
  commit; 14 of the last 15). The `Claude Opus 5` string the draft copied survives only in
  `docs/superpowers/plans/2026-09-03-memory-blind-sync.md:19`.
- **`OpenBurnBarKernel` is at its ceiling and must not be raised**:
  `scripts/debt/check-core-target-membership-budget.sh:152`
  `{ maxFiles: 191, maxLines: 54000 }`, commented "No headroom on purpose". New wire
  contracts go to `OpenBurnBarProjectCodeContracts` (`:139-145`,
  `{ maxFiles: 2, maxLines: 1000 }`, seeded just above the measured 866 LOC — roughly one
  file and ~134 lines of headroom). A slice needing more than that argues for a new leaf in
  its PR body. The script is a per-PR gate.
- **Any new app SQLite table costs eight surfaces**, all of which must land in the same PR:
  (1) both ordered migrator surfaces (app + Core), (2) the fast-lane migration lists,
  (3) `scripts/rollback-migration.sh` catalog + `scripts/ci/verify-migration-rollback-catalog.test.mjs`
  + `docs/DATABASE_OPERATIONS.md:197-207` checklist and its tripwire, (4)
  `docs/SCHEMA_SQLITE.sql` DDL **and** its hash, (5) Windows provisioning
  `WindowsSqlCipherProvisioning.{Schema,Upgrades,Metadata}.cs`, (6) the five Windows test
  pins (`WindowsSchemaUpgradeTests.cs` + siblings), (7) the Swift pins, (8) the byte-compat
  fixture + `openburnbar-db-compat-vector.json` +
  `AgentLensTests/Support/DatabaseByteCompatVector.swift`. Price accordingly, or do not add
  a table. E19 in particular persists to `engine_meta` and the daemon's existing metrics
  surface, **not** a new app table.
- The engine's schema half is roll-forward-only (§9 of the design spec). Any A-slice engine
  bump inherits that and says so in its PR body.
- `OpenBurnBarCore/Package.swift` is digest-pinned in **two** places —
  `config/domain-core-control-plane-manifest.json:19` and
  `launch-evidence/libsignal-rust-core-bridge-v1.0.34.json:10,131`. Touching it means
  re-pinning both (see `e4b8f8abf1` and `c4cdaf94ef` for the precedent commits).
- **The Mac app build is nightly, not a merge gate** (CHEAP_FAST). Therefore every slice
  compiles and runs the app test target *locally* after merging `main`, before opening the
  PR — the merge door will not catch a break for you.
- Non-goals: server-side plaintext search or ranking; changing the blindness proof (sealed
  blob validator, opaque doc id, banned plaintext fields, Data Vault entitlement stay
  untouched); MAS-excluded paths stay excluded.

## Key Decisions

Numbering preserved from the draft so a reader of the original can map. Corrections are
marked.

1. **Sequence: A → E-platform(a) → B → C → D → E-ops.** Slice 0 is deleted (it is #2519).
   Phase A now opens with A-1/A-2, which are *verifications* that the #2519 review wave
   landed, then the genuinely new A-items. The Linux **build** break (E18a) rides with A
   because it is one line; the Linux **enforcement** port (E18b) is its own PR in Slice 6
   because it is a port into a separate 1816-line server. Team/org (D) goes last — it is
   the only phase needing new key-distribution design.

2. **A0 is hygiene, not a prerequisite, and not a migration.** *(Corrected — the draft's
   "known inconsistency" does not exist.)* Add `canonical_body_hash()` in `_util.py`; route
   `_write.py:544`, `_read.py:824` and `_sync.py:463` through it; add a regression test
   asserting all three agree on mixed-case bodies. **No recompute, no data migration.**
   A code comment records that the daemon-mirror hash (`server.py:2075`, `:2172`,
   `_admin.py:420`) is a different, non-lowered hash in a different namespace and must not
   be folded into this helper. The draft's sub-check (a) ("re-key the mirror map in the
   same migration") is deleted: it would break the staleness check at `server.py:2075-2085`.
   A recompute would also invalidate every `forget_identity:*` key and thereby **resurrect
   forgotten memories**.

3. **`previousBodyHash` is advisory ordering evidence, never an admission gate — and there
   is no version bump.** *(Corrected on both halves.)*
   - **No version bump.** `previousBodyHash` and `writerDevice` land as **optional fields at
     schemaVersion 2 (unchanged)**. Both readers already ignore unknown JSON members (Swift
     `Codable` with optionals; C# `System.Text.Json` default `UnmappedMemberHandling.Skip`)
     and both already *refuse* anything above their own maximum — Swift by freezing the
     cursor (`MemoryCloudPullService.swift:427-429` → `:236-240` → `:290-296`), Python by
     parking forever (`constants.py:79`, `_sync.py:341-350`). A bump would strand every
     un-upgraded device's cursor permanently. The version moves only after every reader
     ships a raised maximum, one release ahead of the first document that uses it.
   - **Forward-safety gate, restated:** before any new optional field ships, every sealed
     reader (Swift, Python, C#) proves **unknown-field tolerance at a fixed version**
     in-test by opening a fixture carrying an unknown member. Tolerance fixtures land
     *first*, in their own packet, before the field.
   - **Chain rule, complete.** Absence of `previousBodyHash` means "no lineage advice" and
     changes nothing. Present and matching the current body → fast-forward. Present and not
     matching → held in a bounded persisted queue, re-evaluated each merge, surfacing
     `UNRESOLVED_GAP` to doctor after the gap timeout — **and the existing
     LWW-on-`sync_mark` decision (`_sync.py:641-664`) still applies at the timeout**, so a
     replica can never stall on a peer that will never send the missing body. The draft's
     "any update to a known memory without `previousBodyHash` is rejected" is **deleted**
     (it would reject every shipped v2 writer and every Windows client,
     `MemoryCloudFactCodec.cs:36`). The "genesis-only omission" rule is **deleted** — it is
     undecidable at the reader, which cannot distinguish "genesis" from "I have not seen the
     predecessor", which is the exact scenario the field exists for, and which
     `sync_identity:*` (`_sync.py:262-296`) already solves.
   - **Lineage is advisory for fork detection; LWW stays authoritative.** Fork handling is
     already shipped (`_sync.py:698-716`) and is not re-implemented.

4. **Forget is a tombstone, and retirement propagates on the PULL side.** *(Corrected.)*
   No new kind — the rules allowlist has none to give without a contract change
   (`firestore.rules:3239`). The draft's "the uploader synthesizes the retired sealed record
   from the receipt" is **deleted**: a receipt carries no body, the engine's screen refuses
   an empty body before it looks at `validTo` (`_sync.py:387-391`, again at `:400-402`) and
   refuses a payload with no `projectID` (`:377-386`) — so a synthesized record is refused
   terminally on every replica; and attaching a body to make it pass would re-publish sealed
   ciphertext of exactly the content the member asked to forget.
   Instead: `MemoryCloudPullService` gains a second pass over
   `users/{uid}/memory_forget_receipts` above its own watermark; each receipt's
   `memoryIdHmac` is matched against the engine ids this device holds and applied as a local
   forget + receipt. The existing delete-doc-and-write-receipt path
   (`KnowledgeSyncService.swift:601-618`) is already correct and stays. **Nothing about a
   forgotten body is ever re-uploaded.**
   **Receipt check precedes chain check, so a retire wins regardless of arrival order** —
   this is `_decide_remote_fact` (`_sync.py:610-632`) and it is the single most important
   invariant in the program. Receipts are keyed per `memory_id` **and** per convergence
   identity so a re-learned copy arriving under a foreign engine id still loses
   (`_sync.py:130-165`). Re-remember escape rule: a fresh write mints a new `memory_id`, so
   deliberate re-learning after forget is unaffected (`_sync.py:617-620`).
   A `forget_receipts` **table** is not created: the `forget_receipt:*` / `forget_identity:*`
   keys already exist. Promote them to a table only if A7's doctor pass proves it needs
   indexed scans, and say so in that PR.

5. **Doctor stays report-first.** The sync-ledger pass (watermark sanity on **both**
   ledgers, orphan `agent_memory_bodies`, parked supersedes, receipt coverage,
   `UNRESOLVED_GAP`) reports findings with codes; `--apply` prunes only orphans older than a
   grace period and unreferenced by any un-uploaded row or receipt, and parked supersedes
   only after N days. Same shape as today's aux-scan cursor walk.

6. **Alias resolution rides the mechanism that already exists — no new table.**
   *(Corrected.)* `memory_alias:<foreign_id> → <local_id>` already lives in `engine_meta`,
   written by the merge (`_sync.py:161-176`), resolved through `_alias_target` (`:178-190`)
   and `_local_memory_id` (`:192-218`), purged with the row (`_read.py:1086-1089`). A second
   alias store would be a divergence bug waiting to happen. Delete
   `memory_aliases(folded_id → canonical_id)` from the draft.

7. **Non-git project identity: explicit adoption only.** *(Corrected — the draft's
   automatic dotfile inheritance is a cross-project scope-confusion primitive.)* Resolution
   order: explicit mapping → git root → hashed path flagged provisional. A
   `.burnbar/project-id` dotfile is **read but never auto-applied**: opening a folder whose
   dotfile names an id this device does not already map surfaces a one-time confirmation;
   `project adopt <id>` prints the id and the memories it would join and requires an
   explicit yes. A dotfile naming an id the device already maps to that path is a no-op.
   **Repository contents never silently re-scope a folder's memories.**
   Why: repo contents are attacker-controlled, `resolve_project` upserts the `projects` row
   on the spot with no confirmation (`store.py:431-434`, `:448-460`), today's fingerprint is
   at least a property of *your* clone (`project_code_memory.py:324-346`), `history()` is
   unscoped by project (`_read.py:1169-1173`), and the inbox list is deliberately not
   narrowed by `projectID` (`server.py:3100-3107`). Auto-adoption would turn all of that
   into both a read primitive (recall in a hostile folder resolves against the victim
   project) and a write primitive (facts learned in the hostile repo file under, and upload
   as, the victim project).

8. **Removed.** *(The draft's "No migration for `sync_state` — the table does not exist
   yet" is false.)* `sync_state` shipped in #2519 with its names (`store.py:193-199`,
   `:275-284`). Renaming `applied_count` now costs an `ENGINE_SCHEMA_VERSION` 2→3 migration
   that **removes** columns, which the v2 engine's additive-only tolerance
   (`store.py:267-336`) does not cover and which the branch's own rollback doctrine calls
   non-revertable (design spec §9). Decision: **keep the names.** If a rename is ever worth
   it, bundle it into the same PR as the next additive bump and price it as
   roll-forward-only in the PR body. A5 is deleted from the work plan.

9. **Visibility reuses computed data, adds no new ranking.** "Why this" surfaces the RRF
   components already computed; the timeline reads `memory_history`; the health card
   aggregates doctor + analytics counters. No new scoring, no new telemetry schema. The
   engine half is **already shipped** (`_read.py:226-236`, returned at `:257`), so B9 is the
   daemon ranker plus the app surface. Device attribution: `writer_device` travels inside
   the sealed payload (optional field at v2, never a plaintext field) and the pull path
   stamps it into local history `meta_json`; local writes stamp the local device id.
   Because `history()` is unscoped by project, B8's read API scopes by project itself
   rather than inheriting that hole.

10. **Capture stays quarantined-by-default — including from the embedding provider.**
    Importer rows and auto-collected rows enter as quarantine; on-demand Pro-model
    extraction reuses the #2501 model policy (member's own quota/keys, BurnBar blind) and
    stamps provenance `extracted_by` visibly. Importer runs in bounded batches with a cap +
    summary and a strict export-schema version gate. Quarantined content is never handed to
    a hosted embedder (`_sync.py:767` — fixed on #2519, verified in A-2).

11. **Team memory = same envelope, new key, new collection — and the roster is NEW
    design.** *(Corrected.)* `team_memory_facts/{teamId}/facts/{docID}` sealed under a team
    vault key; doc-id derivation and AAD bind `teamId`; leave-team = key rotation.
    But the escrow pattern this reuses is **intra-account only** — every escrow construct is
    `users/{uid}/…` gated by `ownsUserNamespace(userId)` (`firestore.rules:15, 1402,
    2644-2646, 3467-3470`; `SessionLogSyncService+VaultKeyPublishing.swift:25-60`) and
    distributes one member's key to that member's own devices. There is no cross-member
    roster, no cross-uid read path, and no authority that can assert "X is a member of team
    T" — a client cannot be trusted to assert it, so it needs a server-side writer that does
    not exist. "Extended to a roster" is a new trust model. The spec must name the writer of
    the roster and the rules that bind it.
    Two semantics are accepted and **must be stated in the spec and in the UI**:
    (a) joining a team grants read of all team facts sealed under the current key, including
    those contributed before joining; (b) leaving triggers rotation, which protects future
    writes only — the departing member retains the old key and anything already downloaded.
    **Consent is a display and contribution control, not a confidentiality boundary.** The
    draft's "a compromised member client is out of scope as with all client-side gates" is
    withdrawn: existing client-side gates protect a member from their own device; a team
    gate must protect member A from member B, which is a different claim.
    Budget: spec + **two** PRs (roster authority and rules; envelope and client).

12. **Org ceiling is closed-until-resolved; member-local memory is a separate lane.**
    *(Corrected — the draft's max-age rule fails open on a device that has never resolved
    the ceiling, because "which kinds are org-gated" is itself in the ceiling.)* Follow the
    shipped fleet-ceiling shape (`MemorySettings.swift:257-270` — "the gates are
    structurally held CLOSED until an RC value has actually been applied"; `:274-286`
    `applyUsageRemoteConfig`; gates `:531-583`): an `orgCeilingResolved` lever ANDed into the
    org lane, seeded from Remote Config's **active cached snapshot at init**, so an
    unresolved or never-fetched ceiling closes the org lane rather than defaulting it open.
    Offline uses the cache, which counts as resolved. **No max-age is introduced** — the
    precedent has none. Fail-soft applies only to **member-local memory that was never
    org-gated**: it is a separate lane, never ANDed with the org ceiling, so a stale or
    absent ceiling cannot brick it.

## Recommended Approach

Six shippable slices (the draft's seven minus the deleted Slice 0): A-sync (Slice 1),
A-platform/hygiene (Slice 2), B-visibility (Slice 3), C-capture (Slice 4), D-team/org
(Slice 5), E-ops/docs/Linux-enforcement (Slice 6, parallelizable with Slice 3 except E18b).
Each slice ends with the verification table below — extended, per the audit, with the
**app-layer** test classes, because the Python convergence simulation never touches the
Swift transport where most of the live defects were.

## Work Plan

### Slice 1 — Sync correctness (Phase A, engine + envelope)

- **A-1 (first) — the ten #2519 review findings.** *In progress on PR #2519; this plan
  lists them as acceptance, not as work to redo.* Verify each has landed with a test before
  any A-item opens a PR. By thread id:
  | Thread | Subject | Verify landed |
  |---|---|---|
  | `PRRT_kwDORtgQYs6ffqQA` | retirement filtered out of upload (`ControlPlaneStore+MemoryForget.swift:227`) | receipt channel is read by the pull; A2 builds on it |
  | `PRRT_kwDORtgQYs6ffqQC` | hosted embedding of quarantined content (`_sync.py:767`) | A-2 below |
  | `PRRT_kwDORtgQYs6ffqQD` | timestamp-tie cursor (`MemoryCloudPullService.swift:353`) | composite `(updatedAt, documentID)` cursor |
  | `PRRT_kwDORtgQYs6ffqQF` | device-clock global cursor (`:200`) | 15-minute skew re-scan window below the cursor (mitigation, landed); server-ordered `ingestedAt` transport stamp is a named follow-up (rules allowlist + Windows codec); sealed `updatedAt` stays LWW-only |
  | `PRRT_kwDORtgQYs6ffqQJ` | watermark rewind on inbox purge (`ControlPlaneStore+MemorySyncInbox.swift:219`) | purge and transport watermark rewind atomically; the 90-day sweep too |
  | `PRRT_kwDORtgQYs6ffqQK` | consent-marker cadence (`…+SyncInbox.swift:62`) | marker refresher on its own 5-minute cadence |
  | `PRRT_kwDORtgQYs6ffqQL` | account-wide consent missing from the toggle handler (`PrivacyIndexingSettingsView.swift:891`) | scope built from the same account levers as `GateSnapshot.pullConsentGranted` |
  | `PRRT_kwDORtgQYs6ffqQN` | permanent rejection pinning the first page (`MemoryCloudPullService.swift:243`) | terminal rejections (bad AAD, wrong doc id, undecodable payload) advance the cursor and are logged once; transient failures still freeze it |
  | `PRRT_kwDORtgQYs6ffqQO` | stale push overwriting a newer remote revision (`MemoryCloudSyncDomain.swift:290`) | cloud write skipped when the remote document's `updatedAt` is not older than the local revision; receipts stay unconditional |
  | `PRRT_kwDORtgQYs6ffqQS` | cross-project bodies in the tool response (`server.py:3218`) | bodies omitted or filtered to the requested project |
  Two of these (stale-push overwrite, device-clock cursor) make any lineage chain
  meaningless, and one (retirement propagation) is A2's actual subject — so A1 and A2 do
  not open until A-1 is green.

- **A-2 — quarantine excludes embedding.** *Already fixed on #2519; verify landed.*
  `_write_remote_row` skips the provider call when `fact.injection` is non-empty; a later
  review-to-approved re-embeds through `reindex`. Acceptance: an injection-labelled remote
  row lands with `embedded: false` and the fake provider records **zero** calls.

- **A0 — canonical body hash (hygiene).** `canonical_body_hash()` in `_util.py`; route
  `_write.py:544`, `_read.py:824`, `_sync.py:463` through it; regression test asserting the
  three agree on mixed-case bodies; comment recording that the daemon-mirror hash is a
  separate namespace. **No recompute, no migration, no ordering dependency on A1.**

- **A1 — lineage fields as optional members at v2.** Two packets.
  (i) *Tolerance fixtures first*: every sealed reader opens a v2 fixture carrying an
  unknown member, in-test, on Swift (`MemoryCloudPullServiceTests`), Python
  (`test_memory_blind_sync.py`) and C# (codec round-trip). No field ships until all three
  are green.
  (ii) *The fields*: `previousBodyHash` and `writerDevice`, optional, schemaVersion stays
  **2**. Writer: `KnowledgeSyncService.swift` payload encode. Reader/merge:
  `memory_engine/_sync.py` implements fast-forward / bounded persisted hold-back with gap
  timeout → `UNRESOLVED_GAP`, with LWW-on-`sync_mark` still deciding at the timeout. Fork
  handling is not re-implemented (`_sync.py:698-716`).
  Validate: three-replica out-of-order simulation still converges; a gap fixture yields
  exactly one `UNRESOLVED_GAP`, including across a restart with the persisted queue; a
  writer that omits the field is applied normally; old-client payload still opens; rules
  test asserts the plaintext allowlist is byte-identical (set comparison) — it must not
  move, because nothing new is plaintext.

- **A2 — pull-side receipt application.** `MemoryCloudPullService` gains a second pass over
  `users/{uid}/memory_forget_receipts` above its own watermark, applying each receipt as a
  local forget + receipt via the engine's existing `forget_receipt:*` /
  `forget_identity:*` keys. **Never upload a retired body.** No new engine table.
  Files: `AgentLens/Services/CloudSync/MemoryCloudPullService.swift`,
  `ControlPlaneStore+MemoryForget.swift`, `memory_engine/_sync.py` (application entry only).
  Validate: forget-then-replay (late body, foreign id, reworded body under the same id)
  stays forgotten on all replicas; deliberate re-remember reactivates via the new id; a
  receipt arriving before the fact it retires still wins; the receipt pass has its own
  watermark and cannot rewind the fact watermark.

- **A3 — alias-aware get/forget/recall, no new table.** `get`, `recall` and `forget` resolve
  their id argument through the existing `_alias_target` (`_sync.py:178-190`) before lookup;
  a local fold writes the same `memory_alias:*` key and a `memory_history` entry.
  Validate: folded id resolves in get/recall on the folding device; post-sync it resolves on
  a second device via the supersede chain; forget-via-alias removes the canonical row;
  double-fold is a no-op.

- **A4 — explicit project identity.** Same override chain in engine `resolve_project`
  (`store.py:431-434`) and daemon `resolveProjectIdentity`
  (`BurnBarProjectCodeMemoryStore+ProjectIdentity.swift:4`): explicit map → git root →
  hashed-path provisional with a doctor warning. `.burnbar/project-id` is read and
  **surfaced for confirmation**, never auto-applied; `project adopt <id>` prints the id and
  the memories it would join and requires an explicit yes. Explicit id travels in the sealed
  `projectID`.
  Validate: a mapped folder on two devices yields one doc id; unmapped keeps today's
  behavior; a provisional project surfaces the warning; **red-team: a cloned repo whose
  dotfile names another project's id changes nothing until the member adopts it.**

*(A5 deleted — see KD8.)*

### Slice 2 — Sync correctness (Phase A, platforms + hygiene)

- **A6 — Windows codec v2 is a correctness fix, not a parity chore.**
  `MemoryCloudFactCodec.cs:36`, `:53` write payload v1 and `DecodeAuthority` (`:66-81`)
  drops `validTo` and `supersededBy` — a Windows device opening a v2 **retired** Mac fact
  materialises it as **active**. Mirror the full v2 field set (`validTo`, `supersededBy`,
  `tags`, `bodyHash`, `projectID`, `engineScope`, plus A1's optional members) in both
  `EncodeFact` and `Decode`/`Open`, with round-trip tests against fixtures produced by the
  Swift sealer. Add a case asserting **a retired Swift-sealed fixture decodes as retired**.
  C# stays the parity oracle: any sealed-field change updates both.

- **A7 — Doctor prune pass for sync ledgers, naming both watermarks.** Checks: (1)
  watermark sanity across **both** ledgers — the engine's `sync_state`
  (`store.py:193-199`) and the app's `remote_sync_watermarks` `memory_facts` kind
  (`RemoteSyncWatermarkStore.swift:16, 49`) — including *transport watermark ahead of
  anything the engine ever applied*; (2) orphan `agent_memory_bodies`; (3) parked
  supersedes; (4) receipt coverage; (5) `UNRESOLVED_GAP`. Report codes first; `--apply`
  under the KD5 safety rule.
  Validate: a fixture store with all five conditions reports exactly five codes; `--apply`
  leaves a clean re-run and never touches rows referenced by un-uploaded work (assert with a
  staged in-flight upload); a fixture with a stranded transport watermark and a healthy
  engine watermark is reported, not silently passed.

- **E18a — unbreak the Linux build (one line, rides with A).** `memoryEgress` is Darwin-only
  at `OpenBurnBarDaemonServer.swift:695` (the `#if os(Linux)` block ends at `:679`) while
  `Linux/OpenBurnBarHTTPGatewayServerLinux.swift:142-155` has no such parameter. Either
  guard the argument or add an accepted-and-ignored `memoryEgress` parameter to the Linux
  gateway actor's init with a `TODO(E18b)`. Reproduce on `main` first. **Until E18b is
  green, the Linux daemon refuses to start the gateway when memory egress is configured,
  rather than serving unenforced** — a Linux daemon that builds while enforcing nothing is
  worse than an honest build failure.

### Slice 3 — Visibility (Phase B)

- **B8 — memory timeline.** Read API over `memory_history` (revisions, writing device via
  `writer_device`/`meta_json`, last-helped timestamp) + an app view per memory. The API
  **scopes by project itself** — `history()` is unscoped (`_read.py:1169-1173`) and this
  surface must not inherit that. "Last helped", in order: latest audit recall-serve event if
  that coverage verifies, else latest history event; if recall-serve logging is missing, add
  it in the recall path first (verify at implementation; do not assume).
- **B9 — "why did I get this": daemon half only.** The engine half **ships**
  (`_read.py:226-236`, returned at `:257`). Remaining: the daemon ranker
  (`BurnBarMemoryRanking.swift`) returns the same breakdown, and the app shows one
  explanation line. Verify which ranker serves the app UI and instrument that path first.
  No scoring change — pure exposure.
- **B10 — review inbox names the gate.** Thread the `gate.py` verdict + reason through to
  `MemoryReviewInboxModel`/`View` so each item says which gate fired and why.
- **B11 — per-project health card.** Aggregate doctor codes + analytics counters per project
  into one card (counts by severity; last pull / marker age once E19 lands). No new app
  table. Validate: the card on a fixture project matches doctor JSON exactly.

### Slice 4 — Capture (Phase C)

- **C12 — session-start briefing pack.** Opt-in setting, token-budgeted builder reusing the
  resume-briefing consent shape (`server.py:4875-4879`); budget counted with a documented
  no-new-deps estimator (default: chars/4, calibrated in-test; reuse an in-repo tokenizer if
  one verifies); over-budget degrades to headings-only. Validate: budget=0 yields
  headings-only; consent off yields nothing.
- **C13 — collector parity (Cursor, Codex, Hermes, others).** Extend the
  `memorize_transcript.py` pattern per advertised client; Hermes reuses `hermes_proxy.py`.
  Identical contract (quarantine by default, provenance stamped); per-client golden fixture
  asserting field mapping + provenance + quarantine — not identical rows across differing
  formats.
- **C14 — guarded importer (ChatGPT / Claude.ai exports).** Strict export-schema version
  gate (unknown versions rejected, not guessed); parser → quarantine only; secret sweep on
  entry; dedupe by `(project, scope, body_hash)`; bounded batches with cap + summary; a
  human approves before anything becomes approved. Validate: an export fixture with secrets
  + dupes + an oversized batch → all quarantined, secrets flagged, dupes collapsed, cap
  respected.
- **C15 — on-demand Pro-model extraction.** Route through the #2501 model policy (member
  quota/keys, blind); stamp `extracted_by` + model id on every row; visibly labelled in
  timeline and inbox. Validate: extraction without entitlement/consent is refused
  fail-closed.

### Slice 5 — Team and organisation (Phase D)

- **D16 — team memory spaces: spec + two PRs.**
  *Spec* (the only planned design document in the program): roster **authority** — who
  writes it and under what rules, given that no client can assert membership and every
  existing escrow construct is `users/{uid}/…` (`firestore.rules:15, 1402, 2644-2646,
  3467-3470`); `team_memory_facts` collection + rules incl. red-team cases; team-bound AAD
  and doc-id derivation; per-member consent matrix; leave-team rotation semantics; and the
  two accepted semantics from KD11 stated plainly, plus the UI copy that states them.
  *PR 1*: roster authority + rules. *PR 2*: envelope + client, client-side enforcement only.
  Validate: rules red-team (non-member denied; ex-member post-rotation denied); blindness
  proof paragraph updated; UI copy asserted by a test the way the website copy gates assert
  page copy.
- **D17 — org kinds/policies as a Remote Config ceiling.** Mirror the fleet-ceiling shape
  with KD12's resolved lever: `orgCeilingResolved` seeded from the active cached RC
  snapshot at init and ANDed into the org lane; member-local memory is a separate lane.
  Validate: a ceiling-deny matrix like `MemoryCloudModelsSettingsTests`, plus a
  never-resolved test asserting the org lane is **closed** and member memory still works.

### Slice 6 — Ops, docs gates, and Linux enforcement (Phase E; parallelizable with Slice 3 except E18b)

- **E19 — sync observability, both watermarks.** Persist last-pull timestamp, **both**
  watermark ages (engine `sync_state`, app `remote_sync_watermarks`), and
  applied/rejected/parked/skipped counters to a queryable surface (daemon metrics + app
  debug row + health-card input). Persist to `engine_meta` and the daemon's existing metrics
  surface — **not a new app table** (see Constraints).
  Alert threshold on marker age is derived from `BackgroundCadenceCoordinator`'s **maximum**
  effective interval — **not** the `2 × BehaviorSettings.refreshInterval` constant at
  `BurnBarProjectCodeMemoryStore+SyncInbox.swift:63`, which Codex flagged and which the fix
  wave replaced with an independent 5-minute refresher. The marker's own max-age and the
  alert threshold derive from the same source so the two cannot drift apart.
  Name the expected floor for `skipped`: `users/{uid}/memory_facts` has accumulated chat
  memories since before PR 1 and none carry an engine `projectID`, so all of them are
  skipped on every pull (`MemoryCloudPullService.swift:96-104`, `:255-266`). A permanent
  non-zero `skipped` is expected, not a fault, and the surface must say so.
  Validate: forced rejection/park fixtures show correct counts; a stale watermark on
  *either* ledger trips the alert.
- **E20 — copy gates on `/providers` and `/security`** (two pages; `/pricing` is already
  gated at `website/package.json:18`). Add `website/scripts/test-providers-copy.mjs` and
  `test-security-copy.mjs` following the shipped sibling pattern (`test-router-copy.mjs`,
  `test-trust-copy.mjs`, `test-approved-hero-copy.mjs`, `test-demo-telemetry-copy.mjs`), and
  **wire both into the `verify` chain** (`website/package.json:61`) — that is what makes
  them CI gates (`website-ci.yml:59`). No fallback clause: the pattern exists and is live.
- **E18b — port egress enforcement into the Linux gateway (its own PR).** Add purpose-header
  parsing, caller authorisation, the evaluate / deny / record calls at the three Darwin call sites, and denial
  response shaping to
  `Linux/OpenBurnBarHTTPGatewayServerLinux.swift`'s route pipeline, mirroring
  `OpenBurnBarHTTPGatewayServer+RoutePipeline.swift:111-126`, `:209-222`, `:750-762` and
  `+Connection.swift:163-164` without importing `Network`. The enforcer itself is already
  portable (`Memory/BurnBarMemoryEgressEnforcer.swift:1-2`, 129 lines) and is reused
  unchanged. Add the Linux gateway test filter. Only when this is green may the Linux daemon
  serve the gateway with memory egress configured, and only then is any blindness claim
  credible on Linux.

## Validation Plan

- **Per-slice table** (unchanged in shape, corrected in content): pytest on **3.11** (the CI
  gate) excluding `test_domain_core_cloudvault.py`, with a local 3.12 courtesy run;
  `ruff check` + `ruff format`; daemon `swift test --filter "Memory|Gateway|RPCCapability"`;
  touched app test classes via `scripts/test-openburnbar-app.sh`; the Firestore rules job;
  `xcodegen generate` + pbxproj drift check; debt ratchets (including
  `scripts/debt/check-core-target-membership-budget.sh`); `gitleaks detect
  --log-opts=origin/main..HEAD`.
- **App-layer classes are part of the table, not an afterthought.** The Python convergence
  simulation feeds `merge_remote` directly and never runs the Swift transport, which is
  where nine of the ten #2519 findings live. Every A-slice PR runs
  `MemoryCloudPullServiceTests`, `MemoryCloudSyncDomainTests`,
  `MemoryDeviceSyncSettingsTests` and `BurnBarProjectCodeMemoryStoreTests`.
- **Convergence proof** (A1/A2): extend the *existing*
  `test_three_replicas_converge_on_an_identical_active_set`
  (`tests/test_memory_blind_sync.py:174`) rather than writing a new one — add lineage
  fast-forward, gap timeout with persisted-queue restart, receipt-before-fact arrival, and
  a stale-push replay. Run twice for idempotence.
- **Codec parity** (A6): Swift-sealed fixtures opened by the C# codec and vice versa in CI,
  including a retired fixture.
- **Highest-risk validation** is no longer the convergence sim (it exists and passes) but
  the **transport**: a test that a stale push cannot overwrite a newer remote revision, and
  that a permanently-invalid document does not pin the first page. Both live in
  `MemoryCloudSyncDomainTests` / `MemoryCloudPullServiceTests` and both are A-1 acceptance.
- **The Mac app build is nightly, not a merge gate.** Every slice merges `main` and compiles
  the app test target locally before the PR opens.

## Risks / Rollback

1. **Stale-push overwrite defeats the whole of Phase A.** `syncApprovedMemories` uploads
   every eligible fact with an unconditional `setData(merge: true)`
   (`KnowledgeSyncService.swift:592`) with no comparison against the document's existing
   `updatedAt`. A device holding a stale mirror overwrites a newer peer's ciphertext before
   any pull can observe it, so the engine's LWW — and any lineage built on it — never sees
   the winning revision. A1 must not open until the conditional write lands (A-1, thread
   `…ffqQO`).
2. **Clock skew is load-bearing.** `updatedAt` is device-authored and is simultaneously the
   LWW key (`_sync.py:88-92`), the transport cursor (`MemoryCloudPullService.swift:195-199`)
   and the idempotence key. One clock-forward device strands correctly-timed later writes
   below the watermark. A1 deepens the dependence; the transport half is separated onto a
   15-minute skew re-scan in A-1 (thread `…ffqQF`) with the server-ordered `ingestedAt` stamp as the named follow-up, and sealed `updatedAt` remains LWW-only.
3. **A permanent `projectIdentityMissing` floor.** Pre-PR-1 chat memories in
   `users/{uid}/memory_facts` carry no engine `projectID` and are skipped on every pull
   (`MemoryCloudPullService.swift:96-104`, `:255-266`). E19 must name that floor or
   operators will read it as a fault.
4. **`history()` is unscoped by project** (`_read.py:1169-1173`) — any caller with a memory
   id reads another project's revision bodies and `meta`. Bodies are untrusted-wrapped
   (`server.py:1857-1877`), so injection is handled; **disclosure is not**. KD9 adds
   `writer_device` to that surface, so B8 scopes its own read API and does not widen the
   hole.
5. **The consent marker outlives the app by design**
   (`BurnBarProjectCodeMemoryStore+SyncInbox.swift:47-63`). Every new background surface the
   plan adds (C12 briefing pack, E19 metrics) widens the window in which the daemon acts on
   a marker no live gate is backing. Each such surface states which gate backs it and
   re-checks the generation (`MemoryDeviceSyncInboxGuard.swift:124`).
6. **`ENGINE_SCHEMA_VERSION` is roll-forward-only.** The draft's "rollback is a plain
   revert" is false for the engine half (design spec §9). Any A-slice engine bump inherits
   that; a column rename inherits it permanently, which is why KD8 keeps the `sync_state`
   names.
7. **Sealed field additions**: forward-safe only after the KD3 tolerance gate passes on
   Swift, Python and C#, at a **fixed** version. Rules need no change because the payload
   version is inside the ciphertext (`firestore.rules:1098-1128` governs the envelope, not
   the payload). Rollback for the Swift/C# half is a plain revert; the engine half is not.
8. **Team key distribution (D16)** can fail closed into "no team sync" without affecting
   member sync — behind its own entitlement + toggle, so a design miss cannot strand member
   data. The roster authority is new server-side surface and carries its own review.
9. **Linux (E18a/E18b)**: E18a is a one-line build fix and must not be allowed to imply
   enforcement. The gateway refuses to serve with memory egress configured until E18b lands.
10. **Kernel LOC ceiling.** A1, A2, A6, B8, E19 and D16 all add Swift contracts against a
    leaf with ~one file and ~134 lines of headroom
    (`scripts/debt/check-core-target-membership-budget.sh:139-145`). A slice that needs more
    argues for a new leaf in its PR body rather than raising Kernel's 54,000.
11. **New app tables cost eight surfaces.** E19/B11/D16 are priced without one; if any of
    them later needs a table, the PR carries all eight or does not open.

## Open Questions

None blocking. Four items verify at implementation with fallbacks already specified:
recall-serve audit coverage (B8 — add logging if missing), which ranker serves the app UI
(B9 — instrument that one first), whether A7's doctor pass needs indexed receipt scans
(KD4 — promote the `engine_meta` keys to a table only then, and say so in that PR), and
which in-repo tokenizer, if any, serves C12's budget (fallback: chars/4, calibrated
in-test). The D16 design spec is a planned work product, not an open question.

---

## Appendix A — Audit disposition

| # | Finding | Disposition |
|---|---|---|
| C1 | A1's sealed schemaVersion bump freezes the pull cursor on un-upgraded devices | **Adopted.** KD3 and A1 now ship `previousBodyHash`/`writerDevice` as optional fields at schemaVersion **2**, no bump. Tolerance gate restated as unknown-field tolerance at a fixed version, in its own packet before the field. Evidence cited: `MemoryCloudPullService.swift:427-429` → `:236-240` → `:290-296`; `constants.py:79`; `_sync.py:341-350` |
| C2 | A0 is a data migration for a defect that does not exist | **Adopted.** A0 reduced to a `canonical_body_hash()` helper + regression test + a comment separating the daemon-mirror namespace. No recompute, no migration, no "do this before A1", sub-check (a) deleted, A0 Risks bullet deleted |
| C3 | KD4's synthesized retired record cannot merge and re-uploads forgotten ciphertext | **Adopted.** KD4 rewritten to pull-side receipt application over the existing `memory_forget_receipts` collection; "the uploader synthesizes the retired sealed record" deleted; "receipt check precedes chain check" kept verbatim in spirit; the `forget_receipts` table deferred to A7's actual need |
| C4 | E18 mis-scoped by an order of magnitude | **Adopted.** Split into E18a (one-line `memoryEgress` parameter on the Linux gateway actor, Slice 2) and E18b (port enforcement into `Linux/OpenBurnBarHTTPGatewayServerLinux.swift`'s route pipeline, own PR, Slice 6). Linux refuses to serve the gateway with egress configured until E18b. Risks bullet corrected |
| C5 | KD7's adopt-in-folder dotfile is a cross-project scope-confusion primitive | **Adopted.** KD7 is explicit adoption only: dotfile read but never auto-applied, `project adopt <id>` with confirmation. Red-team case added to A4 validation |
| I6 | Plan silent on all ten #2519 findings; its validation would catch none | **Adopted.** New **A-1** opens Slice 1, listing all ten by thread id as *verify landed* acceptance; the per-slice table now names `MemoryCloudPullServiceTests`, `MemoryCloudSyncDomainTests`, `MemoryDeviceSyncSettingsTests`, `BurnBarProjectCodeMemoryStoreTests` |
| I7 | Two watermarks; A7 and E19 see one | **Adopted.** A7 names both ledgers and adds "transport ahead of anything applied"; E19 reports both and trips on either |
| I8 | Quarantined remote bodies embedded off-device | **Adopted.** New **A-2**, marked already-fixed-on-#2519 / verify landed, with the zero-provider-calls acceptance |
| I9 | A3 forks an alias mechanism that exists | **Adopted.** A3 resolves through `_alias_target`; `memory_aliases` table deleted from KD6 and from A3 |
| I10 | KD8 false; the `sync_state` rename is now non-revertable | **Adopted.** KD8 removed; replaced with "keep the names", the roll-forward-only doctrine moved into Constraints and Risks; A5 deleted from the work plan |
| I11 | KD3's chain rule bricks current writers and duplicates shipped fork handling | **Adopted.** "Reject updates lacking `previousBodyHash`" deleted; "genesis-only omission" deleted; lineage is advisory for fork detection and LWW-on-`sync_mark` stays authoritative; shipped fork handling (`_sync.py:698-716`) explicitly not re-implemented |
| I12 | KD12 fails open on a device that never resolved the ceiling | **Adopted.** KD12 rewritten to the closed-until-resolved precedent (`MemorySettings.swift:257-270`), `orgCeilingResolved` seeded from the active cached snapshot, no max-age; fail-soft applies only to member-local memory that was never org-gated |
| I13 | KD11 mis-states the escrow pattern and imports the wrong trust assumption | **Adopted.** KD11 rewritten: roster is NEW design needing a named membership authority; both semantics (join-reads-history, leave-protects-future-only) stated for spec and UI; consent demoted to a display/contribution control; D16 budgeted as spec + two PRs |
| I14 | Kernel LOC ceiling exhausted, unmentioned | **Adopted.** Constraints state the 191/54,000 ceiling must not be raised and route new contracts to `OpenBurnBarProjectCodeContracts`; Risks item 10 names the six slices that press on it |
| I15 | A new app table costs ~20 files across eight surfaces | **Adopted.** Constraints enumerate the eight surfaces; E19 explicitly persists to `engine_meta` + daemon metrics instead; B11 and D16 add no table |
| I16 | E19 reproduces the constant Codex flagged | **Adopted.** E19's threshold derives from `BackgroundCadenceCoordinator`'s maximum effective interval, from the same source as the marker's own max-age; the `2 × 600` constant at `…+SyncInbox.swift:63` is named as the thing not to reuse, and the fix wave's independent 5-minute refresher is recorded in Context |
| M17 | Stale `Co-Authored-By` trailer | **Adopted.** `Claude Fable 5.1 <noreply@anthropic.com>` |
| M18 | CI pytest is 3.11 only | **Adopted.** Constraints and the validation table say 3.11 is the gate; 3.12 is local courtesy |
| M19 | `sealedMemory.schemaVersion >= 2` is the envelope, not the payload | **Adopted.** Context and Risks now give the correct reason for "no rules change": the payload version is inside the ciphertext |
| M20 | E20 is two pages and the fallback is dead | **Adopted.** E20 covers `/providers` and `/security` only, follows `website/scripts/test-*-copy.mjs`, and wires both into the `verify` chain; the downgrade clause is deleted |
| M21 | B9's engine half is done | **Adopted.** B9 is the daemon ranker plus the app surface; the engine's `why` at `_read.py:226-236`/`:257` recorded in Context and Appendix B |
| M22 | Restate "Context And Current Facts" against #2519 | **Adopted.** Section rewritten end to end against `e4b8f8abf1`; the false verification claim is explicitly withdrawn |
| M23 | A6 is a correctness bug, not a parity chore | **Adopted.** A6 reframed around the retired-fact-materialises-as-active defect (`MemoryCloudFactCodec.cs:36`, `:53`, `:66-81`) with a retired-fixture round-trip case |

Nothing in the audit was rejected. Items kept from §6 of the audit (unchanged in substance):
receipt-before-chain ordering; receipts keyed by id **and** convergence identity; the
re-remember escape rule; report-first doctor with a bounded `--apply` asserted against a
staged in-flight upload; a reader-tolerance gate before any new sealed field, with C# as the
parity oracle; sequencing Linux egress with A rather than after it; a design spec before
D16's code; "no invented machinery" and a named verify-at-implementation fallback for every
uncertainty; quarantine-by-default with provenance stamped visibly on every new capture path.

---

## Appendix B — What #2519 already delivers (do not re-implement)

| Shipped | Where |
|---|---|
| `merge_remote` and the whole remote-merge path (962 new lines) | `memory_engine/_sync.py:496` |
| `sync_state` table + `SCHEMA_MIGRATIONS` v2, `ENGINE_SCHEMA_VERSION` 1→2 | `store.py:193-199`, `:275-284` |
| Additive-only tolerance for a newer store | `store.py:267-336` |
| Alias namespace `memory_alias:<foreign_id>` + `_alias_target` + `_local_memory_id` + purge | `_sync.py:161-190`, `:192-218`, `_read.py:1086-1089` |
| Forget receipts keyed by id and by convergence identity | `_sync.py:134-165` |
| `sync_identity:*` and `sync_mark:*` ledgers | `_sync.py:229-255`, `:296` |
| Receipt check preceding chain check | `_sync.py:610-632` |
| Re-remember lifts the receipt (+ test) | `_sync.py:617-620`; `tests/test_memory_blind_sync.py:446` |
| Fork resolution: alias, retire loser into holder, reinforce, under LWW on `sync_mark` | `_sync.py:698-716`, `:641-664` |
| Parked supersedes | `_sync.py:698-716` |
| Three-replica convergence simulation + 32 sibling tests | `tests/test_memory_blind_sync.py:174` |
| Sealed payload **v2**: `validTo`, `supersededBy`, `tags`, `bodyHash`, `projectID`, `engineScope`, all optional | `KnowledgeSyncService.swift:509-546`, `currentSchemaVersion = 2` at `:511` |
| `MemoryCloudPullService` (~500 lines): verification, parking, watermark discipline, rejection freeze | `MemoryCloudPullService.swift` |
| Forget cloud channel: `memory_forget_receipts` write + fact delete, and its rules | `KnowledgeSyncService.swift:601-618`; `firestore.rules:3263-3300` |
| Device sub-toggle, consent marker, daemon-side marker enforcement with max age | `MemorySettings.swift`, `PrivacyIndexingSettingsView.swift`, `BurnBarProjectCodeMemoryStore+SyncInbox.swift:47-63` |
| Generation-guarded withdrawal (marker + rows in one transaction, commit only if generation matches) | `MemoryDeviceSyncInboxGuard.swift:46-48`, `:124`, `:140`, `:220` |
| App transport watermark store with a `memory_facts` kind | `RemoteSyncWatermarkStore.swift:16`, `:49` |
| Engine recall `why` breakdown returned on every hit | `_read.py:226-236`, `:257` |
| `agent_memory_inbox` table with all eight migration surfaces done | see `docs/DATABASE_OPERATIONS.md:197-207` and the #2519 diff |
| `OpenBurnBarProjectCodeContracts` leaf carved out when Kernel hit its ceiling | `scripts/debt/check-core-target-membership-budget.sh:139-145` |
| Roll-forward-only doctrine for the engine schema half | design spec §9 |
| `docs/PRIVACY.md` device-sync section | #2519 diff |

In flight on #2519 (the Codex fix wave — **verify landed**, do not rebuild): composite
`(updatedAt, documentID)` cursor; 15-minute skew re-scan (server-ordered stamp is a follow-up); terminal-rejection
ledger; atomic inbox-purge + watermark rewind; independent 5-minute consent-marker
refresher; account-wide consent in the toggle handler; conditional (monotonic
`updatedAt`, remote-not-older) cloud write; quarantine excluded from hosted embedding;
cross-project bodies removed from the inbox tool response; receipt channel read by the pull.
