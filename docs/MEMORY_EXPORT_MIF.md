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
`hashtree.json`, `sections/<NN-name>/<index:05>.seg`, `lost.csv`, `id-map.csv`
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

Each section is written as one `<index:05>.seg` per sealed segment, rotating at
`--max-section-bytes` of ciphertext (default 256 MiB). The file index is the
segment index the nonce and the chunk AAD are derived from (D-0031 ruling 1:
five decimal digits, zero-padded, from 0).

**An empty section seals the empty string** (F-3). Sections `01`, `03` and `08`
are empty in every bundle BB-E writes today, and each used to declare
`{bytes: 0, segments: 1}` over a **0-byte** `00000.seg`. A ChaCha20-Poly1305
segment is never shorter than its 12-byte nonce and 16-byte tag, so an importer
that opens every segment the manifest declares — which is what §2's "a reader
knows every path in the bundle from the manifest alone" invites — failed on three
sections of every bundle, while one that special-cased `bytes == 0` did not: a
fork in the format at its first interop run. An empty section now declares
`{bytes: 28, segments: 1}` and its one segment is a real seal that opens to zero
plaintext bytes, hence to zero records, which is exactly what `row_count: 0`
says. **The importer side reads it the same way: open every declared segment,
expect no records from this one.**

`{bytes: 0, segments: 0}` is the other option REVIEW-BB-EXPORTER-3 offered, and
the contract cannot express it — `section_header.segments` is `{"type":
"integer", "minimum": 1}` at the vendored HEAD, so a bundle declaring zero fails
validation on both sides. §2 itself says nothing about the empty case beyond
"`manifest.sections[].segments` is that count", so the schema is the tiebreak.

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
| Hash tree (D-0031 ruling 1): `ht_key = HKDF-SHA256(salt = "imaginethat.memory.hkdf.v1", bundle_key, "mif1/hashtree/v1")`, leaves `HMAC(key, 0x00 ‖ chunk)`, folds `HMAC(key, 0x01 ‖ l ‖ r)`, 4 MiB chunks over ciphertext | as stated. One salt constant, not two; pinned outside the code path by a test that recomputes a leaf straight from CryptoKit |
| `manifest.sig` (D-0031 ruling 1): Ed25519 over the 32 raw bytes of `content_digest`, b64url unpadded | as stated. `verify` shares the preimage through one `sign`/`verifySignature` pair, and **recomputes `content_digest` from the manifest on disk**, so the signature is a signature over the manifest (F-1, stated once below) |
| Segment files `sections/<NN-name>/<index:05>.seg`; root computed once, carried in `manifest.hashtree.root` and `hashtree.json`, input to `content_digest` | as stated. The bundle root is **the same fold**, applied to the eleven raw 32-byte section subroots in section order with an odd tail carried up (F-2, pinned to a value below). The one deliberate gap: `key_derivation` still emits the contract's pre-D-0031 `const` (D-BB-E-14) |

**The bundle root, stated once.** §2's tree is `leaf = HMAC-SHA256(ht_key,
0x00 ‖ chunk)` and `fold = HMAC-SHA256(ht_key, 0x01 ‖ left ‖ right)   with
last-node promotion`, and BB-E folds the **section subroots into the bundle root
with that same fold**: the eleven raw 32-byte subroots, pairwise in section
order, an odd node at any level carried up unchanged rather than paired with
itself. `manifest.hashtree.root` is that value, `hashtree.json` carries the same
bytes, and it is a member of the manifest `content_digest` covers.

Until F-2 the subroots were joined as ASCII **hex** separated by U+001F and
HMAC'd in one message — a construction D-0031 does not describe, which no
importer folding per ruling 1 could reproduce: a different root, a different
`content_digest`, a different bundle identity for the same bytes. Nothing pinned
it either. It is pinned to a **value** now:
`MemoryExportCryptoTests.test_theBundleRootIsTheD0031FoldOverTheRawSubroots`
carries the eleven subroots and the bundle key REVIEW-BB-EXPORTER-3 recomputed
independently in Python, and asserts the root that reference produced
(`a3d92105…`, against the old join's `e9bdcabd…`). Mutating the fold's domain
byte turns it red with three assertions.

**What `content_digest` is a digest of, stated once.** §2's determinism claim —
*"Determinism is claimed on `content_digest` and on the manifest minus
`{created_at_ms, recipient_key_id, wrapped key, signature}` — JCS
canonicalisation, fixed sort keys …"* — and D-0031 ruling 1's *"the digest
already binds the manifest minus the four excluded members, §2 line 244"* fix one
preimage, and BB-E computes exactly it:

```
content_digest = sha256( JCS( manifest minus {created_at_ms, recipient_key_id,
                                              bundle_id, content_digest} ) )
