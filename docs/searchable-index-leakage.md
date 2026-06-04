# Searchable session-log index — leakage analysis

**Status:** accepted leakage, documented (honest-disclosure; no plaintext-at-rest
break). **Scope:** the deterministic keyword/semantic search index for session
logs and conversations — the per-term keyed digests produced by
`searchIndexTokenHashes()` /`tokenHashes`/`semanticHashes` in
`OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/CloudVaultCrypto.swift`,
committed by `functions/src/callables/encryptedSearch.ts`
(`commitEncryptedSearchIndexBatch`) and
`functions/src/callables/encryptedSearchIndex.ts` into
`users/{uid}/cloud_search_chunks` (inline `tokenHashes`/`semanticHashes`) and
`users/{uid}/cloud_search_postings` (one `postingKey` row per term×chunk), and
queried by `searchEncryptedConversationIndex`.

This is the companion to
[`docs/pensieve-leakage-analysis.md`](pensieve-leakage-analysis.md) (which covers
the vector cloak). It supersedes any framing that called these digests merely
"opaque hashes" — they are opaque *byte-wise*, but they are **deterministic**, and
determinism leaks structure.

## What the index is

Every searchable term (and its prefixes and exact phrases) is mapped to a stable,
vault-keyed digest: `digest(term) = truncate(HMAC-SHA256(searchKey, term), 16)`,
where `searchKey` is HKDF-derived from the per-user vault key. The server never
holds the key, so it cannot reverse a digest to its term or re-derive a digest for
a guessed term **on its own**. The same term always maps to the same digest
*within one user's index* (that is what makes lookup work): a query term is hashed
the same way and matched against the stored `postingKey`s.

## The property that drives everything

The map is **deterministic and equality-preserving**: `term₁ == term₂ ⇒
digest(term₁) == digest(term₂)` (for a fixed user key). That single property is
simultaneously:

- **the feature** — a query digest can be matched against stored posting rows, so
  encrypted keyword search works at all; and
- **the leak** — anything derivable from *equality and frequency of digests* is
  derivable from the stored index alone, with no key.

## What the index PROTECTS (claim only these)

- **Term plaintext** stays sealed: a digest is a truncated keyed HMAC; without the
  vault key the server cannot read a term or compute the digest of a guess.
- **Titles, snippets, bodies, project/path text** stay AES-256-GCM sealed — the
  index carries no readable content, only digests + counts.
- **Cross-user term equality** is broken: the per-user `searchKey` means the same
  term under two members' keys yields different digests, so the server cannot join
  two users' indexes by shared terms.

## What the index LEAKS (to an honest-but-curious server with raw Firestore read)

Reconstructable **without any key**, per user:

1. **Per-term document frequency** — the length of each term's posting list
   (`cloud_search_postings` rows sharing a `postingKey`) = how many chunks contain
   that term.
2. **Term co-occurrence** — which digests appear together on the same `chunkID`
   gives the full term×document incidence matrix and the co-occurrence graph.
3. **Per-document term density** — `tokenHashes.length` per `cloud_search_chunks`
   doc (capped by `MAX_TOKEN_POSTING_EDGES_PER_CHUNK`, which bounds but does not
   hide density).
4. **Prefix / phrase structure** — `searchIndexTokenHashes()` emits separate stable
   digests for prefixes and exact phrases, so the server sees prefix/phrase fan-out
   and partial-word relationships.
5. **Query access patterns** — `searchEncryptedConversationIndex` matches query
   digests against the same deterministic posting keys, so the server learns which
   stored terms a query touched and can link repeated queries for the same term.

Against natural-language corpora, (1)–(2) are exactly the inputs to the
well-studied **deterministic-SSE frequency / co-occurrence inference attacks**,
which can narrow or recover plaintext terms from frequency statistics even though
every stored snippet/title/body remains sealed. **This is structure leakage of an
encrypted index, not a plaintext-at-rest break.**

## Honest claim ceiling

Say: *"The server runs your search without reading your queries or your content in
the clear; the keyword index is deterministic, so it reveals which terms repeat and
co-occur (search structure), not the terms themselves."* **Do not** say "the server
learns nothing" — it is false for this index.

## Optional hardening (behavior change → index-version bump / re-sync = migration)

- Drop the inline `cloud_search_chunks.tokenHashes`/`semanticHashes` arrays once the
  array-contains-any fallback is removed from `searchEncryptedConversationIndex`
  (postings already serve search) — removes the per-doc density signal (#3).
- Uniformize / cap posting fan-out per chunk to flatten the frequency signal (#1).
- The strong fix (volume-hiding / response padding / frequency-smoothing or an
  oblivious-SSE construction, or folding keyword search into the `findNearest`
  vector path) is a large redesign, gated behind a threat-model upgrade. Not
  shipped; not implied by any current copy.

## Related hash-oracle status

Current session-log writes use vault-keyed HMACs for `bodyHash` and per-chunk
`contentHash` and stamp `bodyHashVersion >= 2` / `contentHashVersion >= 2`; current
blob envelopes store `plaintextHMAC` with `integrityHashVersion`, not
`plaintextSHA256`. Those values are still deterministic equality tokens inside one
user's vault, but a server reader cannot confirm a guessed body/chunk without the
vault key.

Legacy v1 rows and schema-1 blob envelopes can still carry raw SHA-256
`bodyHash`/`contentHash`/`plaintextSHA256` for migration readback. Export and
scanner gates treat those legacy raw hashes as non-opaque leakage unless a sibling
version field proves the value is keyed.
