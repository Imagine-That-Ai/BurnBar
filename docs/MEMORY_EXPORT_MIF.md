# MEMORY_EXPORT_MIF — release BB-E, the BurnBar side of the memory migration

BurnBar's memory store is the current authority. The migration moves it to the
memory core, once, through a signed and sealed bundle. This document is what BB-E
actually ships, how each part maps to `MEMORY_MIGRATION_SPEC.md` (§2.1 as
amended by **D-0021** and **D-0025**), and every place the implementation
departs from that spec's prose — with the reason.

**Release state.** `REVIEW-BB-EXPORTER.md` returned this branch with nineteen
ranked findings. Every one is answered; §7 is the per-finding status, and the
two that corrupted truth (F-2, F-5) each carry a regression test that fails when
the fix is removed.

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
| `MemoryExportCrypto.swift` | §2.1 | Bundle key, `body_join_key` / `body_norm_digest`, the `mif1-hkdf-v1` key schedule, the segment seal and its AAD, the keyed hash tree, the RFC 9180 HPKE wrap, the Ed25519 signature. |
| `MemoryExportRecipient.swift` | D-0025 | The recipient descriptor, its recomputed id, and unpadded base64url. |
| `MemoryExportIdentity.swift` | §2, §4 | Every deterministic id. |
| `MemoryExportRecords.swift` | §2 | One builder per MIF record type. |
| `MemoryExportGate.swift` | D-0008 | The three gate classes, over BurnBar's own `MemorySecretPIIGate`. |
| `MemoryExportReport.swift` | §10 | The reconciliation report, version 1.1. |
| `MemoryExportBundleWriter.swift` | §2 | Sections and their segment rotation, manifest (including `crypto`), hash tree, `lost.csv`, `id-map.csv`. |
| `MemoryExportBundleVerifier.swift` | §3 `verify` | What a bundle on disk can be checked for without the bundle key. |
| `MemoryExporter.swift` | §3 | The pipeline. `export(mode: .dryRun \| .full \| .delta(sinceAuditSeq:sinceUpdatedAtMS:))`. |
| `MemoryExportP5Check.swift` | §5, D-0007 | The `audit_head`-unchanged proof, as its own command. |
| `MemoryExportCommand.swift` | §3 | Flags, and `burnbar.memory.export.enabled`. |
| `MemoryExportStoreReader.swift` | §3 | The only file that knows GRDB exists. |

`OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarCLI+MemoryExport.swift`
adds one `case "memory"` with the verbs `export | export-status | verify |
p5-check`, macOS-only and behind `OPENBURNBAR_MEMORY_EXPORT`.

### The API

```swift
let exporter = MemoryExporter(
    storeID: …,              // read from INSIDE the store, never from its inode
    storeFingerprint: …, sourceVersion: …, userID: …,
    recipient: …,            // MemoryExportRecipient — REQUIRED, D-0025 ruling 3
    signingKey: …,           // com.openburnbar.memory-export / export-signing-key-v1
    options: MemoryExportOptions(enabled: …, gate: .shared, …)
)
let result = try exporter.export(snapshot, mode: .full, to: bundleURL)
```

`recipient` is not optional. A bundle sealed to nobody is a bundle whose content
key exists nowhere, and the type refuses to represent one.

Producing `<out>/manifest.json`, `manifest.sig`, `keys/wrapped-bundle-key`,
`hashtree.json`, `sections/<NN-name>/NNN.ndjson.seal`, `lost.csv`, `id-map.csv`
and `report.json`.

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
| `05 memories` | `agent_memories` | Plus one synthetic row per carried orphan. `source_memory_id` carries the oracle id wherever `memory_id` had to be canonicalised. |
| `06 bodies` | `memory_body_snapshots`, `project_memory_snapshots`, `memory_quarantine_bodies`, `body_redacted` | `recovered_from` names the table the body came from, quarantine included (minor 2). |
| `07 provenance` | `memory_provenance` | Always `citation_state: "unknown"` — the sources are not migrated by this bundle. |
| `08 embeddings` | `memory_embedding_refs` | Counts only; the record type has no vector field. |
| `09 audit_evidence` | `memory_audit` | Verbatim payload, `chain_epoch: 1`, `body_ref:` labels stripped and counted. In a delta: the window **union** every `audit_seq` a carried human-origin row cites (M-20). |
| `10 findings` | — | Migration only, never applied as data. |

