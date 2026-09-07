# MEMORY_EXPORT_MIF — release BB-E, the BurnBar side of the memory migration

BurnBar's memory store is the current authority. The migration moves it to the
memory core, once, through a signed and sealed bundle. This document is what BB-E
actually ships, how each part maps to `MEMORY_MIGRATION_SPEC.md` v1.1, and every
place the implementation departs from that spec's prose — with the reason.

The contract is the neutral one both sides implement independently:
`contracts/mif-v1.schema.json`. Nothing here is copied from the memory-core repo,
and nothing there is copied from here.

**The single user-visible consequence, stated plainly:** *memories an agent
approved for itself arrive needing your review.*

---

## 1. What ships

`OpenBurnBarCore/Sources/OpenBurnBarMemoryExport/` — a SwiftPM library target,
AGPL-3.0-only like the rest of BurnBar, linked by **both** the Xcode app target
(whose "Export memory" action calls it in-process) and `openburnbar-cli`.

| File | Spec | What it owns |
|---|---|---|
| `MIFCanonicalJSON.swift` | §2 determinism | RFC 8785 (JCS). One serializer owns every byte the bundle emits. |
| `MIFVocabulary.swift` | §2 record types | A typed mirror of every closed set in the contract; section order **is** merge order. |
| `MemoryExportSourceRows.swift` | §3 | Plain values for every oracle table read, plus the timestamp parser. |
| `MemoryExportAuditChain.swift` | §7 | The `openburnbar.memory_audit.v2` recompute, `chain_verified_through_seq`, `chain_broken_at[]`, `chain_forks[]`, `seq_divergence`. |
| `MemoryExportClassifier.swift` | §3.1 | The sixteen-row table and the six conjuncts, as a pure function. |
| `MemoryExportBodyResolver.swift` | §3.2 | Dual `body_ref` resolution, recovery, and loss. |
| `MemoryExportCrypto.swift` | §2 | Bundle key, `body_join_key` / `body_norm_digest`, segment seal, keyed hash tree, recipient wrap, Ed25519 signature. |
| `MemoryExportIdentity.swift` | §2, §4 | Every deterministic id. |
| `MemoryExportRecords.swift` | §2 | One builder per MIF record type. |
| `MemoryExportGate.swift` | D-0008 | The three gate classes, over BurnBar's own `MemorySecretPIIGate`. |
| `MemoryExportReport.swift` | §10 | The reconciliation report, version 1.1. |
| `MemoryExportBundleWriter.swift` | §2 | Sections, manifest, hash tree, `lost.csv`, `id-map.csv`. |
| `MemoryExporter.swift` | §3 | The pipeline. `export(mode: .dryRun \| .full \| .delta(sinceAuditSeq:))`. |
| `MemoryExportP5Check.swift` | §5, D-0007 | The `audit_head`-unchanged proof, as its own command. |
| `MemoryExportCommand.swift` | §3 | Flags, and `burnbar.memory.export.enabled`. |
| `MemoryExportStoreReader.swift` | §3 | The only file that knows GRDB exists. |

`OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarCLI+MemoryExport.swift`
adds one `case "memory"` with the verbs `export | export-status | verify |
p5-check`, macOS-only and behind `OPENBURNBAR_MEMORY_EXPORT`.

### The API

```swift
let exporter = MemoryExporter(
    storeID: …, storeFingerprint: …, sourceVersion: …, userID: …,
    recipientPublicKey: …,   // the importer's static X25519 key (P0 prerequisite)
    signingKey: …,           // com.openburnbar.memory-export / export-signing-key-v1
    options: MemoryExportOptions(enabled: …, gate: .shared, …)
)
let result = try exporter.export(snapshot, mode: .full, to: bundleURL)
```

Producing `<out>/manifest.json`, `manifest.sig`, `keys/wrapped-bundle-key`,
`hashtree.json`, `sections/<NN-name>/`, `lost.csv`, `id-map.csv` and
`report.json`.

---

## 2. The release-BB-E flag

