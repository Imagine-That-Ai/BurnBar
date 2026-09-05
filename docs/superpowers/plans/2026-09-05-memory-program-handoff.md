# Memory program — hand-off packets, 2026-09-05

Companion to [`2026-09-05-memory-program-revised.md`](2026-09-05-memory-program-revised.md).
Each packet below is one PR-sized unit (≤ ~400 changed lines) written to be executed by a
coding agent with **no memory of any other packet**. Everything a packet needs is inside it
or inside the two shared sections at the top.

**Router warning, read before dispatching anything.** The repo's CLI router
(`~/.agent/runs/mailbox/runbooks/CLI-GUY.md`) says **"Never Spark."** The `SPARK-OK` label
below means only *"this packet is mechanical and fully specified enough that a modest model
could execute it"* — it is not a recommendation to override the router. The operator makes
that call knowingly. When in doubt, a `SPARK-OK` packet routes to Grok build.

Route counts: **8 SPARK-OK · 9 ROUTE: Codex · 11 ROUTE: Grok build** (28 packets).

---

## How to run one packet

```bash
# 0. one packet at a time; one Xcode job at a time on this machine.
cd "/Volumes/Samsung NVME/offloaded-home/Documents/Projects/BurnBar"
git fetch origin && git switch -c <branch-from-packet> origin/main

# 1. hand the packet to the routed CLI.
#    SPARK-OK packets (a modest model; the router still says "Never Spark" — operator's call).
#    pi syntax: pi [options] [@files...] [message]. Muse Spark 1.3: add its entry to
#    ~/.pi/agent/models.json beside muse-spark-1.2-contributor first, then use its id here.
pi --provider meta-ai --model muse-spark-1.2-contributor --thinking high --print \
   @docs/superpowers/plans/2026-09-05-memory-program-handoff.md \
   "Execute packet <PACKET-ID> exactly as written. Read 'How to run one packet' and the shared command block first. Touch only the files the packet lists. Run the packet's commands and the shared gates; if any fails, stop and report the failure verbatim instead of working around it. Commit with the trailer given, do not push, and end by printing the PR title and body from the skeleton."
#   ROUTE: Codex      -> the Codex CLI, same @file + message
#   ROUTE: Grok build -> the Grok build lane (repo default), same @file + message

# 2. run the packet's own command block (below), then the shared gates.
# 3. open the PR with the skeleton below, label `factory-review`, and move on.
```

### Shared command block (run what the packet's own block names, plus these)

```bash
export DEVELOPER_DIR="/Users/dewclaw/Xcode-26.6.app/Contents/Developer"
REPO="/Volumes/Samsung NVME/offloaded-home/Documents/Projects/BurnBar"

# Python (engine / MCP) — 3.11 is the CI gate; 3.12 is a local courtesy only.
cd "$REPO/tools/openburnbar-mcp"
python3.11 -m pytest -q --ignore=tests/test_domain_core_cloudvault.py
python3.12 -m pytest -q --ignore=tests/test_domain_core_cloudvault.py   # courtesy, not a gate
ruff check . && ruff format --check .

# Daemon (Swift package). Stage SQLCipher before a --skip-build run or bundles fail to dlopen.
cd "$REPO/OpenBurnBarDaemon"
swift test --filter "Memory|Gateway|RPCCapability"

# App target (nightly in CI — so it MUST be run locally before every PR).
cd "$REPO"
OPENBURNBAR_APP_TEST_FILTERS="OpenBurnBarTests/<ClassA>,OpenBurnBarTests/<ClassB>" \
  scripts/test-openburnbar-app.sh

# Lint + generated project + ratchets + secrets
swiftlint --strict
xcodegen generate --spec project.yml && git diff --exit-code -- OpenBurnBar.xcodeproj/project.pbxproj
scripts/debt/check-core-target-membership-budget.sh
scripts/debt/check-swift-file-size-budget.sh
gitleaks detect --log-opts=origin/main..HEAD

# Website (only for E20 packets)
cd "$REPO/website" && npm run verify
```

### Standing repo rules — every packet, no exceptions

1. **Never `git stash`.** Commit to a scratch branch instead if you must set work aside.
2. **Never commit `.serena/` or `.superpowers/`.** Check `git status` before every commit.
3. **The Xcode project is generated.** Add files to `project.yml` and run
   `xcodegen generate --spec project.yml`; never hand-edit
   `OpenBurnBar.xcodeproj/project.pbxproj`. The drift check is a gate.
4. **One Xcode job at a time on this machine.** Do not start `scripts/test-openburnbar-app.sh`
   while another `xcodebuild` is running.
5. **The Mac app build is nightly, not a merge gate.** Merge `main` and run the app test
   target locally before opening the PR; the door will not catch a break for you.
6. **Commit trailer:** `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
7. **Open the PR with label `factory-review`.** Codex is the independent reviewer and the
   approval gate. Cursor / Bugbot output is not approval evidence.
8. **`OpenBurnBarKernel` is at its ceiling (191 files / 54,000 lines) and must not be
   raised** (`scripts/debt/check-core-target-membership-budget.sh:152`). New Swift wire
   contracts go to `OpenBurnBarProjectCodeContracts` (`:139-145`, `maxFiles: 2`,
   `maxLines: 1000`, ~one file and ~134 lines of headroom). More than that: argue for a new
   leaf in the PR body.
9. **Do not add an app SQLite table** unless the packet says so. One costs eight surfaces:
   both ordered migrators (app + Core), the fast-lane migration lists,
   `scripts/rollback-migration.sh` + `scripts/ci/verify-migration-rollback-catalog.test.mjs`
   + `docs/DATABASE_OPERATIONS.md:197-207` and its tripwire, `docs/SCHEMA_SQLITE.sql` DDL
   **and** hash, `WindowsSqlCipherProvisioning.{Schema,Upgrades,Metadata}.cs`, the five
   Windows test pins, the Swift pins, and the byte-compat fixture +
   `openburnbar-db-compat-vector.json` + `AgentLensTests/Support/DatabaseByteCompatVector.swift`.
10. **Do not touch `OpenBurnBarCore/Package.swift`** unless the packet says so — it is
    digest-pinned in `config/domain-core-control-plane-manifest.json:19` **and**
    `launch-evidence/libsignal-rust-core-bridge-v1.0.34.json:10,131`, and both must be
    re-pinned in the same commit.
11. **Never bump `MemoryCloudFactPayload.currentSchemaVersion` (2) or
    `REMOTE_PAYLOAD_SCHEMA_MAX` (2).** Both readers freeze/park on anything newer
    (`MemoryCloudPullService.swift:427-429`; `memory_engine/constants.py:79`). New payload
    fields are optional members at version 2.
12. **No new Python dependencies.** `ruff==0.15.17`.

### Shared PR body skeleton

```markdown
## What
<one paragraph: the packet's subject and why it is one coherent unit>