Never transported, per §2: token rows, token stats, cursors, clients, `path`
aliases, `derived_dedup` edges, and `restricted`-classification rows. Each of
those has its own row in the reconciliation report where it has source rows to
account for, rather than being folded into another table's `source_rows` to make
a sum come out.

Each section is written as one `NNN.ndjson.seal` per sealed segment, rotating at
`--max-section-bytes` of ciphertext (default 256 MiB). The file index is the
segment index the nonce and the chunk AAD are derived from.

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
deterministic and store-scoped.

**CLOSED by D-0021 ruling 4:** minor 2 adds `record_memory.source_memory_id`,
and BB-E emits the oracle's original id there whenever it rewrote one.
`id-map.csv` is still written, and now a convenience rather than the only record
of the mapping — it also covers what the record cannot: rewritten **tombstone
subjects**, and rows named in `lost.csv` that never became a `record_memory` at
all. Every canonicalisation the exporter performs goes through one memoising
helper that records it, so the map is complete by construction rather than by
each call site remembering.

`store_id` is read from inside the database (D-BB-E-13), so a restore or a
`VACUUM` mints the same ids and a follow-up delta updates rather than
duplicates.

### D-BB-E-2 — section 03 is always empty

§2 transports **authored** supersession edges only; `derived_dedup` edges are
recomputed locally. BurnBar's only source of `agent_memories.superseded_by` is
`mergeDuplicateMemories`, which is exactly a derived dedup edge. So section 03
has no rows to carry, and every edge is counted
`not_exported.derived_edge_recomputed_locally` — or, when its target is missing,
`not_exported.dangling_supersession` with the memory kept (orphan case (c)).

### D-BB-E-3 — `record_tombstone` has no `scope_kind` — **CLOSED by D-0021 ruling 4**

The v1.1 contract's `record_tombstone` carried `scope_key` and, unlike
`record_memory`, no `scope_kind`, so emitting the pair failed
`additionalProperties: false`. This exporter is what proved that asymmetry
unworkable; MIF minor 2 reverses the Wave 2 decision and carries `scope_kind`
optionally (required in the next major), and BB-E emits it.

It remains an **interchange** field. The importer still derives its routing from
`scope_key`'s own leading tag and never writes a tombstone column that does not
exist, so a `scope_kind` disagreeing with the tag is a finding, not a store
write.

### D-BB-E-4 — quarantined daemon bodies live in `memory_quarantine_bodies`

§3.2's convention-B row names `project_memory_snapshots` as the daemon body
store. That holds only for **approved** rows: `setReviewStatus` moves a
quarantined or rejected body into `memory_quarantine_bodies` and rewrites
`body_redacted` to a `Quarantine body ref:` locator. Treating that as loss would
silently drop the daemon lane's entire review queue.

BB-E resolved those bodies and stamped `recovered_from:
"project_memory_snapshots"` — true about the lane, false about the table —
because v1.1's `recovered_from` set had no member for that store. **CLOSED by
D-0021 ruling 4:** minor 2 adds `memory_quarantine_bodies`, and BB-E stamps the
table the body actually came from.

### D-BB-E-5 — the v1.2 crypto profile, as implemented

§2.1 [D-0021, D-0025] is byte-precise and closed: *a construction not written
there is not a MIF bundle*. What BB-E emits, item by item:

