# Pensieve vector-cloak leakage analysis

**Status:** accepted leakage, documented. **Scope:** the per-user orthonormal
vector cloak only — `cloakVector` in
`tools/openburnbar-mcp-remote/src/embed.ts`, mirrored byte-for-byte in
`OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/PensieveVectorCloak.swift`.
This is the honest, one-page accounting of what the cloak protects versus what it
leaks. It supersedes any earlier framing that sold the cloak as an
embedding-inversion countermeasure.

## What the cloak is

Each member's vault key (HKDF seed) deterministically derives an orthonormal
matrix **Q**, realized as a product of 24 Householder reflections
(each `Hᵢ = I − 2·vᵢvᵢᵀ`, `‖vᵢ‖ = 1`). Every embedding `x` (index-time and
query-time) is stored/sent as `Qx`. The server never receives the key, so it
never recovers `x`, `Q`, or `Q⁻¹ = Qᵀ` on its own.

## The math (one line that drives everything)

Q is orthonormal ⇒ it is **inner-product-preserving and norm-preserving**:

```
<Qx, Qy> = xᵀ Qᵀ Q y = xᵀ y = <x, y>     and     ‖Qx‖ = ‖x‖
```

Therefore **cosine similarity is preserved exactly**:
`cos(Qx, Qy) = cos(x, y)`. That single identity is simultaneously:

- **the feature** — the server can run `findNearest` COSINE over cloaked vectors
  and get the same ranking as raw bge space, so E2EE recall works at all; and
- **the leak** — anything derivable from pairwise cosines is derivable from the
  cloaked vectors alone, with no key.

The proof is asserted in
`tools/openburnbar-mcp-remote/src/cloakLeakage.test.ts`
(`cosine(a,b) == cosine(cloak(a),cloak(b))` within `1e-9`).

## What the cloak PROTECTS (proven properties — claim only these)

1. **Hides the public-model (bge) basis.** Stored vectors are not expressed in
   the raw bge coordinate frame. Off-the-shelf embedding-inversion models
   (vec2text-style) are trained to map **raw bge-space** vectors back to text;
   they cannot be pointed **directly** at `Qx`, because `Qx` lives in a secret,
   per-user rotated frame. This raises the attacker's bar. It is **not** a proof
   that the vectors are non-invertible — an adversary who learns `Q` (key
   compromise), or who mounts a sufficiently strong learning attack against the
   preserved geometry, is out of scope of this control.
2. **Per-user distinct stored bytes.** Q is per-user, so the **same** plaintext
   embedded under two different members' keys produces **different** stored
   vectors (relative L2 distance `‖Q_A x − Q_B x‖ / ‖x‖ ≈ 0.74`, measured at
   384-dim with the shipped 24-reflection cloak; asserted in
   `cloakLeakage.test.ts`). The exact float payload is not byte-equal across
   users, so a naïve byte/exact-match join across tenants finds nothing.