## Review map
<files, grouped, with one line each on what to look at>

## Validation
- python3.11 -m pytest -q --ignore=tests/test_domain_core_cloudvault.py  -> <result>
- ruff check . && ruff format --check .                                   -> <result>
- swift test --filter "Memory|Gateway|RPCCapability"                      -> <result>
- OPENBURNBAR_APP_TEST_FILTERS="..." scripts/test-openburnbar-app.sh       -> <result>
- swiftlint --strict / xcodegen drift / debt ratchets / gitleaks           -> <result>
<paste the new test names and their assertions>

## Invariants preserved
- No plaintext to the server; payload version unchanged at 2.
- Receipt check still precedes chain check (`_sync.py:610-632`).
- <packet-specific>

## Risks
<what could go wrong, and what the tests would catch>

## Rollback
<plain revert / roll-forward-only, and why>

## Cross-agent receipt
- saw: <PR/review/thread ids, commit SHAs>
- reaction: <what was changed in response>
- status: <MERGED | OPEN | OPEN_WITH_NAMED_BLOCKER>
- next owner: <who>

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
```

---

# Slice 1 — Sync correctness (engine + envelope)

## P1 — A-1: verify the #2519 review wave landed  · **ROUTE: Grok build**

Evidence packet, not a code packet. Nothing in Slice 1 opens a PR until this is green.

- **Files to read (do not modify):** `AgentLens/Services/CloudSync/MemoryCloudPullService.swift`,
  `MemoryCloudSyncDomain.swift`, `KnowledgeSyncService.swift`,
  `AgentLens/Services/DataStore/ControlPlaneStore+MemorySyncInbox.swift`,
  `AgentLens/Views/Settings/PrivacyIndexingSettingsView.swift`,
  `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/ProjectCodeMemory/BurnBarProjectCodeMemoryStore+SyncInbox.swift`,
  `tools/openburnbar-mcp/memory_engine/_sync.py`, `tools/openburnbar-mcp/server.py`.
- **Check each of the ten threads and record the test that proves it:**
  `…ffqQA` retirement propagation (pull reads `memory_forget_receipts`);
  `…ffqQC` quarantine excluded from embedding (`_sync.py:767`);
  `…ffqQD` composite `(updatedAt, documentID)` cursor (`:353`);
  `…ffqQF` 15-minute skew re-scan below the cursor; server-ordered `ingestedAt` stamp is a named follow-up; sealed `updatedAt` LWW-only (`:200`);
  `…ffqQJ` atomic inbox purge + transport watermark rewind, incl. the 90-day sweep (`+MemorySyncInbox.swift:219`);
  `…ffqQK` marker refresher on its own 5-minute cadence (`+SyncInbox.swift:62`);
  `…ffqQL` account-wide consent in the toggle handler (`PrivacyIndexingSettingsView.swift:891`);
  `…ffqQN` terminal rejections advance the cursor (logged once), transient ones still freeze it (`:243`);
  `…ffqQO` cloud write skipped when the remote `updatedAt` is not older than the local revision; receipts unconditional (`MemoryCloudSyncDomain.swift:290`);
  `…ffqQS` cross-project bodies out of the inbox tool response (`server.py:3218`).
- **Commands:** the shared block, with
  `OPENBURNBAR_APP_TEST_FILTERS="OpenBurnBarTests/MemoryCloudPullServiceTests,OpenBurnBarTests/MemoryCloudSyncDomainTests,OpenBurnBarTests/MemoryDeviceSyncSettingsTests"`.
- **Acceptance:** a table in the PR/issue comment mapping each thread id → the test name that
  fails if the fix is reverted. Any thread with no such test becomes a named blocker and P1b
  or a new packet is filed for it.
- **Do not touch:** anything. This packet changes no code.

---

## P1b — contingency: conditional cloud write (only if `…ffqQO` did not land) · **ROUTE: Codex**

- **Files:** `AgentLens/Services/CloudSync/MemoryCloudSyncDomain.swift` (~`:290`),
  `AgentLens/Services/CloudSync/KnowledgeSyncService.swift` (`:592` unconditional
  `setData(merge: true)`).
- **Change:** make the upload conditional on `updatedAt` (skip when the remote document is not older),
  rather than relying on push-before-pull ordering.
- **Tests to add** in `OpenBurnBarTests/MemoryCloudSyncDomainTests`:
  - `test_stale_push_does_not_overwrite_a_newer_remote_revision` — device B holds a mirror
    older than the document's current `updatedAt`; asserts the write is refused and the
    remote ciphertext is byte-unchanged.
  - `test_push_with_a_stale_vault_generation_is_refused` — asserts refusal and that no
    partial write occurred.
  - `test_monotonic_push_still_succeeds` — the happy path is not regressed.
- **Commands:** shared block with
  `OPENBURNBAR_APP_TEST_FILTERS="OpenBurnBarTests/MemoryCloudSyncDomainTests"`.
- **Acceptance:** the three tests pass; reverting the guard fails the first two.
- **Do not touch:** the pull service, the engine, the payload struct.
- **PR title:** `fix(memory-sync): skip the cloud write when the remote revision is not older`

---

## P2 — A0: `canonical_body_hash()` helper + regression test · **SPARK-OK**

- **Files:** `tools/openburnbar-mcp/memory_engine/_util.py` (add the helper),
  `_write.py:544`, `_read.py:824`, `_sync.py:463` (route through it).
- **The helper:** `def canonical_body_hash(body: str) -> str: return sha256_hex(body.lower())`
  — byte-identical behaviour to all three current sites.
- **Required comment on the helper** (verbatim intent): the daemon-mirror hash
  (`server.py:2075`, `server.py:2172`, `_admin.py:420` → `engine_meta` key
  `daemon_mirror:<id>`) is a **different, non-lowered** hash in a different namespace and
  must never be folded into this helper.
- **Tests to add** in `tools/openburnbar-mcp/tests/test_memory_engine.py`:
  - `test_all_body_hash_write_paths_agree_on_mixed_case` — writes the same body via the
    write path, the read/update path and the merge path with mixed casing; asserts one
    `memories.body_hash` value for all three.
  - `test_canonical_body_hash_is_not_the_daemon_mirror_hash` — asserts
    `canonical_body_hash("Foo") != sha256_hex("Foo")` and that
    `daemon_mirror_body_hash` is unchanged for a mixed-case body.
- **Commands:** the Python block only.
- **Acceptance:** both tests pass; `git diff` shows **zero** migration files, **zero**
  `UPDATE memories SET body_hash` statements, and no change to `_admin.py`'s hashing.
- **Do not touch:** `_admin.py` hashing, `server.py:2075`, `server.py:2172`, `engine.py`,
  `SCHEMA_MIGRATIONS`, any existing row.
- **PR title:** `refactor(memory-engine): route every memories.body_hash site through canonical_body_hash()`

---

## P3 — A1(i): unknown-field tolerance fixtures on all three readers · **ROUTE: Grok build**

Ships **before** any new payload field. Multi-language, so not Spark-eligible.

- **Files:**
  - `AgentLensTests/Fixtures/MemoryCloudFact/v2-with-unknown-member.json` (new)
  - `OpenBurnBarTests/.../MemoryCloudPullServiceTests.swift` (new case)
  - `tools/openburnbar-mcp/tests/test_memory_blind_sync.py` (new case)
  - `windows/app/OpenBurnBar.App.CloudSync.Tests/MemoryCloudFactCodecTests.cs` (new case)
- **Fixture:** a schemaVersion **2** payload carrying every shipped v2 field plus one
  unknown member (`"futureField": "x"`). Do not change `currentSchemaVersion`.
- **Tests to add:**
  - Swift `test_a_v2_payload_with_an_unknown_member_decodes_and_applies` — asserts the pull
    applies it, does **not** reject, and does **not** set `watermarkFrozen`.
  - Python `test_merge_remote_tolerates_an_unknown_payload_member` — asserts `ack=True` and
    no `PAYLOAD_TOO_NEW`.
  - C# `DecodeAuthority_ToleratesUnknownMember` — asserts the decode succeeds and the known
    fields round-trip.
- **Commands:** Python block, shared Swift blocks with
  `OPENBURNBAR_APP_TEST_FILTERS="OpenBurnBarTests/MemoryCloudPullServiceTests"`; the C# test
  via the Windows solution's usual runner (record the invocation in the PR body).
- **Acceptance:** three tests, three languages, all green, with `currentSchemaVersion` and
  `REMOTE_PAYLOAD_SCHEMA_MAX` both still `2` in the diff.
- **Do not touch:** `currentSchemaVersion`, `REMOTE_PAYLOAD_SCHEMA_MAX`, `firestore.rules`.
- **PR title:** `test(memory-sync): prove unknown-field tolerance at payload v2 on Swift, Python and C#`

