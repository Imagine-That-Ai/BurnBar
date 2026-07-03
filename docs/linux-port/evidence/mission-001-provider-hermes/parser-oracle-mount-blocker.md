# Parser Corpus / macOS Oracle Blocker

Fresh check from `/private/tmp/openburnbar-linux-mission-001` on 2026-07-03:

- `find /private/tmp/openburnbar-linux-mission-001 ... '*parser*corpus*' '*provider*corpus*' '*provider*oracle*' '*parser*oracle*' '*usage*golden*'` returned no files outside pruned build, node_modules, and target directories.
- `docs/linux-port/fixtures/` only contains `burnbarrpc-canon-missing-subscription.fixture.json`.
- `docs/linux-port/evidence/mission-001-provider-hermes/` contains provider path fixtures and daemon transcripts, but no mounted macOS parser oracle, provider corpus runner, usage-row golden, or reconciliation diff input.

Impact:

- `VAL-PROVIDER-002` cannot be honestly passed because parser output parity requires the accepted provider corpus plus macOS oracle/golden diffs.
- `VAL-DATA-004` cannot be honestly passed because DB row parity requires parser-corpus outputs and a macOS oracle row diff for provenance, cost, confidence, account, timestamps, parent request, and reconciliation fields.

