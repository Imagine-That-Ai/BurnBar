# BurnBar HPKE v3 Test Agent Prompt

Goal: Build the focused test coverage that proves HPKE v3 behavior and catches
downgrade, forgery, schema, and replay regressions.

Claude launch: run this workstream through Claude from the tmux `tests` window
with the literal keyword `ultracode` in the prompt.

Success means:

- Add or harden tests for v3 round trip, wrong sender, wrong recipient, wrong
  AAD, mutated `enc`, mutated `wrappedKey`, stripped version, and downgrade.
- Add adapter tests for v3 send/open, v2 compatibility, v1 refusal, plaintext
  refusal, replay counter enforcement, and routing ID binding.
- Add fixture tests that verify current-schema Swift vectors.
- Keep test edits coordinated with implementation workers to avoid duplicate
  assertions or conflicting fixture shape.

Stop when:

- The targeted gateway and vector tests pass or fail with actionable
  implementation defects.

Constraints:

- Own tests and fixtures only unless the orchestrator assigns a code fix.
- Use production-shaped inputs.
- Prefer real crypto helpers over mocks.
- Keep each failure message specific enough for the implementation worker.

## Expected Commands

Run the Hermes suite:

```bash
cd /Users/albertonunez/.hermes/hermes-agent
venv/bin/python -m pytest \
  tests/gateway/test_relay_e2ee.py \
  tests/gateway/test_relay_e2ee_v2.py \
  tests/gateway/test_relay_e2ee_v3.py \
  tests/gateway/test_burnbar_plugin.py \
  tests/gateway/test_burnbar_hpke_v3_vectors.py \
  -q
```

Run the BurnBar Swift vector suite:

```bash
cd /Users/albertonunez/Documents/Windsurf/BurnBar/OpenBurnBarCore
swift test --filter HermesRelayCrossPlatformVectorTests
```

## Handoff Output

Return:

```text
Tests added:
Fixtures changed:
Commands run:
Failures found:
Implementation fixes requested:
Residual gaps:
```