| §2.1 | BB-E |
|---|---|
| Wrap: RFC 9180 HPKE, mode_base, DHKEM(X25519,HKDF-SHA256)/HKDF-SHA256/ChaCha20Poly1305 (`0x0020`/`0x0001`/`0x0003`) | CryptoKit `HPKE.Sender(ciphersuite: .Curve25519_SHA256_ChachaPoly)`. **No fallback below it, on any platform, for any reason** — `EXPORT_HPKE_UNAVAILABLE` instead |
| `info = "mif1/keywrap/v1"`, `aad = recipient_key_id` (UTF-8), plaintext = the 32-byte bundle key | as stated |
| `keys/wrapped-bundle-key` = `b64url(enc) "." b64url(ct)`, unpadded | as stated |
| `seg_key = HKDF-SHA256(salt = "imaginethat.memory.hkdf.v1", ikm = bundle_key, info = "mif1/segment/" ‖ section_name, L = 32)` | as stated, `section_name` **bare** (D-0025 ruling 1) |
| `nonce = HKDF-SHA256(salt = same, ikm = seg_key, info = "mif1/nonce/" ‖ decimal(index), L = 32)[0 .. nonce_len]` | as stated. RFC 5869's Expand is prefix-consistent, so asking for 12 directly gives the same bytes — pinned by a test, because the two readings would otherwise fail as a silent decryption error |
| `aad = UTF-8(section_name ‖ "/" ‖ decimal(segment_index))` | as stated. `memories/0` does not open as `bodies/0`, and does not open at index 1 |
| AEAD ∈ {`xchacha20poly1305`, `chacha20poly1305`}, declared | **`chacha20poly1305`**, `nonce_len` 12. CryptoKit ships no XChaCha20; §2.1 admits the substitution and requires the declaration |
| Compression ∈ {`none`, `zstd`}, declared | **`none`**. BurnBar vendors no zstd. Declaring `none` is legal; silently ignoring a *declared* `zstd` is not |
| `manifest.crypto{aead, compression, wrap, key_schedule}`, required | emitted, with `wrap` and `key_schedule` the contract's `const` values — which the wrap above is the only construction able to satisfy honestly |

**Two departures, both forced, both here rather than in the code's head:**

1. **`manifest.recipient_key_id` cannot hold D-0025's id.** D-0025 ruling 2
   defines `recipient_key_id = "rcp_" + sha256(public_key)[0..32]` and says an
   exporter copies it into `manifest.recipient_key_id`. The contract types that
   field `hex64_null` (`^[0-9a-f]{64}$`), and the manifest is
   `additionalProperties: false`, so the `rcp_` form cannot go in it and there
   is nowhere else to put it. BB-E uses the `rcp_` id where D-0021 ruling 1
   requires it — as the HPKE `aad`, which is where the binding is
   cryptographic — and puts the full `sha256(public_key)` in the manifest field,
   of which the id is a prefix, so an importer checks
   `manifest.recipient_key_id[0..32] == recipient_key_id[4..]` in one
   comparison. **For the spec owner:** either widen the field or restate the id.
2. **`EXPORT_HPKE_UNAVAILABLE` and `EXPORT_RECIPIENT_REQUIRED` are not in the
   contract's `export_error` set,** which `reconciliation_report.export_error`
   validates against. They live in their own Swift enum so a refusal can never
   produce a report no validator accepts. Both fire before any bundle or report
   is written. **For the spec owner:** add them to the closed set.

**On the `#available` D-0021 ruling 1 asks for:** `OpenBurnBarCore`'s deployment
floor is macOS 14 / iOS 17, which is exactly CryptoKit HPKE's floor, so the
guard is statically satisfied on every platform this package builds for and
writing it would only raise an always-true warning. The refusal it guards is
still the only alternative, and it is still there.

