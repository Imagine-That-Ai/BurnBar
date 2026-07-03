# Parser contract corpus

Portable, language-neutral parser fixtures + the Mac parser-output golden for the
Windows-port parity contract (`VAL-P0-HARNESS-023` / `VAL-P0-HARNESS-024`).

**Full spec:** [`docs/windows-port/PARSER_OUTPUT_CONTRACT.md`](../../../docs/windows-port/PARSER_OUTPUT_CONTRACT.md)

## Contents

- `pc-*.jsonl` / `pc-*.json` — the 15 extracted parser fixtures (one per
  `ParserTestFixtures` builder), across Claude Code, Factory Droid, Codex, Hermes.
  These are the exact bytes a provider writes to disk; every timestamp is frozen.
- `parser-output-golden.json` — the Mac golden: the parser-output contract
  projection produced by the real production parsers over this corpus.
- `MANIFEST.json` — the language-neutral index: for each fixture, its provider,
  target parser, file(s), and the directory layout the parser expects.

## Do not hand-edit

Both the fixtures and the golden are **generated from
`ParserTestFixtures`** and validated by
`AgentLensTests/Active/Parsers/ParserFixtureExtractionParityTests.swift` (byte-identical
extraction + old-inline-vs-new-file parser output) and
`ParserOutputContractGoldenTests.swift` (deterministic golden + committed match).
Regenerate via the workflow in the spec; do not edit these files by hand.

## Windows port

A Windows parser reads these files (per `MANIFEST.json`), produces the same
contract records with the same nano-USD cost rule + canonical serialization, and
diffs byte-for-byte against `parser-output-golden.json`. That diff is Phase-2.
