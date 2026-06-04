# BurnBar HPKE v3 Regression QA Agent Prompt

Goal: Run the final regression matrix for the HPKE v3 migration across Hermes
Python and BurnBar Swift/Android fixture surfaces.

Claude launch: run this workstream through Claude from the tmux `regression`
window with the literal keyword `ultracode` in the prompt.

Success means:

- Run the targeted Hermes gateway crypto and adapter tests.
- Run the BurnBar Swift vector tests.
- Run the Android fixture/vector test target if Android participates.
- Verify docs and fixtures are included in the intended diff.
- Return a concise pass/fail matrix with exact commands.

Stop when:

- Every required command has passed or every failure has an owner and a
  reproducible command.

Constraints:

- Keep this stream primarily test-only.
- Report failures with the first actionable error and the affected owner.
- Avoid broad full-CI runs unless the targeted matrix is green and time permits.

## Regression Matrix

Hermes:

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

Swift:

```bash
cd /Users/albertonunez/Documents/Windsurf/BurnBar/OpenBurnBarCore
swift test --filter HermesRelayCrossPlatformVectorTests
```

Android:

```bash
cd /Users/albertonunez/Documents/Windsurf/BurnBar/android
./gradlew :app:testDebugUnitTest --tests '*Hermes*' --no-daemon
```

Diff hygiene:

```bash
cd /Users/albertonunez/Documents/Windsurf/BurnBar
git status --short --branch
git diff --stat
```

## Handoff Output

Return:

```text
Hermes tests:
Swift tests:
Android tests:
Diff hygiene:
Failures:
Owners:
Residual risk:
```