> **Important — cross-tenant linkage is NOT fully defeated by the current cloak.**
> "Different bytes" is **not** "uncorrelated." With only 24 Householder
> reflections in 384-dim, `Q_A` and `Q_B` are each far from a Haar-random
> rotation, so `cos(Q_A x, Q_B x) ≈ 0.77` (measured; see "The reflection-count
> reality" below). A curious server can therefore still **correlate the same
> plaintext across two tenants by cosine similarity** — the cloak does not give
> cross-tenant unlinkability at the shipped parameters. Treat cross-tenant
> linkage resistance as **partial** (defeats exact-match joins, not
> similarity-match joins) and see the trigger section for the fix.

## What the cloak LEAKS (accepted, in scope)

**Single-user relative geometry.** Because Q preserves all inner products, the
server — holding only one user's cloaked vectors, **without the key** — can
compute:

- the **full pairwise cosine similarity matrix**;
- the **k-nearest-neighbor graph** (which chunks are semantically close);
- **clusterability** (topic/cluster structure, cluster sizes, outliers);
- **similarity-based dedup** (near-duplicate chunks collapse identically to raw
  space).

**Cross-tenant similarity linkage (partial leak).** As noted above, the
shipped 24-reflection cloak does **not** decorrelate the same plaintext across
users; cosine ≈ 0.77 across two tenants' cloaks of the same vector. A server can
flag "these two tenants likely stored a near-identical item" by thresholding
cross-tenant cosine, even though it never recovers the item.

In short, the cloak hides the *basis*, not the *relative geometry* — within a
tenant **or** across tenants. The server learns the **shape** of a user's
knowledge graph (topic count, cluster tightness, near-duplicates, recall
fan-out), and a coarse cross-tenant "same-item" signal, even though it never
learns *what* any item says.

### The reflection-count reality (why cross-tenant cosine is ~0.77, not ~0)

`cos(Q_A x, Q_B x) = cos(x, Rx)` where `R = Q_Aᵀ Q_B` is a product of `2·k`
Householder reflections (`k = 24` per user). A single reflection only
significantly perturbs the component of a generic vector along its unit normal;
in `d = 384` dimensions you need `k` on the order of `d` before `R` behaves like
a Haar-random rotation and the cross-user cosine collapses to ≈ 0. Measured mean
`|cos(Q_A x, Q_B x)|` versus reflection count `k` (384-dim, random keys):

| reflections `k` | mean \|cross-user cos\| |
|---|---|
| **24 (shipped)** | **0.77** |
| 48 | 0.59 |
| 96 | 0.35 |
| 192 | 0.12 |
| 384 (≈ full rotation) | 0.04 |

24 reflections is sized for thorough **within-vector** coordinate mixing
(`> log2(384) ≈ 8.6`, defeating signed-permutation structure → basis hiding),
**not** for cross-user decorrelation, which needs `k ≳ d`. This is a parameter
choice, not a bug in the math; raising `k` is a behavior/parity change (it
alters every stored vector and must stay byte-identical to the Swift mirror), so
it belongs in a versioned re-cloak migration — see the trigger section.

### Out of scope for this document

Plaintext metadata leakage is handled elsewhere and is **not** a cloak property:
ciphertext, chunk counts, timestamps, and `namespace = uid` are covered by
`docs/PENSIEVE.md` §"Security & threat model." This page is strictly about the
geometry the cloaked **vectors** expose.

**Per-vector metadata after B-SEC-2.** The earlier per-vector cleartext side
channels are gone: `commitKnowledgeBatch` no longer stores the SHA-256
`contentHash` (a confirm-the-guess oracle), the real `sourcePath` (it is already
inside the AES-256-GCM `sealedMetadata` blob), or the cleartext `sourceSlug`.
Dedup/idempotency now uses `dedupHash` — a **vault-keyed HMAC of the plaintext**
the device computes (HKDF-derive a per-user dedup key from the vault key, then
HMAC), stamped with `dedupHashVersion` (0 = legacy cleartext SHA-256 awaiting
re-ingestion, 1 = vault-keyed). The source filter key is `slugHmac`, a vault-keyed
HMAC of the slug. Both are keyed, so the same plaintext/slug under two members'
keys produces **different** stored values and the server cannot confirm a guessed
plaintext by hashing it. The two remaining cleartext per-vector columns are
**accepted leakage**:

- **`sourceKind`** — one of three coarse buckets (`repo_docs` / `notes` /
  `chat_memory`); a server-side `findNearest` pre-filter. It carries no content,
  only which of three lanes a chunk lives in.
- **`byteCount`** — the chunk's plaintext length, the input to the per-tier
  `count()` + `sum(byteCount)` cap aggregates. A length, never content.

Both are load-bearing (server-side filtering / cap enforcement without the key)
and low-sensitivity, so they are accepted in the current threat model.

## Accepted-leakage rationale (early-commercial product)

For Pensieve's current threat model this leakage is **accepted**:

- **The content is sealed.** Every chunk's text + metadata is AES-256-GCM sealed
  under the vault key. The geometry leak exposes *structure*, never *content*:
  the server sees "these two opaque blobs are similar," never the blobs' meaning.
- **Single-user graph shape is low-sensitivity** relative to content.
- **Cross-tenant linkage is only a coarse "same-item" signal, not identity.**
  Even where cross-tenant cosine is high, the server learns "these two tenants
  hold a near-identical sealed item," never which item — and our isolation model
  already keeps each tenant's reads scoped to their own namespace.
- **Geometry preservation is load-bearing.** It is exactly what lets recall run
  server-side without the key. A scheme that hid relative geometry (see triggers
  below) would forfeit the cheap `findNearest` path that keeps per-member COGS at
  cents/month — the cost discipline the product is built on.
- **Honesty over over-claiming.** We claim basis-hiding (no *direct* off-the-
  shelf inversion) and per-user distinct stored bytes (no exact-match
  cross-tenant join), which are true. We do **not** claim distance-hiding,
  inversion-proofness, **or full cross-tenant unlinkability** — at 24 reflections
  those would be false.

## Trigger — what would force a stronger scheme

Re-open this decision and move to a distance-distorting / asymmetric transform or
homomorphic encryption (HE) if **any** of the following becomes true:

- **Threat model upgrade:** the adversary now includes an honest-but-curious or
  compromised server whose *single-user* relative-geometry knowledge (topic
  graph, near-dup structure, recall patterns) is itself classified sensitive
  (e.g. regulated/PHI/PII-structure, or an enterprise contract that forbids the
  provider learning knowledge-graph shape).
- **Inference attack demonstrated:** a practical attack reconstructs meaningful
  plaintext or category labels from the preserved geometry + cloaked vectors
  alone (without the key), defeating property (1) in practice.
- **Cross-tenant linkage becomes in-scope:** the threat model starts to care
  about the server correlating the *same plaintext across tenants*. The shipped
  24-reflection cloak leaves cross-tenant cosine ≈ 0.77, so this is **not**
  covered today. The cheapest mitigation is a versioned re-cloak that raises the
  Householder count to `k ≳ dim` (≈ a full Haar-random per-user rotation, where
  cross-tenant cosine → ≈ 0) in both `embed.ts` and `PensieveVectorCloak.swift`,
  gated behind a new `embeddingModelVersion`/cloak-version so existing vectors
  migrate cleanly. (This is a behavior/parity change, hence out of scope for the
  docs-only honesty pass that created this file.)
- **Compliance demand:** a customer/regulator requires provable hiding of vector
  relationships, not just content confidentiality.

Candidate replacements when triggered (each trades cost/latency for stronger
hiding): a **full-rotation re-cloak** (`k ≳ dim` Householder reflections — keeps
single-tenant geometry but kills cross-tenant cosine); an **asymmetric /
distance-distorting transform** (different maps at index vs. query time so
stored-pair distances are not directly computable — also breaks single-tenant
geometry leak); **locality-obscuring / noised** embeddings; or **HE /
encrypted-search** so the server ranks without ever seeing comparable vectors.
The last three forfeit the free server-side `findNearest` path and must be
re-costed before adoption.

## Verify

```bash
cd tools/openburnbar-mcp-remote
npm run build
node --test lib/*.test.js   # cloakLeakage.test.js pins geometry-preserved +
                            # per-user-distinct-bytes + measured cross-tenant cos
```