`burnbar.memory.export.enabled` — **default OFF, user-initiated** (§5, P1).
Namespaced by product; v1.0's shared `memory.*` prefix across two products is
gone. `MemoryExporter.export` throws `MemoryExporterError.featureDisabled` when
it is off, so the flag is enforced in the engine rather than only in the UI that
calls it.

---

## 3. Section map

| Section | Source | Notes |
|---|---|---|
| `00 tombstones` | `memory_fact_tombstones`, `memory_source_tombstones`, synthesized | Every `memory.delete` in the window synthesizes a `fact` tombstone; a stored `forgotten` row leaves as one and never appears in 05. |
| `01 tombstone_receipts` | `memory_fact_tombstones.replicated_at` | `peer_label: "cloud"` — the only peer BurnBar replicates a forget to. |
| `02 review_events` | proven human verdicts only | See §5 below. |
| `03 supersessions` | — | **Always empty.** See deviation D-BB-E-2. |
| `04 projects` | `pcm_projects` | Fingerprint inputs only; the importer computes `project_id`. |
| `05 memories` | `agent_memories` | |
| `06 bodies` | `memory_body_snapshots`, `project_memory_snapshots`, `memory_quarantine_bodies`, `body_redacted` | |
| `07 provenance` | `memory_provenance` | Always `citation_state: "unknown"` — the sources are not migrated by this bundle. |
| `08 embeddings` | `memory_embedding_refs` | Counts only; the record type has no vector field. |
| `09 audit_evidence` | `memory_audit` | Verbatim payload, `chain_epoch: 1`, `body_ref:` labels stripped and counted. |
| `10 findings` | — | Migration only, never applied as data. |

Never transported, per §2: token rows, token stats, cursors, clients, `path`
aliases, `derived_dedup` edges, and `restricted`-classification rows.

---

## 4. Deviations

Each one is a place the implementation and the spec's prose differ. None is
silent.

### D-BB-E-1 — `memory_id` canonicalisation, and `id-map.csv`

**Spec:** §2 says the oracle `memory_id` travels verbatim; §4 calls it "the
oracle's `mem_…` `memory_id`".

**Reality:** that is true of the daemon lane, which mints
`"mem_" + sha256(projectID:scope:bodyRef)[:32]`. It is **not** true of the app
lane: `ControlPlaneStore.addMemoryAuthorityRecord` defaults its id to
`UUID().uuidString`, so every chat and usage row carries an uppercase hyphenated
UUID that the contract's `^mem_[0-9a-f]{32}$` rejects. Carrying those verbatim
would fail validation on the larger of the two lanes.

**What BB-E does:** already-conforming ids pass through untouched, so every
daemon-lane audit, provenance and tombstone reference migrates intact.
Non-conforming ids become `"mem_" + sha256(store_id ‖ 0x1F ‖ raw)[:32]` —
deterministic and store-scoped — and **every rewritten pair is written to
`id-map.csv` beside the bundle**, because `record_memory` is
`additionalProperties: false` and has nowhere to carry the original.

**Owed:** the spec and the contract should say which lane they mean, and MIF v1.2
should carry `source_memory_id` on `record_memory` so the map need not be a
sidecar.

### D-BB-E-2 — section 03 is always empty

§2 transports **authored** supersession edges only; `derived_dedup` edges are
recomputed locally. BurnBar's only source of `agent_memories.superseded_by` is
`mergeDuplicateMemories`, which is exactly a derived dedup edge. So section 03
has no rows to carry, and every edge is counted
`not_exported.derived_edge_recomputed_locally` — or, when its target is missing,
`not_exported.dangling_supersession` with the memory kept (orphan case (c)).

### D-BB-E-3 — `record_tombstone` has no `scope_kind`

The contract's `record_tombstone` carries `scope_key` and, unlike
`record_memory`, no `scope_kind`. Emitting the pair fails
`additionalProperties: false`, so a tombstone's scope is expressed by the key
alone. This is a contract asymmetry, not a decision of ours; flagged for the
schema owner.

