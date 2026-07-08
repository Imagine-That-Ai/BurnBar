# Retrieval Golden / Live Replay Oracle Accepted

Fresh live replay oracle from `/private/tmp/openburnbar-linux-mission-001`:

- `docs/linux-port/fixtures/project-memory-retrieval-golden-source-oracle.json` provides the expected remember/index/watch/search/recall/audit/analytics/privacy contract.
- `scripts/linux-port/run-provider-hermes-canonical-oracles.mjs` builds observed retrieval output from `cli-hermes-transcript.txt` plus `packaged-browser-memory-dom-transcript.json`; fixture expected rows are not reused as observed rows.
- Required evidence files: `retrieval-golden-source-oracle-macos.json`, `retrieval-golden-diff-macos.json`, `retrieval-golden-source-oracle-linux.json`, and `retrieval-golden-diff-linux.json`.
- Existing `AgentLensTests/Fixtures/ReplayGoldens` remain supporting app SearchService replay-golden coverage.

Acceptance:

- `VAL-HERMES-002` is canonical when both retrieval golden diffs are `exact_match`, the observed source names the live CLI/browser artifacts, and live daemon/CLI/browser memory evidence is complete.