---

## P4 — A1(ii): `previousBodyHash` + `writerDevice` as optional members at v2 · **ROUTE: Codex**

- **Depends on:** P2, P3.
- **Files:** `AgentLens/Services/CloudSync/KnowledgeSyncService.swift` (payload struct at
  `:509-546` and the encode site), `tools/openburnbar-mcp/memory_engine/_sync.py` (parse
  only; semantics land in P5), `memory_engine/constants.py` (no version change — assert it).
- **Rules:** the plaintext key set must not move. `previousBodyHash` and `writerDevice` live
  **inside the ciphertext**; nothing new becomes a plaintext field.
- **Tests to add:**
  - Swift `test_payload_encodes_previous_body_hash_and_writer_device_at_version_two` —
    asserts `schemaVersion == 2` in the encoded JSON.
  - Swift `test_a_payload_omitting_the_new_fields_still_decodes` (old-client fixture).
  - Rules test `test_memory_fact_plaintext_key_set_is_unchanged` — set comparison against
    `firestore.rules:3207-3224`, asserting byte-identical membership.
  - Python `test_merge_remote_reads_previous_body_hash_when_present_and_ignores_it_when_absent`.
- **Commands:** Python block, the Firestore rules job, shared Swift blocks with
  `OPENBURNBAR_APP_TEST_FILTERS="OpenBurnBarTests/MemoryCloudPullServiceTests,OpenBurnBarTests/KnowledgeSyncServiceTests"`.
- **Acceptance:** the four tests pass; the diff contains no version bump and no
  `firestore.rules` change.
- **Do not touch:** merge semantics (P5), `firestore.rules`, the Windows codec (P9).
- **PR title:** `feat(memory-sync): carry previousBodyHash and writerDevice as optional sealed fields at v2`

---

## P5 — A1(iii): lineage merge semantics — fast-forward, hold-back, `UNRESOLVED_GAP` · **ROUTE: Codex**

- **Depends on:** P4.
- **Files:** `tools/openburnbar-mcp/memory_engine/_sync.py` only.
- **Semantics (implement exactly):**
  - Absent `previousBodyHash` → no lineage advice; behave exactly as today.
  - Present and matching the current body's `body_hash` → fast-forward.
  - Present and not matching → hold in a **bounded, persisted** queue (an `engine_meta` key
    namespace, no new table), re-evaluated on every `merge_remote`; after the gap timeout,
    surface `UNRESOLVED_GAP` **and apply the existing LWW-on-`sync_mark` decision**
    (`_sync.py:641-664`) so a replica can never stall on a peer that will never send the
    missing body.
  - **Do not re-implement fork handling** — `_update_remote_row` (`_sync.py:698-716`)
    already aliases, retires the loser into the holder and reinforces.
  - **Do not** make lineage an admission gate. Never reject an update for lacking the field.
- **Tests to add** in `tools/openburnbar-mcp/tests/test_memory_blind_sync.py`:
  - `test_a_matching_previous_body_hash_fast_forwards`
  - `test_a_mismatching_previous_body_hash_is_held_then_resolved_by_lww_at_the_timeout`
  - `test_the_hold_back_queue_survives_a_restart_and_reports_exactly_one_unresolved_gap`
  - `test_an_update_without_previous_body_hash_is_applied_normally`
  - extend `test_three_replicas_converge_on_an_identical_active_set` (`:174`) with an
    out-of-order lineage delivery; assert identical active sets and idempotence on a
    second run.
- **Commands:** the Python block.
- **Acceptance:** five green tests; the gap fixture yields **exactly one**
  `UNRESOLVED_GAP`; no new SQLite table in the diff; `ENGINE_SCHEMA_VERSION` unchanged.