### D-BB-E-4 — quarantined daemon bodies live in `memory_quarantine_bodies`

§3.2's convention-B row names `project_memory_snapshots` as the daemon body
store. That holds only for **approved** rows: `setReviewStatus` moves a
quarantined or rejected body into `memory_quarantine_bodies` and rewrites
`body_redacted` to a `Quarantine body ref:` locator. Treating that as loss would
silently drop the daemon lane's entire review queue.

BB-E resolves those bodies and stamps `recovered_from:
"project_memory_snapshots"`, because MIF v1.1's `recovered_from` set has no
member for that store. **Owed:** a fourth `recovered_from` value.

### D-BB-E-5 — cipher and compression primitives

- §2 names **XChaCha20-Poly1305**. CryptoKit ships no XChaCha20, so segments are
  sealed with **ChaCha20-Poly1305** (RFC 8439). The nonce is *derived* from the
  segment key and the chunk index rather than drawn at random: the bundle key is
  fresh per export and each `(segment, chunk)` is sealed exactly once, so the
  uniqueness guarantee is the same, and `--deterministic-nonces` becomes a seed
  change rather than a separate code path.
- §2 names **zstd**. BurnBar vendors no zstd, and adding a compressor to reach a
  bundle nobody has yet read back is the wrong order of work. v1 writes
  **uncompressed** NDJSON inside the seal. The manifest has no compression field
  (`additionalProperties: false`), so this is a container-level fact for the
  importer to discover, and a later codec is additive.
- §2 names **HPKE base** for the recipient wrap. `HPKE` carries availability
  annotations this target does not want to inherit, so the wrap is
  DHKEM(X25519, HKDF-SHA256) + ChaCha20-Poly1305 written out directly — the same
  shape, one file to swap.

### D-BB-E-6 — the snapshot ladder is not pinned

D-0009's ladder (`vacuum` → `sqlcipher_export` → `backup_api`) requires an
**executed R9-class test on the shipped artefact** before a rung may be claimed.
That test is not in this release. The CLI therefore accepts only
`--snapshot read_txn --allow-long-read` and refuses every other rung with
`EXPORT_SNAPSHOT_UNAVAILABLE` — the spec's own instruction, rather than falling
through to an unpinned copy. `snapshot_mode` in a shipped manifest stays a fact.

### D-BB-E-7 — `--resume` is refused, not ignored

§3's flag set includes `--resume`. BB-E's writer builds a bundle in one pass
rather than streaming it, so there is no partial bundle to resume onto, and the
flag is **refused with a message** rather than accepted and silently ignored —
which would leave an operator believing a half-written bundle had been
completed. Streaming and per-section resume are what an 8.4 GB source needs and
are owed before the real store is exported; the section rotation
(`--max-section-bytes`) is already in place for it.

### D-BB-E-8 — sources BB-E does not read

`--source legacy|cloud|all` records the unread source in `partial_sources` with a
reason and exports the authority store. Never a silent skip. The cloud vault
reader (§8) and the legacy plaintext readers (§1 S2/S2b) are later releases; the
classifier already carries the `cloud` branch (§3.1 row 15) so wiring the reader
does not touch classification.

### D-BB-E-9 — section 02 carries proven verdicts only

`record_review_event` is emitted only for §3.1 rows 1–3. An **unproven** verdict
is represented by the memory's `import_origin_detail` plus its finding, and no
event is minted for it: an `automatic` event would enter §4's merge as a verdict
nobody made.

### D-BB-E-10 — a gate hit the scanner cannot locate

D-0008's hold class covers "any body where redaction cannot be located exactly".
When `MemorySecretPIIGate` returns `.reject` for a located-span failure, no part
of that body is safe to carry, so the row travels with a
`[REDACTED:unlocatable]` placeholder, its metadata, its labels, and
`redaction_state: held_for_review`. The row is **held, never dropped** — but its
text does not survive, and the report says so. A corpus that will not load is a
different case: it refuses the whole export with `GATE_UNAVAILABLE`, because
fail-closed must not mean "placeholder every body in the store".