manifest.sig   = Ed25519(the 32 raw bytes of that digest), b64url unpadded
```

Two of §2's four excluded members are not manifest members at all — the wrapped
key is `keys/wrapped-bundle-key` and the signature is `manifest.sig` — so
removing them from a manifest is a no-op and the two that remain are §2's.
`bundle_id` and `content_digest` come off because a digest cannot bind itself,
and `bundle_id` is `"bnd_" + content_digest[0..<32]` (§4), so it carries nothing
the digest does not. **Everything else is inside it**, `hashtree.root` and every
per-section `subroot` included — which is D-0031's "the root is an input to
`content_digest`" — so the section plaintexts are bound transitively through the
keyed tree over the ciphertext that seals them, and the crypto profile, the
recipient binding, `user_id`, `not_exported` and the roll-up digests are bound
directly.

Until F-1 the digest was `sha256(JCS({<section>: sha256(plaintext), …,
hashtree_root}))` — the plaintexts and the tree and nothing else — so every
manifest member above could be rewritten on the wire under a signature that
still verified, and `verify` never recomputed the digest to notice. It does now,
from the manifest bytes on disk; and because the claim is about MEMBERS rather
than bytes, a manifest reformatted by another JSON writer still reproduces its
digest while a changed value never does. Where the bundle carries a second,
independent witness of the same fact — `rollups[]` against the section headers,
`not_exported` against `report.json`'s per-table view, the recipient members
against the descriptor — `verify` also NAMES the member; `crypto`, `user_id` and
the other members the bundle witnesses once are named by the digest failure as a
group, because naming them individually would need a second copy of the manifest
that a verifier on the operator's own disk does not have.

**Three departures, all forced, all here rather than in the code's head —
all three now CLOSED, kept for the archaeology:**

1. ~~**`manifest.recipient_key_id` cannot hold D-0025's id.**~~ **CLOSED by R4.**
   D-0025 retyped the field to `recipient_key_id_null` and the schema was
   re-vendored; the manifest carries the `rcp_` id and the R4 test opens the
   HPKE wrap with exactly that string as the aad. The struck paragraph below
   is what the second review found stale. D-0025 ruling 2
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
2. ~~**`EXPORT_HPKE_UNAVAILABLE` and `EXPORT_RECIPIENT_REQUIRED` are not in the
   contract's `export_error` set,**~~ **CLOSED by Q-24.** Both codes are in the
   contract now and the two Swift enums are merged into `MIFExportError`. What
   remains below is the history. which `reconciliation_report.export_error`
   validates against. They live in their own Swift enum so a refusal can never
   produce a report no validator accepts. Both fire before any bundle or report
   is written. **For the spec owner:** add them to the closed set.
3. ~~**`manifest.sig` is not byte-reproducible.**~~ **CLOSED by Q-24**, which
   restated the determinism claim around a randomized signature; CryptoKit's
   `Curve25519.Signing` is still *randomized*,
   so two signings of identical bytes under one key differ — both valid, and the
   on-disk determinism test is the evidence. Nothing downstream breaks, because
   §2's determinism claim already excludes the signature along with
   `created_at_ms`, `recipient_key_id` and the wrapped key. **For the spec
   owner:** drop the parenthetical, or require a deterministic implementation
   and say which.

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
`<index:05>.seg` per sealed segment (D-0031), rotating at `max_section_bytes` of
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
classifier already carries the `cloud` branch (§3.1 row 15) so landing the reader
does not touch classification.

**`isCloudOnly` is a constant `false`, not a wiring — correcting a commit
subject.** Commit `b7f7941f18` is titled "… `isCloudOnly` is wired", and it is
not: the exporter passes the literal `false` at its one classify call site. The
argument for the value is sound — every row BB-E classifies comes from the
authority store, which is local by construction, so row 15's shape cannot arise
from these sources and no cloud-only approved row can be mislabelled
`v51_backfill` — but the claim was wrong, and its consequence is worth stating
plainly (F-7): **§3.1 row 15 is unreachable in a real export today and
`MIFImportOriginDetail.cloud` is production-dead.** The row-15 tests pin the
branch the future vault reader will feed; the wiring itself is that reader's
work.

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


### D-BB-E-15 — `manifest.not_exported` is a SOURCE-ROW count, summed across tables

§10's closed sum is **per logical table**: `source_rows == exported + Σ
not_exported[reason]`, and `report.json` carries that view one table at a time.
`manifest.not_exported{}` is the roll-up of those sums, per reason code — so it
counts **source rows**, never the records the bundle carries, and a single
`forgotten` memory contributes **two**: the `agent_memories` row and the
`memory_body_snapshots` row the forget left behind. The bundle carries one
tombstone record for the same event, and both numbers are right.

REVIEW-BB-EXPORTER-3 read `forgotten_to_tombstone: 2` as a record count and found
one tombstone (F-4). Nothing about the arithmetic changed; what changed is that
the reading is now written down, pinned by a test that asserts 1 + 1 = 2 across
the two tables against one tombstone record, and **checkable on the wire**:
`verify` sums `report.json`'s per-table `not_exported` and names
`not_exported.<reason>` when the manifest disagrees with it. That is also what
makes an edited `not_exported` a NAMED failure rather than only a broken digest.

### D-BB-E-16 — the case-2 comparator is pinned WHITE-BOX, and cannot be pinned otherwise

§3.1 case 2 orders candidates across a broken or forked boundary by the `ts`
**string** (R2). In BB-E that rule has **no exported consequence**, and the
reason is structural: the comparator only runs when the regime is not intact, and
every such row exits at §3.1 row 7, which discards the winner — `quarantined`,
`import`, `verdict_on_broken_chain`, no `verdict_audit_seq`. Whichever candidate
the comparator picks, the classification is identical.

So `MemoryExportClassifierTests.test_acrossABrokenBoundaryTheTimestampIsComparedAsAString`
asserts on `selectVerdict` directly, and the test now says so in its own header
and proves the claim beside it: both orderings of the same two candidates
classify identically (F-6). BB-E implements §3.1's selection faithfully anyway —
the rule is the spec's, not this exporter's, and a later consumer of
`selectVerdict` (a verdict-conflicts surface, say) would inherit any divergence
silently. The risk the review named is real and stated rather than papered over:
a refactor that drops `selectVerdict`'s visibility drops the pin, and nothing
downstream would go red.

### D-BB-E-14 — the `key_derivation` const still names the pre-D-0031 tree (spec-owner item)

D-0031 ruling 1 pins the hash-tree key as salted HKDF (`salt =
"imaginethat.memory.hkdf.v1"`, the §2.1 salt) with `0x00`/`0x01` domain bytes,
and BB-E implements exactly that. But the contract's
`manifest.hashtree.key_derivation` is still `const:
"HKDF(bundle_key,'mif1/hashtree/v1')"` — the unsalted spelling — at the newest
committed digest, so emitting the salted spelling fails validation on both
sides. BB-E emits the const verbatim and implements the prose; the const update
is a Po'dex-side contract change, recorded here rather than smuggled into a
bundle no importer would accept.

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

What the row actually contributes is narrower than that paragraph used to say
(R9): migration v22 reads `deviceId` from `UserDefaults "openburnbar.device.id"`,
and nothing in the tree writes that key — the live installation identity lives
under the Kernel key `com.openburnbar.deviceId`, which the migration cannot see
(it compiles inside `OpenBurnBarData`, which never imports Kernel, so the
module-local stub wins). Every migrated store therefore carries the literal
`"unknown"`, and the row's `createdAt` is the **only** varying input: two stores
migrated in the same millisecond collide. That is a pre-existing migration
defect BB-E inherits and states, not an installation identity. `report.json`'s
`source` block carries no derivation sentence because it cannot: it is
`additionalProperties: false` in the Po'dex-owned contract, so the derivation
lives here instead of smuggled into a member that means something else — adding
a member needs a Po'dex-side contract change.

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

**An unproven verdict decides nothing, in either direction.** §3.1 row 7 —
`memory.approve` exists but conjunct 5 fails — exports `quarantined` + the
finding `verdict_on_broken_chain`, and that is now literally what BB-E exports.
It used to LOWER the row to `rejected` whenever any candidate in the unverifiable
span carried a `review_status:rejected` label. Safe in direction, and an invented
rule with a cost in the other one (F-5): `memory_audit` is a three-writer table
with no lock and a self-declared `actor`, so a writer who can append a rejection
and break or fork the chain around it could force **any** memory to `rejected` —
and §4's merge makes a rejection permanent and unrecallable, which is the exact
sentence M-13 uses about the mirror-image defect. Two clamps remain and no third:
a stored `rejected` is never raised (row 11), and row 8's winner — a placeable
verdict on an intact chain whose body was rewritten under it — still clamps on
its own label, because a body rewrite does not un-reject a rejection.

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

`OpenBurnBarCore/Tests/OpenBurnBarMemoryExportTests/`, **113 tests**, run on the
Swift door by `scripts/test-openburnbar-swift.sh`:

```
swift test --package-path OpenBurnBarCore --filter MemoryExport
→ Executed 113 tests, with 0 failures (0 unexpected)
```

The count reconciles: `grep -h "func test"` over the target's files sums to
113, and there is no swift-testing `@Test` anywhere in it, so 113 declared is
113 executed (94 at the second review + 19: R4's recipient binding, R5's
bit-flip, R6's refusal, six R8 row exits, R9's entropy, the D-0031 leaf/sig/
roll-up/root pins, and the held-report contract check).

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

**Determinism is checked on disk, not only through a digest.** Two exports of
one store with one bundle key and one clock produce byte-identical artefacts
except `keys/wrapped-bundle-key` and `manifest.sig` — exactly the two §2's
claim excludes, for the two reasons in D-BB-E-5 — and the ciphertext is
identical because the segment nonces are derived rather than drawn. Across two
different bundle keys only `counts_hash` matches, which is the whole of
D-BB-E-11's claim.

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
`e591e7c8e8a71fdd50a562f4d63f14e30e13462b` (Q-30), sha256
`1107c3ec56feb70fa704f49d97f3ac9cf098ea3d97b89afc13e04858db1be487`, MIF v1
minor 2, copied byte for byte with no local edit — and asserts that digest, as
D-0021 ruling 5 requires of each side. Both re-vendor moves since Q-24 were
additive (Q-26's closed hold vocabulary, Q-30's reason/project members), and a
produced bundle plus one record of every emitted type validates against the
new copy out of process (`jsonschema` 4.26.0, draft 2020-12) with **0 failing
assertions over 12 instances**. The two copies had drifted inside one
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

---

## 9. Review response — R-1 … R-9 (second review)

Against `docs/memory/reviews/REVIEW-BB-EXPORTER-2.md` (verdict `return`), fixed
in review order, one commit per finding.

| # | Finding | Status |
|---|---|---|
| R1 | `latest_verdict` promotes a clock-skewed approve when a sibling audit row is untrustworthy | **fixed** — the regime is decided from the row's own candidates and conjunct 5 is checked on every candidate that can win; the review's end-to-end case exports `quarantined` + `verdict_on_broken_chain` (it exported `rejected` until F-5 removed the candidate-label lowering — the R1 property, that the clock-skewed approve is never promoted and nothing unplaceable leaves as `human`, is unchanged). Test fails before, passes after |
| R2 | `ts` parsed as an instant; tie-break reads the action verb | **fixed** — `ts` compared as the lexicographic string §3.1 specifies; the tie is won by the `review_status:` label, never the verb (M-13). Divergence and tie tests |
| R3 | reconciliation cannot fail | **fixed** — `source_rows` is measured once at the source query and never touched again; a row counted but not held fails its table with `source_unreadable` and holds the bundle. A test drives `balanced == false` |
| R4 | `manifest.recipient_key_id` is the wrong string, and the HPKE aad | **fixed** — emits the `rcp_` id (D-0025); the manifest field is the string the wrap was sealed under, proved by opening the wrap with it. Schema re-vendored at `3332bd5b` (`a008cdef…`), validation at HEAD → 0 failures |
| R5 | `verify` does not detect a modified segment | **fixed** — `hashtree.json` carries one unkeyed `sha256` per 4 MiB chunk of every segment file (`segment_sha256`, over ciphertext, so it leaks nothing); `verify` recomputes the stream and names the segment file and chunk on mismatch. A one-bit flip fails |
| R6 | p5-check invents a store id; `concurrent_writes` stays false | **fixed** — both lanes refuse an identity-less store with `EXPORT_STORE_IDENTITY_ABSENT` via one shared `requireStoreID`; `run` sets `report.concurrent_writes` from the head assertion, and the moved-head test pins it |
| R7 | seven classification tests can skip green | **fixed** — the shared helper `XCTFail`s and throws instead of `XCTSkip` (proved red by pointing one test at a missing row); M-20 pins the real seq; the tie test asserts each chain state separately |
| R8 | rows 1/5/10/15 uncovered; `isCloudOnly` unwired; absent label raises stored-`rejected` | **partly fixed** — row 1 asserts `human`/`human_verdict`; rows 5/10/15 and both row-11 raisings have tests. `isCloudOnly` is passed explicitly as the constant `false` and is **still unwired**: this row's commit subject overclaimed it, corrected in D-BB-E-8 and F-7 below |
| R9 | `store_id` comment claims an installation identity | **fixed** — the comment says what the row contributes (`deviceId` is `"unknown"`, `createdAt` is the only varying input, same-millisecond migrations collide); D-BB-E-13 states the migration defect; `report.json` gains no member (closed contract) and the doc says why |

| D-0031 | layout alignment: segment names, hash-tree domains, `manifest.sig`, roll-up tuples | **fixed** — `<index:05>.seg`; salted key with `0x00`/`0x01` domains; signature over the 32 raw digest bytes, b64url; root computed once, carried twice, input to the digest; 05/02 tuples as ruled, JCS-ordered; the rest transcribed but unemitted per §15 item 8. One open const (`key_derivation`, D-BB-E-14) is the spec owner's |
| re-vendor | schema at HEAD | **fixed** — byte-identical to `e591e7c8e` (Q-30), digest `1107c3ec…`, pin updated; in-process suite green; out-of-process validation 0 failures over 12 instances; the held-report test exercises the new `hold_reason` anyOf |

---

## 10. Review response — F-1 … F-8 (third review)

Against `docs/memory/reviews/REVIEW-BB-EXPORTER-3.md` (verdict
`merge-with-fixes`), fixed in review order, one commit per finding.

| # | Finding | Status |
|---|---|---|
| F-1 | `manifest.sig` signs eleven section digests, not the manifest | **fixed** — `content_digest` is `sha256(JCS(manifest minus {created_at_ms, recipient_key_id, bundle_id, content_digest}))`, the preimage §2 and D-0031 ruling 1 both rest on (stated once in D-BB-E-5). `verify` recomputes it from the manifest bytes on disk and names the member wherever a second witness in the bundle can. Each of the review's six edits — `recipient_store_id`, `crypto.aead`, `user_id`, `not_exported`, `sections[5].row_count`, `rollups[0].rollup_digest` — now fails verification; the test drives all six, and reverting the digest to a tree-root-only preimage turns it red with 13 assertions |
| F-2 | the bundle root is not D-0031 ruling 1's fold, and no test pins it | **fixed** — the section subroots fold with the same `HMAC(key, 0x01 ‖ l ‖ r)` and last-node promotion as the tree beneath them, over the RAW 32 bytes in section order (stated in D-BB-E-5). Pinned to the review's own independently computed value `a3d92105…`; mutating the fold domain byte fails it |
| F-3 | three of eleven sections ship a 0-byte `.seg` no AEAD can open | **fixed** — an empty section seals the empty string: `{bytes: 28, segments: 1}` and one real segment that opens to zero plaintext bytes, so every declared segment of every bundle opens. `{bytes: 0, segments: 0}` was refused by the contract (`segments` is `minimum: 1`) and §3 says so. `verify` accepts the bundle and now NAMES a segment shorter than an AEAD seal |
| F-4 | `manifest.not_exported` double-counts across tables | **fixed as a definition, pinned as arithmetic** — the manifest's `not_exported` is the per-reason sum of every table's not-exported SOURCE ROWS (§10's sum is per table), so one forgotten memory is two rows in two tables against one tombstone record. D-BB-E-15 states it, a test asserts 1 + 1 = 2 with one record, and `verify` names `not_exported.<reason>` when the manifest and `report.json` disagree |
| F-5 | row 7 exports `rejected` where §3.1 says `quarantined` | **fixed** — row 7 is `quarantined` + `verdict_on_broken_chain`, as written. The candidate-label lowering is gone and its vector is closed by a test: a writer who appends a rejection and breaks the chain around it can no longer force a row to `rejected`. Restoring the scan turns five classifier tests red |
| F-6 | R2's case-2 comparator no longer affects any exported field | **labelled, and the label is proved** — D-BB-E-16 states that the comparator has no exported consequence because every case-2 row exits at row 7, which discards the winner; the test header says it is white-box and the test asserts that both orderings classify identically. The rule is kept because it is §3.1's, and the refactor risk is recorded |
| F-7 | `isCloudOnly` is reasoned, not wired | **claim corrected** — commit `b7f7941f18`'s subject says it is wired and it is not; D-BB-E-8, the §9 R8 row and the call site now say it is a constant `false`, that §3.1 row 15 is unreachable in a real export, and that `MIFImportOriginDetail.cloud` is production-dead until the vault reader lands. The value itself is unchanged and the reason for it stands |
| F-8 | smaller: a bare `EXPORT_STORE_IDENTITY_ABSENT` literal, flags missing from usage, the audit-genesis rung untested | **fixed** — the export lane names `MIFExportError.storeIdentityAbsent.rawValue` like the p5 lane; `memoryUsage` lists every flag the parser accepts (`--source`, `--accept-degraded-source`, `--max-section-bytes`, `--rehearsal`, `--deterministic-nonces`), with the rehearsal entry saying in as many words that a rehearsal bundle is not an interop fixture; and R9's genesis fallback has a test that recomputes the digest outside the reader and proves the seed is the GENESIS row, not the moving head |

---

## 11. The interop fixture, and the two commands that make one

D-0021 ruling 6's interop gate needs a bundle the Rust importer can **open**.
Neither obvious route produces one:

* **`--rehearsal` is the wrong flag.** `MemoryExportRecipient.rehearsalThrowaway()`
  mints `Curve25519.KeyAgreement.PrivateKey().publicKey` and **discards the
  private half by design** — that is what makes a rehearsal a rehearsal. The
  bundle is sealed to a key nobody holds, `report.json` says so in `next_action`,
  and it is stamped `rehearsal: true`, which an importer refuses outright
  (`MIF_REHEARSAL_BUNDLE_REFUSED`). Correct for what it is for; useless as a
  courier fixture.
* **A real `memory export`** reads the store under `~/Library` and seals to the
  descriptor the importer published — and at fixture time the importer has not
  published one.

So BB-E gains one verb, and the recipe is two commands:

```
openburnbar-cli memory recipient-keypair --out ./fixture-keys
openburnbar-cli memory export --out ./fixture-bundle \
    --recipient ./fixture-keys/recipient.json \
    --snapshot read_txn --allow-long-read