**RFC 9180 vector provenance.** `MemoryExportCryptoTests` transcribes Appendix
A.2 ("DHKEM(X25519, HKDF-SHA256), HKDF-SHA256, ChaCha20Poly1305"), §A.2.1 *Base
Setup Information* and the first record of §A.2.1.1 *Encryptions* (sequence
number 0), from `https://www.rfc-editor.org/rfc/rfc9180.txt`. Line-wrapping in
the RFC's rendering is removed; no other byte is changed. The test opens the
vector's ciphertext with the vector's `skRm`, `enc`, `info` and `aad` through
the same `HPKE` the wrap uses, checks the vector's `pkRm` follows from its
`skRm`, and pairs it with a wrong-AAD negative — without which the vector would
still pass on an implementation that ignored `aad` entirely.

### D-BB-E-6 — the snapshot ladder is not pinned

D-0009's ladder (`vacuum` → `sqlcipher_export` → `backup_api`) requires an
**executed R9-class test on the shipped artefact** before a rung may be claimed.
That test is not in this release. The CLI therefore accepts only
`--snapshot read_txn --allow-long-read` and refuses every other rung with
`EXPORT_SNAPSHOT_UNAVAILABLE` — the spec's own instruction, rather than falling
through to an unpinned copy. `snapshot_mode` in a shipped manifest stays a fact.

### D-BB-E-7 — `--resume` is refused, and BB-E is a fixture-scale exporter

§3's flag set includes `--resume`. BB-E's writer builds a bundle in one pass
rather than streaming it, so there is no partial bundle to resume onto, and the
flag is **refused with a message** rather than accepted and silently ignored —
which would leave an operator believing a half-written bundle had been
completed.

**Correction.** The previous wording claimed the section rotation was "already
in place for it". It was not: `--max-section-bytes` was the chunk size and
nothing else, every sealed chunk was concatenated into one file, and `segments`
reported a re-chunking of the ciphertext at a boundary that corresponded to
nothing on disk. That is fixed — a section is now written as one
`NNN.ndjson.seal` per sealed segment, rotating at `max_section_bytes` of
*ciphertext*, and the file index is the same number the nonce and the chunk AAD
are derived from.

**Streaming is still owed, and it is the part that matters at scale.** The
exporter materialises the entire store before it writes anything:
`MemoryExportStoreReader.read` builds a whole `MemoryExportSourceSnapshot` in
one read transaction, and `MemoryExportBundleWriter.build` then holds, at once,
the section record arrays, every section's NDJSON plaintext, and every sealed
segment. Bodies are the bulk of the 8.4 GB store, and they exist in at least
four of those forms simultaneously — the `snapshot_json` they were read from,
the section-06 record, the NDJSON line, and the sealed bytes — so a conservative
multiplier on body bytes alone is **3–4×**, i.e. tens of gigabytes against §2's
**≤ 512 MiB RSS** ceiling. The process would be killed, or thrash, long before
it wrote a manifest, and because nothing is written until everything is in
memory a failure at 95 % leaves nothing behind — and nothing to resume onto.

That number is an estimate from the allocation structure, not a measurement: no
real store was opened to produce it, and none should be. What it makes BB-E is a
**fixture-scale exporter**, which is exactly what D-0021 ruling 6's interop gate
requires (a bundle from GRDB fixtures, never a real store) and is not enough for
P0. Streaming, per-section resume, and a bounded-buffer reader are the work
before the real store is exported. Two small steps are already taken: the hash
tree runs across a section's segments without concatenating them, and segments
are written as they are produced rather than joined first.

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

### D-BB-E-12 — `dedup_partition` maps `agent` to `chat`

§3.3 lists `chat→chat`, `usage→usage`, `code→code`, `safari_ask→chat`,
`agent_session→chat`, absent→`import`. BB-E adds `agent→chat`: the oracle has
rows with a bare `source_kind = 'agent'` from before the column settled on
`agent_session`, and leaving them in the `import` partition would stop a
migrated conversational row and a Po'dex-native one from ever forming the
supersession edge the rehearsal profile asserts. Harmless and additive, but it
is a departure and the review was right that it belonged here.