### D-BB-E-11 — `content_digest` is per-bundle-key

`body_join_key` and `body_norm_digest` are HMACs under the per-export bundle key
and live in the plaintext `content_digest` covers, so two exports of one
unchanged store agree only when the key does. That is the design (a raw body hash
is a dictionary-invertible oracle), and it is why `--rehearsal
--deterministic-nonces` derives the key from a fixture seed. The report's
`counts_hash`, which carries no keyed value, is stable across keys — and that is
what the determinism test asserts alongside the per-key digest.

---

## 5. The classifier, in one paragraph

There exists a `memory_audit` row with `action ∈ {memory.approve,
memory.reject}` **and** `actor = 'app'` **and** `subject_id = m.id`; `m`'s
`source_kind` is app-owned; `m` uses the `memory_body_snapshots:` convention;
`m.user_id` and `m.app_id` are both non-NULL; the audit row is chain-trustworthy;
and the body snapshot is not newer than the verdict. All six, or it is not proof.
The verdict's **value** comes from the row's `review_status:<raw>` label, never
from the action verb — BurnBar writes `memory.reject` for `approved →
quarantined` too, and reading the verb would turn "send back to review" into a
permanent, unrecallable rejection. Among candidate rows, latest wins on
`(ts, seq)` with `rejected` taking any tie.

---

## 6. Tests

`OpenBurnBarCore/Tests/OpenBurnBarMemoryExportTests/`, 53 tests, run on the
Swift door by `scripts/test-openburnbar-swift.sh`:

```
swift test --package-path OpenBurnBarCore --filter MemoryExport
```

Fixtures are built by **BurnBar's own migrator** (`OpenBurnBarDatabase.migrator`,
the `OpenBurnBarData` mirror), so the schema under test is the one production
has. Every store is `:memory:`; **nothing under `~/Library` is ever opened**.

Covered: `--carry-orphans` (always counted; carried only when asked, and a
carried orphan becomes a synthetic `quarantined` row with a body-only provenance
marker that satisfies the same contract) · the §3.1 table including a proven
human approve, approve-then-mutated,
a daemon `code` row approved by default, a label-only approval, a forged
`actor: "app"`, a verdict on a broken chain, and both absent-column and
absent-table base cases · the chain walk's break, fork and payload-seq-divergence
behaviour · both body conventions against a real store, the adversarial
`memory_body_snapshots:<64 hex>` value, legacy-plaintext recovery, the quarantine
store, and unreconstructible loss · determinism, dry-run parity, the delete
obligation, the gate (against the real corpus, asserting the credential never
reaches the sealed body) · and the P5 gates.

**Schema validation runs in-process.** `MIFSchemaValidator.swift` is a JSON
Schema subset validator over an embedded copy of `contracts/mif-v1.schema.json`,
and the test asserts `assertionsEvaluated > 500`. It is deliberately not a
`python3 -c 'import jsonschema'` shell-out: §10 requires the validator be proven
to have run, and an optional import that fails open on every machine that never
installed it is the exact failure mode it names. An unknown JSON Schema keyword
is a hard failure there, so a contract that grows one turns the suite red rather
than quietly checking less.

The embedded contract is a byte copy of the gauntlet's
`docs/memory/contracts/mif-v1.schema.json`. Re-copy it when the contract moves;
the validator will name whatever no longer agrees.

---

## 7. What BB-E does not do

- It never writes to the source store, never mints a key, and never re-keys.
- It never stops `com.openburnbar.daemon` and never changes the store file's
  mode. D-0007 forbids both: that LaunchAgent and that one `openburnbar.sqlite`
  serve roughly twenty unrelated RPC families, and BurnBar must keep working
  without Po'dex and without memory. The P5 proof is `audit_head` unchanged
  across the final delta — an observation of the shared file, which stays valid
  with the agent up.
- It builds no importer. The bundle is BurnBar → core, one way.