```

`recipient-keypair` mints an X25519 keypair and writes **both halves** into
`--out`: `recipient.json` — the D-0025 three-field descriptor, byte-comparable
with what `memoryctl memory export-recipient` prints — and
`recipient-secret.json`, the private half, `0600`, which is what the interop run
hands its importer. `--store-id` sets the fingerprint the fixture's importer will
present, which becomes `manifest.recipient_store_id`.

It is **its own verb rather than a flag on `export`** on purpose: D-0025 ruling 3
requires `--recipient` whenever a bundle is sealed, and an export that minted its
own recipient would be a second way around that rule. The export above is an
ordinary sealed export taking an ordinary descriptor.

**The fixture handed to the interop run** is built the same way through the
public library API — the CLI's export lane reads the real store, and D-0021
ruling 6 wants a bundle from fixtures — with both key halves and the bundle key
seeded, so it regenerates byte for byte:

```
bundle_id       bnd_95ee02b1f83ca2347422459f3198a411
recipient       rcp_3005b65cea91bf2755860ad621af8cea   store `importer-store-fixture`
contents        6 memories in (one `forgotten` → a tombstone, one proven human
                rejection), 5 memory records, 5 bodies, 1 project, 1 citation,
                2 audit rows, 2 findings; 11 sections, 11 segment files
verify          intact, signature verified, 8 checks, 0 problems
schema at HEAD  20 instances (manifest, report, 18 records), 0 failing assertions
```

Recomputed out of process from the bundle's own files (venv `cryptography` +
`jsonschema` 4.26.0): all eleven subroots, the D-0031 ruling 1 fold root
(`51ff2138…`, equal to `manifest.hashtree.root` and to `hashtree.json`'s), the
unkeyed per-chunk sidecar, `sha256(JCS(manifest minus the four))` equal to
`content_digest`, `bundle_id` following from it, and the Ed25519 signature over
its 32 raw bytes.