### D-BB-E-13 — `store_id` comes from a row, not from the file

Every canonical id above is seeded from `store_id`, so it has to survive
everything that leaves the user's data intact but rewrites the file. BB-E read
it from `sha256(inode ‖ creation date)`, and an inode survives none of a Time
Machine restore, a `VACUUM`, an APFS clone or a reinstall.

It now comes from the local `devices` row — written once by migration v22, and a
row, so a restore copies it verbatim, a `VACUUM` rewrites it in place and a
clone clones it — with the audit chain's genesis hash as the fallback for a
store predating that migration. A store carrying neither is refused rather than
given an invented identity.

That a byte copy of the store yields the **same** id is correct, not a weakness:
a restored store is the same store, and the migration's idempotency rests on it.

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
permanent, unrecallable rejection.

**Latest-wins is segment-aware**, which is one rule with two cases. Inside one
intact segment — every candidate chain-verified, in no `chain_broken_at[]` span
and in no `chain_forks[]` member — order by **`seq DESC`**, because `seq` is the
oracle's own append order and inside a verified run it is exactly the fact the
chain proves. Only across a broken or forked boundary, where `seq` is undefined
between the candidates, fall back to `(ts, seq)`. Either way a tie is won by
`rejected`. Applying the timestamp rule universally — which BB-E did until the
review — let a clock skew between the app and daemon writers promote an
`approve` over a later-sequenced `reject`, on an intact chain, into the new
authority as `approved` with `origin_kind: human`.

---

## 6. Tests

`OpenBurnBarCore/Tests/OpenBurnBarMemoryExportTests/`, **92 tests**, run on the
Swift door by `scripts/test-openburnbar-swift.sh`:

```
swift test --package-path OpenBurnBarCore --filter MemoryExport
→ Executed 92 tests, with 0 failures (0 unexpected)
```

The count reconciles: `grep -c "func test"` over the target's files sums to 92,
and there is no swift-testing `@Test` anywhere in it, so 92 declared is 92
executed.

Fixtures are built by **BurnBar's own migrator** (`OpenBurnBarDatabase.migrator`,
the `OpenBurnBarData` mirror), so the schema under test is the one production
has. Every store is `:memory:`; **nothing under `~/Library` is ever opened**.

Covered: `--carry-orphans` (always counted; carried only when asked; and a
forgotten memory stays forgotten, which it did not before) · the §3.1 table
including a proven human approve, approve-then-mutated, a daemon `code` row
approved by default, a label-only approval, a forged `actor: "app"`, a verdict
on a broken chain, and both absent-column and absent-table base cases · the
segment-aware selection rule in both segment states and both skew directions ·
the chain walk's break, fork and payload-seq-divergence behaviour · both body
conventions against a real store, the adversarial `memory_body_snapshots:<64
hex>` value, legacy-plaintext recovery, the quarantine store, and
unreconstructible loss · determinism, dry-run parity, the delete obligation, the
gate · the delta window counting rows across three windows · every table's
closed sum over its own source rows · segment rotation and the four corruptions
`verify` can catch on disk · and the P5 gates.

**Three tests exist to fail when a fix is removed**, and each was run against
the un-fixed code to prove it: the forgotten-memory regression (F-2) fails on
both halves of its fix; the delta window (F-4) and the M-20 audit union (F-10)
fail on five assertions between them; and the segment-aware selection (F-5)
returns exactly the `approved` the review reported.

**Crypto is proved, not asserted.** `MemoryExportCryptoTests` runs the RFC 9180
Appendix A.2 base-mode vectors for this suite through the same `HPKE` the wrap
uses (provenance in D-BB-E-5), with a wrong-AAD negative beside them; pins the
`mif1-hkdf-v1` salt and info strings against values computed outside the code
path with `python3` + `hashlib`; and checks that a segment sealed as
`memories/0` opens neither as `bodies/0` nor at index 1.

