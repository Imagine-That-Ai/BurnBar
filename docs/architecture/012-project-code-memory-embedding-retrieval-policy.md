# ADR 012: Project Code Memory Embedding Retrieval Policy

## Status

Accepted, 2026-06-17.

## Context

Project Code Memory previously stored deterministic content fingerprints in the
embedding tables. Those vectors are useful for reproducibility and storage
accounting, but they are not learned semantic embeddings and must not influence
production ranking.

Dense retrieval also changes the threat model: it increases local storage,
introduces model/version freshness requirements, and can make search quality
look better than it is if stale vectors are fused with current lexical rows.

## Decision

The first supported local embedding provider is **Ollama** through the local
loopback runtime, with `nomic-embed-text` as the default selected model name.
Dense retrieval remains disabled until all of these conditions are true:

- `OPENBURNBAR_CODE_EMBEDDING_PROVIDER=ollama`.
- `OPENBURNBAR_CODE_EMBEDDING_MODEL` is set or defaults to `nomic-embed-text`.
- The active embedding version is not the deterministic fingerprint version.
- Every current code chunk for the project has a vector for the active embedding
  version.
- The vector backend has a current benchmark under
  `scripts/ci/project-code-memory-vector-benchmark.py`.

Search responses must return `semanticAvailable`, `embeddingProvider`,
`embeddingModel`, `embeddingVersion`, and `semanticFallbackReason`. Until the
gate is satisfied, ranking stays sparse/lexical and the fallback reason explains
why dense retrieval is off.

Optional reranking is not enabled in production yet. The retrieval eval and
benchmark harnesses are the review gate: a reranker can land only if it improves
the eval set without breaching the latency budget recorded by the benchmark.

## Consequences

- Deterministic vectors remain allowed only as content fingerprints and test
  fixtures.
- Product copy cannot claim semantic code search while `semanticAvailable` is
  false.
- The current benchmark result is sparse-only by design; this is a valid
  readiness state, not a hidden semantic implementation.