- **Do not touch:** `store.py` schema, `_update_remote_row`'s fork path, the Swift side.
- **PR title:** `feat(memory-engine): advisory previousBodyHash lineage with a persisted hold-back queue`

---

## P6 — A2: pull-side forget-receipt application · **ROUTE: Codex**

- **Depends on:** P1 (thread `…ffqQA`).
- **Files:** `AgentLens/Services/CloudSync/MemoryCloudPullService.swift` (second pass),
  `AgentLens/Services/DataStore/ControlPlaneStore+MemoryForget.swift`,
  `tools/openburnbar-mcp/memory_engine/_sync.py` (application entry only).
- **Change:** a second pass over `users/{uid}/memory_forget_receipts`
  (rules `firestore.rules:3263-3300`) above its **own** watermark; match each receipt's
  `memoryIdHmac` against the engine ids this device holds; apply as a local forget +
  receipt through the existing `forget_receipt:*` / `forget_identity:*` keys
  (`_sync.py:134-165`). **No new engine table. Never upload a retired body** — the existing
  delete-doc-and-write-receipt path (`KnowledgeSyncService.swift:601-618`) stays, and
  `ControlPlaneStore+MemoryForget.swift:227`'s `validTo == nil` upload filter stays.
- **Tests to add:**
  - Swift `test_a_forget_receipt_pass_applies_a_local_forget` (`MemoryCloudPullServiceTests`)
  - Swift `test_the_receipt_watermark_is_independent_of_the_fact_watermark`
  - Python `test_a_receipt_arriving_before_the_fact_it_retires_still_wins`
  - Python `test_a_reworded_body_under_a_forgotten_id_stays_forgotten`
  - Python `test_a_forgotten_body_replayed_under_a_foreign_engine_id_stays_forgotten`
  - Python `test_a_deliberate_re_remember_reactivates_under_a_new_memory_id`
- **Commands:** Python block; app block with
  `OPENBURNBAR_APP_TEST_FILTERS="OpenBurnBarTests/MemoryCloudPullServiceTests"`.
- **Acceptance:** six green tests; the diff contains **no** code that uploads a document for
  a row with `validTo != nil`, and no synthesized retired record anywhere.
- **Do not touch:** the upload path's retirement filter, `firestore.rules`, the payload struct.
- **PR title:** `feat(memory-sync): apply forget receipts on the pull side instead of re-uploading retired bodies`

---

## P7 — A3: alias-aware `get` / `forget` / `recall` (no new table) · **ROUTE: Grok build**

- **Files:** `tools/openburnbar-mcp/memory_engine/_read.py` (`get`, `recall`),
  `_write.py` (`forget`, local fold), `_sync.py` (reuse `_alias_target` at `:178-190`).
- **Change:** all three read/write entry points resolve their id argument through the
  existing `_alias_target` before lookup. A local fold writes the same
  `memory_alias:<folded>` key (`_sync.py:167-179`) and a `memory_history` entry.
  **Create no `memory_aliases` table** — a second alias store is a divergence bug.
- **Tests to add** in `tools/openburnbar-mcp/tests/test_memory_blind_sync.py`:
  - `test_a_folded_id_resolves_in_get_and_recall_on_the_folding_device`
  - `test_a_folded_id_resolves_on_a_second_device_via_the_supersede_chain`
  - `test_forget_via_an_alias_removes_the_canonical_row`
  - `test_a_double_fold_is_a_no_op`
- **Commands:** the Python block.
- **Acceptance:** four green tests; `grep -rn "memory_aliases" tools/` returns nothing;
  `SCHEMA_MIGRATIONS` unchanged.
- **Do not touch:** `store.py` schema, the `memory_alias` purge at `_read.py:1086-1089`.
- **PR title:** `feat(memory-engine): resolve get/forget/recall through the existing memory_alias namespace`

---

## P8 — A4: explicit project identity with confirmed adoption · **ROUTE: Codex**

- **Files:** `tools/openburnbar-mcp/memory_engine/store.py` (`resolve_project`, `:431-434`,
  `:448-460`), `tools/openburnbar-mcp/project_code_memory.py` (`:324-346`),
  `OpenBurnBarDaemon/.../BurnBarProjectCodeMemoryStore+ProjectIdentity.swift`,
  plus the `project adopt` CLI entry in `tools/openburnbar-mcp/server.py`.
- **Resolution order (both implementations, identically):** explicit map → git root →
  hashed path flagged **provisional** with a doctor warning.
- **Security requirement — the point of the packet:** a `.burnbar/project-id` dotfile is
  **read but never auto-applied**. A dotfile naming an id this device does not already map
  surfaces a one-time confirmation; `project adopt <id>` prints the id and the memories it
  would join and requires an explicit yes. A dotfile naming an id already mapped to that
  path is a no-op. Repository contents must never silently re-scope a folder's memories.
- **Tests to add:**
  - Python `test_a_mapped_folder_resolves_to_one_project_id_on_two_devices`
  - Python `test_an_unmapped_folder_keeps_the_git_derived_identity`
  - Python `test_a_provisional_hashed_path_project_raises_the_doctor_warning`
  - Python **red team** `test_a_cloned_repo_whose_dotfile_names_another_project_changes_nothing_until_adopted`
    — asserts recall in the hostile folder returns none of the victim project's rows and
    that no write lands under the victim id.
  - Swift `test_daemon_project_identity_follows_the_same_override_order`
    (`BurnBarProjectCodeMemoryStoreTests`).
- **Commands:** Python block; app block with
  `OPENBURNBAR_APP_TEST_FILTERS="OpenBurnBarTests/BurnBarProjectCodeMemoryStoreTests"`;
  daemon `swift test --filter "Memory"`.
- **Acceptance:** five green tests, the red-team one included; no code path applies a
  dotfile without an explicit adopt.
- **Do not touch:** `server.py:3100-3107` (inbox scoping — separate packet),
  `_read.py:1169-1173` (`history` scoping — P12 owns it).
- **PR title:** `feat(memory): explicit project identity with confirmed adoption, never auto-applied dotfiles`

---

# Slice 2 — Platforms and hygiene

## P9 — A6: Windows codec v2 (correctness fix) · **SPARK-OK**

- **Files:** `windows/app/OpenBurnBar.App.CloudSync/MemoryCloudFactCodec.cs` (`:36`, `:53`
  write v1; `DecodeAuthority` `:66-81` drops `validTo`/`supersededBy`), plus its test file.
- **The defect this fixes:** a Windows device opening a v2 **retired** Mac fact materialises
  it as **active**.