**Schema validation runs in-process.** `MIFSchemaValidator.swift` is a JSON
Schema subset validator over an embedded copy of `contracts/mif-v1.schema.json`,
and the test asserts `assertionsEvaluated > 500`. It is deliberately not a
`python3 -c 'import jsonschema'` shell-out: §10 requires the validator be proven
to have run, and an optional import that fails open on every machine that never
installed it is the exact failure mode it names.

An unknown JSON Schema keyword is a hard failure — but that guard only fires on
nodes an instance actually reaches, so a keyword under an *optional* field no
fixture populates used to be invisible. `auditKeywords()` closes that: it walks
the contract document itself, once, through the same schema-bearing keywords the
evaluator recurses into, and names anything unimplemented whether or not a
fixture exercises it. With it, "a contract that grows a keyword turns the suite
red" is a property rather than a hope, and a test proves the audit can fail.

Three evaluator weaknesses the review named are fixed with it: `maxLength` is
implemented (minor 2's `source_memory_id` is the contract's first), `^…$`
patterns are matched against the whole string rather than through ICU's `$`,
which also matches before a trailing newline, and `minLength`/`maxLength` count
code points rather than grapheme clusters. Negative fixtures now cover a dropped
required field, a broken enum and a `maxLength` violation, none of which any
test mutated before.

**The vendored contract is pinned.** `MIFContractPinTests.swift` carries its
provenance in the file header — source commit
`439c8d3d425a46b2895c20050eca3bf3d508a90e`, sha256
`fc1a4a267809272ab9fd5e21449b72b055505301e285bab13eba5ecc57be2228`, MIF v1
minor 2, copied byte for byte with no local edit — and asserts that digest, as
D-0021 ruling 5 requires of each side. The two copies had drifted inside one
working day and neither side noticed, because the in-process validator was
passing against the stale one; a failure here now says which of the two things
happened and how to fix it. The licence question for vendoring an interchange
schema into an AGPL codebase stays D-0021 ruling 5's open counsel item.

---

## 7. Review response — F-1 … F-19

Against `docs/memory/reviews/REVIEW-BB-EXPORTER.md`.

