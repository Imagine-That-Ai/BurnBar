# Pensieve leakage analysis — what the vector cloak protects vs. leaks

Companion to [`PENSIEVE.md`](PENSIEVE.md). This is the honest accounting the
privacy page links to: precisely what the vault-key vector cloak buys, precisely
what it does not, the math that bounds both, and the trigger that would force a
stronger scheme. Every number below is pinned by
[`tools/openburnbar-mcp-remote/src/cloakLeakage.test.ts`](../tools/openburnbar-mcp-remote/src/cloakLeakage.test.ts)
so the claims cannot drift from the implementation.

## The mechanism

Before upload, every embedding — index *and* query — is multiplied by a
per-user **orthonormal transform Q**:

- Derived from the vault key (HKDF seed → a product of **24 Householder
  reflections** in **384 dimensions**).
- Implemented in `tools/openburnbar-mcp-remote/src/embed.ts` (`cloakVector`),
  mirrored in `PensieveVectorCloak.swift`.
- Q is **exactly** orthonormal: `⟨Qx, Qy⟩ = ⟨x, y⟩` and `‖Qx‖ = ‖x‖`. The test
  proves pairwise cosine drift stays under `1e-9`.

That single property — orthonormality — is the whole story. It is why the cloak
helps and why it leaks.

## What it protects

| Guarantee | Why it holds |
|---|---|
| **The public bge basis is gone.** | Stored vectors are no longer in raw bge coordinates, so off-the-shelf embedding-inversion models — which expect bge-space input — cannot be applied *directly*. Raises the bar; it is not a proof of non-invertibility. |
| **Per-user distinct stored bytes.** | Q is per-user. The same plaintext under two members' keys yields different vectors — measured relative L2 separation ≈ **0.74** (test asserts `> 0.3` per seed). An exact-match cross-tenant join fails. |
| **Search quality is untouched.** | Cosine is preserved exactly, so k-NN ranking, dedup thresholds, and clusters are identical on-device and server-side. The cloak is free: zero recall cost. |

## What it leaks — accepted, documented

| Leakage | Consequence |
|---|---|
| **Relative geometry is fully visible.** Orthonormality preserves it by construction. | The server can compute the complete pairwise cosine matrix, k-NN graph, clusters, and similarity dedup over cloaked vectors **without the key** — within one user's vectors. The cloak is *not* an inversion-proof or distance-hiding scheme. |
| **Partial cross-tenant unlinkability only.** `cos(Q_A x, Q_B x) = cos(x, Q_AᵀQ_B x)`; with 24 reflections in 384-dim, `Q_AᵀQ_B` is far from Haar-random. | The same plaintext stays **cosine ≈ 0.77** correlated across tenants (test pins the measured band, mean |cos| high, min > 0.4). A curious server can correlate the same memory across members by *similarity*. Byte-equality is defeated; geometry is not. Full decorrelation needs ≈ `dim` (384) reflections — a versioned re-cloak, not the shipped parameter. |
| **Deterministic repo match tokens.** `repoMatchToken` is a global HMAC — the same repo gives the same token for every user. | The server can see that two members connected the same repo, and could dictionary-confirm *which* public repo against a candidate list if the server-side match key leaked. Not per-user salted. |
| **Reversible cleartext `sourceSlug`.** | `knowledge_repos` rows and `knowledge_sync_manifests` document ids carry a slugified source path. Replacing them with opaque per-user ids is tracked hardening (privacy-leak-remediation F4/F5). See [`searchable-index-leakage.md`](searchable-index-leakage.md). |

## Why this leakage was accepted

1. **The asset is prose memory, not source code.** Cross-tenant cosine ≈ 0.77
   correlates *that* two members stored the same item — it does not hand the
   server the plaintext. Code chunks can carry live secrets and proprietary
   structure, so **Project Code Memory stays local-only**; hosted code sync is a
   separate opt-in design that re-evaluates this leakage first.
2. **The alternative kills the product.** Hiding geometry means giving up
   server-side similarity search — the feature itself.
3. **Everything sensitive still requires the device vault key.** Cleartext,
   `sourcePath`, `repoFullName`, and the oracle all live behind sealed
   metadata; the server never stores or serves them.

## The trigger that would force a stronger scheme

- Hosting **code** or other high-entropy content cross-tenant → re-evaluate
  before any sync opt-in; likely requires ≈ 384 reflections or a different
  construction (e.g. per-cluster cloaks).
- A measured cross-tenant linkage incident, or a compliance requirement for
  unlinkability → bump `CLOAK_REFLECTIONS` toward `dim` behind a versioned
  re-cloak migration.
- `repoMatchToken` / `sourceSlug` hardening (F4/F5) ships → update this doc and
  [`searchable-index-leakage.md`](searchable-index-leakage.md).

When in doubt, the test is the contract: if `cloakLeakage.test.ts` ever shows
the cross-tenant cosine collapsing toward 0 unexpectedly, the implementation
has changed — update this doc, don't celebrate.
