# ADR 010: Project Code Static Parser Boundary

## Context

Project Code Memory needs a beyond-parity `static_tree_sitter` tier for symbol and definition extraction without moving code plaintext into hosted services or giving parser code authority over persistence. The parser sees source text, so its boundary must be smaller than the daemon boundary.

## Decision

OpenBurnBar uses `crates/project-code-static-parser` as a stateless Rust executable. It reads newline-delimited JSON from stdin and writes newline-delimited JSON to stdout. The helper has no database access, no network access, no auth tokens, and no write path. It supports the initial Phase 4 language set: Swift, TypeScript/TSX, and Python.

The daemon owns all persistence, project partitioning, secret scanning, audit, storage caps, and query-time staleness checks. Helper output is accepted only when the returned blob SHA matches the file blob being indexed. Accepted symbols carry `confidence_tier = static_tree_sitter` plus structured tier evidence. If the helper is unavailable, unsupported, errors, or returns a mismatched blob, the daemon degrades to `lexical_fallback`.

## Consequences

- Static parsing can improve symbol tiers without introducing a new trusted storage process.
- Hosted code sync remains off by default; this helper is local-only and does not weaken the hosted threat model.
- The helper can be tested and shipped independently from the daemon.
- Exact LSP tiers remain a later opt-in path and must only be emitted when a live language server answers for the current buffer within timeout.