| # | Finding | Status |
|---|---|---|
| F-1 | manifest carries no `crypto` object | **fixed** — emitted, and emittable only because the wrap is now RFC 9180 (D-BB-E-5) |
| F-2 | `--carry-orphans` resurrects a forgotten memory | **fixed** — orphanhood is decided from every authority row before classification, a carry whose subject is tombstoned is refused, and `no_resurrected_tombstone` is computed from the records the bundle carries instead of hardcoded `true`. Regression test fails on either half |
| F-3 | `rollups[].tuple` mislabelled for section 06 | **fixed** — declared per section; the orphan's `""` third element is a real provenance digest; and the digest covers the `source_content_hash` values section 07 actually carries, so the declaration is reproducible. A test recomputes every tuple the way an importer does |
| F-4 | `--since-audit-seq` filters nothing | **fixed** — `.delta` carries the watermark as a required parameter, `--since-updated-at-ms` supplies it, and half a window is a refusal. The test counts rows across three windows |
| F-5 | latest-wins is not segment-aware | **fixed** — `seq DESC` inside an intact segment, `(ts, seq)` only across a boundary, `rejected` on any tie. Five tests separate the cases |
| F-6 | vendored contract stale, no sha256 pin | **fixed** — re-vendored at `439c8d3d`, pinned by test, provenance in the header, `maxLength` implemented in the same commit |
| F-7 | crypto diverges from D-0021 on every point | **fixed** — see D-BB-E-5's table; two forced departures recorded there for the spec owner |
| F-8 | an unwrapped bundle is writable, silently | **fixed** — `recipient` is non-optional in the library and `--recipient` is required at the CLI (`EXPORT_RECIPIENT_REQUIRED`); rehearsal mints a throwaway and `report.json` says so in `next_action` |
| F-9 | `recipient_store_id` holds the *source* fingerprint | **fixed** — it holds the descriptor's target store id, it is printed in the export confirmation, and it is no longer blanked for the determinism digest (which is how the bug survived that test) |
| F-10 | a delta drops the audit row its review event names | **fixed** — section 09 selects the union of the window and every `audit_seq` a carried human-origin row cites |
| F-11 | `store_id` derived from the inode | **fixed** — from the local `devices` row, with the audit chain's genesis hash as fallback; a store with neither is a refusal. Tested through a `VACUUM` and a backup |
| F-12 | `lost.csv` names ids in no `id-map.csv` | **fixed** — one memoising canonicaliser records every rewrite, which also covers tombstone subjects |
| F-13 | the delete obligation is a tautology | **fixed** — a set difference between owed delete subjects and emitted tombstone subjects, so a duplicate-subject delete no longer throws falsely |
| F-14 | `--max-section-bytes` is chunk size, not rotation | **partly fixed, and the rest stated** — rotation is real, one file per sealed segment, `segments` counts files. Streaming is still owed and D-BB-E-7 now says so with the estimate instead of claiming the rotation covered it |
| F-15 | the gate test skips itself silently | **fixed** — `XCTAssertTrue` on the corpus, not `XCTSkipUnless`. A missing corpus is a packaging defect, not a fact about the machine |
| F-16 | `verify` verifies nothing | **fixed** — signature, `bundle_id` ↔ `content_digest`, `hashtree.json` ↔ manifest, every segment file and its size, the wrapped key's shape, and the recipient binding. It also names what it did not check |
| F-17 | `p5-check` is advertised but unreachable | **fixed** — wired, taking the target id set and the required version from the runbook; `concurrent_writes` is real, from an audit head read either side of the snapshot |
| F-18 | reconciliation `source_rows` adjusted until it balances | **fixed** — edges and aliases have their own rows, a carried orphan is counted where it belongs, and `memory_body_snapshots` balances over its own rows (it did not before: the fixture bundle was `held` on every run and no test looked) |
| F-19 | raw interpolation of the cipher key into a PRAGMA | **fixed** — bound as a statement argument |

Two items the review raised that are **not** ours to close, recorded for the
spec owner: the `recipient_key_id` type conflict and the two missing
`export_error` codes, both in D-BB-E-5. One item stays open by design: D-0021
ruling 6's interop gate — a BB-E bundle imported by the Rust importer — is Wave
13's, and no bundle can be tried against it from this side.

The review's incidental notes are also closed: `dedup_partition`'s undocumented
`"agent" → chat` mapping is now in D-BB-E-12, and `--allow-long-read` is
required for a dry run too, since a dry run holds the same long read.

---

## 8. What BB-E does not do

- It never writes to the source store, never mints a key, and never re-keys.
- It never stops `com.openburnbar.daemon` and never changes the store file's
  mode. D-0007 forbids both: that LaunchAgent and that one `openburnbar.sqlite`
  serve roughly twenty unrelated RPC families, and BurnBar must keep working
  without Po'dex and without memory. The P5 proof is `audit_head` unchanged
  across the final delta — an observation of the shared file, which stays valid
  with the agent up.
- It builds no importer. The bundle is BurnBar → core, one way.
- **It does not stream.** It is a fixture-scale exporter today: correct against
  the GRDB fixtures D-0021 ruling 6's interop gate requires, and unable to hold
  an 8.4 GB store inside §2's 512 MiB ceiling. D-BB-E-7 has the estimate and the
  work.
- It cannot verify a bundle's plaintext. The bundle key is wrapped to the
  recipient and never kept, so `memory verify` checks the signature, the
  manifest and the files on disk, says so, and points at the importer for the
  rest.
