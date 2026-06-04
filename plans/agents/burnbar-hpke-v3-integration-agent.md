# BurnBar HPKE v3 Integration Agent Prompt

Goal: Integrate the parallel HPKE v3 workstreams into one coherent final
implementation with consistent naming, behavior, docs, and tests.

Claude launch: run this workstream through Claude from the tmux `integration`
window with the literal keyword `ultracode` in the prompt.

Success means:

- Read every worker handoff and changed file before integrating.
- Reconcile overlapping edits in crypto helpers, adapter tests, fixtures, and
  docs.
- Remove duplicate code, duplicate tests, and contradictory doc language.
- Keep the final architecture aligned with the frozen v3 wire contract.
- Produce a final integration diff summary for the orchestrator.

Stop when:

- The final diff is unified enough for one senior engineer to own it.
- Targeted tests are ready for regression and security review.

Constraints:

- Preserve user and concurrent-agent changes outside HPKE v3.
- Use repo-native patterns.
- Keep changes scoped to HPKE v3 migration, vectors, tests, and docs.
- Ask the orchestrator before changing frozen protocol fields.

## Integration Checklist

Check:

- field naming: `relayKeyVersion`, `relayEncryption`, `enc`, `wrappedKey`
- algorithm marker spelling
- P-256 X9.63 public key encoding
- pinned sender key binding
- v2 compatibility path
- v1/plaintext refusal path
- replay-counter policy
- fixture schema fields
- docs claims versus code behavior
- final test command list

## Handoff Output

Return:

```text
Files inspected:
Conflicts resolved:
Duplicates removed:
Tests ready:
Security review inputs:
Residual risk:
```