- **Change:** mirror the full v2 field set in **both** directions — `validTo`,
  `supersededBy`, `tags`, `bodyHash`, `projectID`, `engineScope`, plus P4's
  `previousBodyHash` and `writerDevice`. Write `SchemaVersion: 2`. Do **not** exceed 2.
- **Fixtures:** produced by the Swift sealer, checked in beside the C# tests.
- **Tests to add:**
  - `EncodeFact_WritesSchemaVersionTwoWithEveryV2Field`
  - `DecodeAuthority_PreservesValidToAndSupersededBy`
  - `Decode_ARetiredSwiftSealedFixture_MaterialisesAsRetired` ← the correctness case
  - `RoundTrip_SwiftSealedFixture_MatchesFieldForField`
- **Commands:** the Windows solution's test runner (record the invocation in the PR body);
  no Swift or Python change, so the shared Swift blocks are not required — say so in the PR.
- **Acceptance:** four green tests; reverting `DecodeAuthority` fails the third.
- **Do not touch:** `currentSchemaVersion` on the Swift side, the Swift sealer, the engine.
- **PR title:** `fix(windows-codec): decode payload v2 so a retired fact does not materialise as active`

---

## P10 — A7: doctor sync-ledger pass over both watermarks · **ROUTE: Grok build**

- **Files:** `tools/openburnbar-mcp/memory_engine/_admin.py` (doctor at `:536`, findings
  `:555-600`), `memory_engine/_sync.py` (read-only helpers).
- **Five checks, report-first with codes:** (1) watermark sanity across **both** ledgers —
  the engine's `sync_state` (`store.py:193-199`) and the app's `remote_sync_watermarks`
  `memory_facts` kind (`RemoteSyncWatermarkStore.swift:16,49`) — including *transport
  watermark ahead of anything the engine ever applied*; (2) orphan `agent_memory_bodies`;
  (3) parked supersedes; (4) receipt coverage; (5) `UNRESOLVED_GAP`.
- **`--apply` bound:** prunes only orphans older than the grace period **and** unreferenced
  by any un-uploaded row or receipt; parked supersedes only after N days. Nothing else.
- **Tests to add** in `tools/openburnbar-mcp/tests/test_memory_doctor.py`:
  - `test_a_fixture_with_all_five_conditions_reports_exactly_five_codes`
  - `test_apply_leaves_a_clean_re_run`
  - `test_apply_never_touches_rows_referenced_by_a_staged_in_flight_upload`
  - `test_a_stranded_transport_watermark_with_a_healthy_engine_watermark_is_reported`
- **Commands:** the Python block.
- **Acceptance:** four green tests; `--apply` on the staged-upload fixture deletes zero rows.
- **Do not touch:** the aux-scan cursor walk's existing codes; no new table.
- **PR title:** `feat(memory-doctor): report-first sync-ledger pass across both watermarks`

---

## P11 — E18a: unbreak the Linux daemon build · **SPARK-OK**

- **Files:** `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarDaemonServer.swift:695`
  (passes `memoryEgress:` outside the `#if os(Linux)` block that ends at `:679`) and
  `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/Linux/OpenBurnBarHTTPGatewayServerLinux.swift:142-155`
  (init has no such parameter).
- **Change, one of two — pick the smaller diff:** guard the argument, **or** add an
  accepted-and-ignored `memoryEgress` parameter to the Linux gateway actor's init with a
  `// TODO(E18b): enforcement is not ported yet — see the revised plan, Slice 6.`
- **Also required (small, in this packet):** the Linux daemon **refuses to start the
  gateway** when memory egress is configured, with a clear log line. A Linux daemon that
  builds while enforcing nothing is worse than an honest build failure.
- **Tests to add:** `test_linux_gateway_refuses_to_start_when_memory_egress_is_configured`
  in the Linux daemon test target.
- **Commands:** reproduce on `main` first (Docker Linux toolchain, per
  `docs/linux-port/`), then build the branch; `swift test --filter "Gateway"` on Darwin.
- **Acceptance:** the Linux build is green; the refusal test passes; the diff is under ~40
  lines.
- **Do not touch:** `BurnBarMemoryEgressEnforcer.swift` (already portable, 129 lines), the
  Darwin route pipeline, anything else in the 1816-line Linux gateway — that is P27.
- **PR title:** `fix(daemon-linux): unbreak the build by accepting memoryEgress, and refuse the gateway until enforcement is ported`

---

# Slice 3 — Visibility

## P12 — B8: memory timeline read API + app view · **ROUTE: Grok build**

- **Files:** `tools/openburnbar-mcp/memory_engine/_read.py` (new project-scoped timeline
  read; `history()` at `:1169-1173` is unscoped and must not be widened),
  `tools/openburnbar-mcp/server.py` (tool surface), `AgentLens/Views/Memory/` (the view).
- **Requirement:** the new read API **scopes by project itself**. Do not inherit
  `history()`'s missing project scope.
- **"Last helped", in order:** the latest audit recall-serve event if that coverage
  verifies; else the latest history event. If recall-serve logging is missing, add it in the
  recall path in this packet.
- **Tests to add:** `test_timeline_returns_revisions_in_order`,
  `test_timeline_reports_the_writing_device_from_meta_json`,
  `test_timeline_is_scoped_by_project_and_refuses_a_foreign_memory_id`,
  `test_last_helped_falls_back_to_history_when_no_recall_serve_event_exists`.
- **Commands:** Python block; app block with the touched view's test class.
- **Acceptance:** four green tests; the foreign-id test asserts *no* body or meta is
  returned.
- **Do not touch:** ranking, `history()`'s existing signature, any app table.
- **PR title:** `feat(memory): project-scoped memory timeline with device attribution`

---

## P13 — B9: daemon ranker `why` + one app explanation line · **ROUTE: Grok build**

- **Note:** the engine half already ships (`_read.py:226-236` builds `lexicalRank`, `bm25`,
  `semanticRank`, `cosine`, `salience`, `recency`, `rerankScore`, `reranker`; `:257`
  returns it on every hit). **Do not re-implement it.**
- **Files:** `OpenBurnBarDaemon/.../ProjectCodeMemory/BurnBarMemoryRanking.swift` (return the
  same breakdown), the recall response contract (put any new Swift contract in
  `OpenBurnBarProjectCodeContracts`, not Kernel), and one app view line.
- **First:** verify which ranker serves the app UI and instrument that path first; state the
  finding in the PR body.
