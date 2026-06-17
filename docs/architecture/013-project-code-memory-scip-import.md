# ADR 013: Project Code Memory SCIP Import

## Status

Accepted, 2026-06-17.

## Context

SCIP is a language-agnostic code intelligence protocol for source indexes. The
Project Code Memory confidence ladder reserves `scip_index` for offline precise
definition/reference data that is current for the indexed artifact. This tier
must sit below live exact-LSP responses but above tree-sitter syntax ranges and
lexical fallback.

## Decision

The first importer is a JSON SCIP importer for TypeScript/JavaScript fixture and
tooling output. It accepts a SCIP-shaped JSON document with `documents`,
`relativePath`, `symbols`, and `occurrences`; definition occurrences populate
`code_symbols`, and non-definition occurrences populate `code_references` when
their target definition exists in the imported index.

The importer does not parse binary `.scip` protobuf files directly. Binary SCIP
files must be converted by the SCIP CLI or ecosystem indexer before import. This
keeps the local MCP helper dependency-free and makes golden fixtures readable.

## Rules

- Import is project-scoped and only enriches artifacts already present in
  `code_artifacts`.
- Imported rows use `confidence_tier='scip_index'`.
- Tier evidence records parser `scip`, ecosystem, source index filename, blob
  SHA, and the raw SCIP symbol.
- `get_symbol` prefers `exact_lsp`, then `scip_index`, then
  `static_tree_sitter`, then lexical fallback.

## Consequences

- TypeScript/JavaScript can opt into precise offline symbols/references without
  requiring live LSP.
- Other ecosystems require their own import adapters or JSON fixture coverage
  before claiming `scip_index` support.
- The daemon remains free to add a binary protobuf importer later if the
  dependency and migration cost are justified.
