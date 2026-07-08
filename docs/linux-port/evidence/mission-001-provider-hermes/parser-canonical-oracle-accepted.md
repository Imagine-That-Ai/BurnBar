# Parser Corpus / Product Replay Oracle Accepted

Fresh product replay oracle from `/private/tmp/openburnbar-linux-mission-001`:

- `docs/linux-port/fixtures/provider-parser-canonical-oracle.json` provides expected rows and independent `corpusInput` payloads; expected rows are never copied into observed rows.
- `scripts/linux-port/run-provider-hermes-canonical-oracles.mjs` parses `corpusInput` through `OpenBurnBarCanonicalProviderCorpusParser.parseFixture`, ingests rows through `OpenBurnBarLocalDatabase.ingestProviderParserBatch`, then reads observed usage rows from `OpenBurnBarLocalDatabase.canonicalProviderUsageRows`.
- Required evidence files: `provider-parser-product-replay-macos.json`, `canonical-provider-parser-oracle-macos.json`, `provider-parser-corpus-diff-macos.json`, `usage-row-reconciliation-diff-macos.json`, `provider-parser-product-replay-linux.json`, `canonical-provider-parser-oracle-linux.json`, `provider-parser-corpus-diff-linux.json`, and `usage-row-reconciliation-diff-linux.json`.

Acceptance:

- `VAL-PROVIDER-002` is canonical when both platform parser corpus diffs are `exact_match` and name `OpenBurnBarCanonicalProviderCorpusParser.parseFixture` as the observed source.
- `VAL-DATA-004` is canonical when both platform usage-row reconciliation diffs are `exact_match`, name the product DB read surface as the observed source, and the Linux DB ingestion transcript also passes.
- `docs/linux-port/fixtures/provider-parser-replacement-oracle.json` remains candidate/replacement evidence only and is not used as the canonical source.