- **Tests to add:** `test_daemon_ranking_returns_the_same_why_components_as_the_engine`,
  `test_the_app_renders_one_explanation_line_per_hit`.
- **Commands:** daemon `swift test --filter "Memory"`; app block with the touched class;
  `scripts/debt/check-core-target-membership-budget.sh`.
- **Acceptance:** two green tests; **no scoring change** — a fixture recall returns the same
  ordering before and after.
- **Do not touch:** `_read.py` ranking, any weight or constant.
- **PR title:** `feat(memory): expose the daemon ranker's why-breakdown and show one explanation line`

---

## P14 — B10: review inbox names the firing gate · **SPARK-OK**

- **Files:** `tools/openburnbar-mcp/gate.py` (return verdict + reason where it already
  computes them), `tools/openburnbar-mcp/server.py` (carry them into the inbox payload),
  `AgentLens/Views/Memory/MemoryReviewInboxModel.swift` and its view (currently no
  gate/verdict/reason plumbing at all).
- **Change:** each inbox item states which gate fired and why (which secret shape, which
  injection sentinel, which aux field). Pure plumbing — do not change any gate decision.
- **Tests to add:** Python `test_inbox_items_carry_the_firing_gate_and_reason`; Swift
  `test_review_inbox_row_shows_the_gate_name_and_reason`
  (`OpenBurnBarTests/MemoryReviewInboxModelTests`).
- **Commands:** Python block; app block with
  `OPENBURNBAR_APP_TEST_FILTERS="OpenBurnBarTests/MemoryReviewInboxModelTests"`.
- **Acceptance:** two green tests; a fixture with three different firing gates renders three
  distinct reasons.
- **Do not touch:** gate thresholds, quarantine decisions, the approve/reject actions.
- **PR title:** `feat(memory-inbox): name the firing gate and its reason on every review item`

---

## P15 — B11: per-project memory health card · **SPARK-OK**

- **Files:** the settings card view under `AgentLens/Views/`, and the aggregation that reads
  existing doctor JSON + `burnbar_memory_analytics` counters.
- **Change:** counts by severity per project, plus last pull / marker age once P24 lands
  (render "—" until then). **Add no new app table** and no new counter — aggregate what
  exists.
- **Tests to add:** `test_health_card_matches_doctor_json_exactly_for_a_fixture_project`,
  `test_health_card_renders_a_placeholder_when_sync_observability_is_absent`.
- **Commands:** app block with the card's test class.
- **Acceptance:** two green tests; the first compares field-for-field against the doctor
  JSON fixture.
- **Do not touch:** doctor's output shape, analytics counters, any migration surface.
- **PR title:** `feat(memory): per-project memory health card from existing doctor and analytics output`

---

# Slice 4 — Capture

## P16 — C12: session-start briefing pack (budgeted builder) · **SPARK-OK**

- **Files:** `tools/openburnbar-mcp/server.py` (the SessionStart path and the opt-in
  setting), a new builder module beside it.
- **Change:** opt-in setting; token-budgeted `recall_pack` for the current repo/branch,
  wrapped as untrusted like every recall; consent shape reused from the resume-briefing gate
  (`server.py:4875-4879`). Budget estimator: reuse an in-repo tokenizer **if one verifies**,
  else chars/4, calibrated in-test and documented in a comment. **No new dependency.**
- **Tests to add:** `test_budget_zero_yields_headings_only`,
  `test_consent_off_yields_nothing`,
  `test_over_budget_degrades_to_headings_rather_than_truncating_mid_fact`,
  `test_the_pack_is_wrapped_as_untrusted`.
- **Commands:** the Python block.
- **Acceptance:** four green tests; `pip freeze` diff is empty.
- **Do not touch:** the recall ranking, the consent gate's own logic, the daemon.
- **PR title:** `feat(memory): opt-in, budgeted session-start briefing pack`

---

## P17 — C13: collector parity for the advertised clients · **ROUTE: Grok build**

- **Files:** `tools/openburnbar-mcp/memorize_transcript.py` (the pattern to extend), a
  per-client adapter each; Hermes reuses `hermes_proxy.py`.
- **Contract, identical per client:** quarantine by default, provenance stamped. Formats
  differ, so assert **field mapping**, not identical rows.
- **Tests to add:** one golden fixture per client, each with
  `test_<client>_transcript_maps_fields_and_lands_quarantined_with_provenance`.
- **Commands:** the Python block.
- **Acceptance:** one green test per advertised client; every fixture row lands
  `review_status == "quarantined"` with a non-empty provenance stamp.
- **Do not touch:** the gate, the approve path, the embedding path.
- **PR title:** `feat(memory-capture): transcript collectors for the remaining advertised clients`

---

## P18 — C14: guarded importer for ChatGPT / Claude.ai exports · **ROUTE: Grok build**

- **Files:** the importer behind the existing `memory_import` tool in
  `tools/openburnbar-mcp/server.py`, plus a parser module.
- **Rules:** strict export-schema version gate — unknown versions **rejected, not guessed**;
  parser → quarantine only; secret sweep on entry; dedupe by `(project, scope, body_hash)`
  using `canonical_body_hash()` from P2; bounded batches with a cap + summary; a human
  approves before anything becomes approved.
- **Tests to add:** `test_an_unknown_export_schema_version_is_rejected`,
  `test_every_imported_row_lands_quarantined`,
  `test_secrets_in_an_export_are_flagged_not_stored`,
  `test_duplicate_bodies_collapse_on_the_convergence_key`,
  `test_an_oversized_export_respects_the_batch_cap_and_reports_a_summary`.
- **Commands:** the Python block.
- **Acceptance:** five green tests against one fixture carrying secrets, dupes and an
  oversized batch.
- **Do not touch:** the approve path, the cloud upload path.
- **PR title:** `feat(memory-import): guarded assistant-export importer, quarantine-only with a strict schema gate`

---

## P19 — C15: on-demand Pro-model extraction with visible provenance · **ROUTE: Grok build**

- **Files:** the extraction entry in `tools/openburnbar-mcp/server.py`, routed through the
  #2501 model policy (member's own quota/keys, BurnBar blind); the timeline and inbox
  surfaces from P12/P14 render the label.
- **Change:** stamp `extracted_by` + model id on every row; label it visibly. Refuse
  fail-closed without entitlement or consent.
- **Tests to add:** `test_extraction_without_entitlement_is_refused_fail_closed`,
  `test_extraction_without_consent_is_refused_fail_closed`,
  `test_every_extracted_row_carries_extracted_by_and_the_model_id`,
  Swift `test_the_timeline_and_inbox_label_extracted_rows`.
- **Commands:** Python block; app block with the touched classes.
- **Acceptance:** four green tests; no extracted row lacks the stamp.
- **Do not touch:** the #2501 model policy itself, the quota accounting.
- **PR title:** `feat(memory): on-demand Pro-model extraction with fail-closed gates and visible provenance`

---

# Slice 5 — Team and organisation

## P20 — D16 spec: team memory design document (no code) · **ROUTE: Codex**

- **File:** `docs/superpowers/specs/2026-09-XX-team-memory-design.md` (new). No code.
- **Must contain, each as its own section:**
  1. **Roster authority** — who writes the roster and under what rules. Every escrow
     construct today is intra-account (`users/{uid}/escrow_public_keys`, `escrow_devices`,
     `escrow_envelopes`, `escrow_grants`, all `ownsUserNamespace(userId)`-gated:
     `firestore.rules:15, 1402, 2644-2646, 3467-3470`; publisher
     `SessionLogSyncService+VaultKeyPublishing.swift:25-60`). **No client can assert team
     membership.** Name the server-side writer; it does not exist yet.
  2. `team_memory_facts/{teamId}/facts/{docID}` collection + rules, including red-team cases.
  3. Team-bound AAD and doc-id derivation (bind `teamId`).
  4. Per-member consent matrix.
  5. Leave-team rotation semantics.
  6. **The two semantics that must also appear in the UI:** (a) joining a team grants read of
     all team facts sealed under the current key, **including those contributed before
     joining**; (b) leaving triggers rotation, which protects **future writes only** — the
     departing member keeps the old key and everything already downloaded. Consent is a
     display and contribution control, **not** a confidentiality boundary.
- **Acceptance:** the spec names the roster writer, and a reviewer can answer "who can read
  what, when" from it alone.
- **Do not touch:** any code.
- **PR title:** `docs(spec): team memory design — roster authority, envelope, and the two semantics we cannot hide`

---

## P21 — D16 PR 1: roster authority + rules · **ROUTE: Codex**

- **Depends on:** P20.
- **Files:** `firestore.rules` (new `team_memory_facts` and roster blocks), rules tests, and
  the server-side roster writer the spec names.
- **Tests to add:** `test_a_non_member_is_denied_read_and_write`,
  `test_an_ex_member_is_denied_after_rotation`,
  `test_a_client_cannot_write_the_roster`,
  `test_a_member_of_team_a_cannot_read_team_b`.
- **Commands:** the Firestore rules job; the shared block minus the app/daemon lanes.
- **Acceptance:** four green red-team rules tests; no client-writable roster path exists.
- **Do not touch:** `users/{uid}/memory_facts` rules, the member-sync path.
- **PR title:** `feat(team-memory): roster authority and team_memory_facts rules`

---

## P22 — D16 PR 2: team envelope + client · **ROUTE: Codex**

- **Depends on:** P21.
- **Files:** the team sealer/opener beside `KnowledgeSyncService.swift`, the team vault key
  distribution, the client-side consent enforcement, the UI copy from P20 §6.
- **Behaviour:** same envelope, new key, team-bound AAD and doc id; client-side enforcement
  only; behind its own entitlement + toggle so a design miss cannot strand member data.
- **Tests to add:** `test_a_team_fact_seals_and_opens_under_the_team_key`,
  `test_the_aad_binds_the_team_id`,
  `test_team_sync_failing_closed_does_not_affect_member_sync`,
  `test_the_ui_states_both_join_and_leave_semantics` (copy assertion, in the style of the
  website copy gates).
- **Commands:** the full shared block; new Swift contracts go to
  `OpenBurnBarProjectCodeContracts` (Kernel is at its ceiling).
- **Acceptance:** four green tests; the blindness proof paragraph is updated in the same PR.
- **Do not touch:** the member envelope, `users/{uid}/memory_facts`.
- **PR title:** `feat(team-memory): blind team envelope, key distribution, and honest UI semantics`

---

## P23 — D17: org ceiling as a closed-until-resolved lever · **ROUTE: Grok build**

- **Files:** `AgentLens/Services/Settings/Stores/MemorySettings.swift` — follow the shipped
  shape at `:257-270` (`hasResolvedUsageRemoteConfig`, "structurally held CLOSED until an RC
  value has actually been applied"), `:274-286` (`applyUsageRemoteConfig`, fed Firebase's
  active cached snapshot before any network call), gates `:531-583`.
- **Change:** an `orgCeilingResolved` lever ANDed into the **org lane**, seeded from the
  active cached RC snapshot at init. **No max-age** — the precedent has none, and an age
  rule cannot answer "which kinds are gated" on a device that never resolved. Member-local
  memory is a **separate lane**, never ANDed with the org ceiling.
- **Tests to add** (in the style of `MemoryCloudModelsSettingsTests`):
  `test_an_unresolved_org_ceiling_closes_the_org_lane`,
  `test_an_offline_cached_ceiling_counts_as_resolved`,
  `test_member_local_memory_works_with_no_ceiling_at_all`,
  a ceiling-deny matrix `test_org_gated_kinds_are_denied_per_ceiling`.
- **Commands:** app block with
  `OPENBURNBAR_APP_TEST_FILTERS="OpenBurnBarTests/MemoryCloudModelsSettingsTests,OpenBurnBarTests/MemorySettingsTests"`.
- **Acceptance:** four green tests; the never-resolved test asserts the org lane is
  **closed**, not permissive.
- **Do not touch:** the usage gates at `:531-583`, the fleet ceiling itself.
- **PR title:** `feat(memory-org): org ceiling closed-until-resolved, with member memory on its own lane`

---

# Slice 6 — Ops, docs gates, Linux enforcement

## P24 — E19: sync observability across both watermarks · **ROUTE: Grok build**

- **Files:** `tools/openburnbar-mcp/memory_engine/_sync.py` (persist counters to
  `engine_meta`), the daemon's existing metrics surface, one app debug row.
  **Add no new app table** — see standing rule 9.
- **Surface:** last-pull timestamp; **both** watermark ages (engine `sync_state`
  `store.py:193-199`; app `remote_sync_watermarks` `memory_facts` kind
  `RemoteSyncWatermarkStore.swift:16,49`); applied / rejected / parked / skipped counters.
- **Alert threshold:** derived from `BackgroundCadenceCoordinator`'s **maximum** effective
  interval — **not** the `2 * 600` constant at
  `BurnBarProjectCodeMemoryStore+SyncInbox.swift:63`, which Codex flagged. The marker's own
  max-age and this threshold derive from the same source so they cannot drift apart.
- **Expected floor to document in the surface:** pre-PR-1 chat memories in
  `users/{uid}/memory_facts` carry no engine `projectID` and are skipped on every pull
  (`MemoryCloudPullService.swift:96-104`, `:255-266`), so a permanent non-zero `skipped` is
  expected, not a fault.
- **Tests to add:** `test_forced_rejections_and_parks_produce_the_right_counts`,
  `test_a_stale_engine_watermark_trips_the_alert`,
  `test_a_stale_transport_watermark_trips_the_alert`,
  `test_the_threshold_is_derived_from_the_maximum_cadence_not_the_foreground_interval`,
  `test_the_permanent_skipped_floor_is_labelled_as_expected`.
- **Commands:** Python block; daemon `swift test --filter "Memory"`; app block with the
  debug-row class.
- **Acceptance:** five green tests; `git diff` shows **no** new SQLite table and **no**
  reuse of the `2 * 600` constant.
- **Do not touch:** the marker's own max-age constant (P1/`…ffqQK` owns it), any migration
  surface.
- **PR title:** `feat(memory-ops): sync observability across both watermarks, on a cadence-derived threshold`

---

## P25 — E20a: `/providers` copy gate · **SPARK-OK**

- **Files:** `website/scripts/test-providers-copy.mjs` (new),
  `website/package.json` (add `"test:providers-copy": "node scripts/test-providers-copy.mjs"`
  near `:18`, **and chain it into the `verify` script at `:61`** — that is what makes it a CI
  gate, via `website-ci.yml:59`).
- **Pattern to copy:** `website/scripts/test-pricing-copy.mjs`, and the siblings
  `test-router-copy.mjs`, `test-trust-copy.mjs`, `test-approved-hero-copy.mjs`,
  `test-demo-telemetry-copy.mjs`. Match their structure exactly.
- **What to assert:** every factual claim on `website/src/pages/providers.astro` that names a
  repo fact is pinned to its source (counts, provider names, capability claims), so the page
  cannot drift from the code.
- **Commands:**
  ```bash
  cd "/Volumes/Samsung NVME/offloaded-home/Documents/Projects/BurnBar/website"
  node scripts/test-providers-copy.mjs
  npm run verify
  ```
- **Acceptance:** the script fails when a pinned number in `providers.astro` is edited, and
  `npm run verify` runs it.
- **Do not touch:** `test-pricing-copy.mjs`, the page's design, any other `verify` entry.
- **PR title:** `test(website): pin /providers copy to repo facts and wire it into verify`

---

## P26 — E20b: `/security` copy gate · **SPARK-OK**

Identical shape to P25, for `website/src/pages/security.astro` and
`website/scripts/test-security-copy.mjs`, chained into `verify` at `website/package.json:61`.

- **What to assert:** every security claim on the page that names a repo fact (crypto
  posture, what the server can and cannot see, the blindness claims) is pinned to its source.
- **Commands:** as P25, with `node scripts/test-security-copy.mjs`.
- **Acceptance:** the script fails when a pinned claim is edited; `npm run verify` runs it.
- **Do not touch:** `test-security-headers.mjs` (a different, existing gate), `/providers`.
- **PR title:** `test(website): pin /security copy to repo facts and wire it into verify`

---

## P27 — E18b: port egress enforcement into the Linux gateway · **ROUTE: Codex**

Largest packet in the program; it may exceed 400 lines. If it does, split it as
(a) purpose header + token validation, (b) evaluate/deny/record + denial response — and say
so in the PR body.

- **Depends on:** P11.
- **Files:**
  `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/Linux/OpenBurnBarHTTPGatewayServerLinux.swift`
  (1816 lines, `#if os(Linux)` at `:1`; init at `:142-155`), plus the Linux gateway test
  target.
- **Mirror these Darwin call sites without importing `Network`** (which
  `OpenBurnBarHTTPGatewayServer+RoutePipeline.swift:1-4` does and Linux cannot):
  - purpose-header parsing and token validation → `+Connection.swift:163-164`
  - evaluate / deny → `+RoutePipeline.swift:111-126`
  - record on failure and success → `+RoutePipeline.swift:209-222`
  - denial response shaping → `+RoutePipeline.swift:750-762`
- **Reuse `BurnBarMemoryEgressEnforcer.swift` unchanged** — it is already portable
  (`:1-2`, `import Foundation` + `import OpenBurnBarEngine`, no `#if os`, 129 lines).
- **Remove P11's start-refusal** once enforcement is real, in this same PR.
- **Tests to add** (Linux gateway test filter): `test_a_request_without_a_purpose_header_is_denied`,
  `test_an_invalid_token_is_denied`,
  `test_a_denied_egress_records_and_shapes_the_denial_response_like_darwin`,
  `test_an_allowed_egress_is_recorded_on_success`,
  `test_the_gateway_now_starts_with_memory_egress_configured`.
- **Commands:** the Docker Linux toolchain from `docs/linux-port/`; build and
  `swift test --filter "Gateway"` on Linux; then the Darwin daemon filter to prove no
  regression.
- **Acceptance:** five green Linux tests; a red-team egress probe that succeeds on the
  P11 build is denied on this one.
- **Do not touch:** the Darwin route pipeline, `BurnBarMemoryEgressEnforcer.swift`.
- **PR title:** `feat(daemon-linux): port memory egress enforcement into the Linux gateway route pipeline`

---

## Route index

| Route | Packets |
|---|---|
| **SPARK-OK** (8) | P2, P9, P11, P14, P15, P16, P25, P26 |
| **ROUTE: Codex** (9) | P1b, P4, P5, P6, P8, P20, P21, P22, P27 |
| **ROUTE: Grok build** (11) | P1, P3, P7, P10, P12, P13, P17, P18, P19, P23, P24 |

Ordering is the revised plan's slice order: P1 → P1b (contingency) → P2 → P3 → P4 → P5 →
P6 → P7 → P8 (Slice 1) → P9 → P10 → P11 (Slice 2) → P12 → P13 → P14 → P15 (Slice 3) →
P16 → P17 → P18 → P19 (Slice 4) → P20 → P21 → P22 → P23 (Slice 5) → P24 → P25 → P26 →
P27 (Slice 6). Slice 6's P24–P26 may run in parallel with Slice 3; P27 may not start
before P11.
