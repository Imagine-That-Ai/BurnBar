# BurnBar HPKE v3 Recon Agent Prompt

Goal: Map the current Hermes gateway relay crypto, BurnBar Swift vector, Android
fixture, and documentation seams so implementation agents start with exact file
ownership and current behavior.

Claude launch: run this workstream through Claude from the tmux `recon` window
with the literal keyword `ultracode` in the prompt.

Success means:

- Identify the active Python Hermes checkout and the active BurnBar checkout.
- List the exact files that own relay key wrapping, gateway adapter open/send,
  Swift fixture generation or verification, Android fixture consumption, and
  security docs.
- Record the tests that currently pass for strict-schema v2 vectors.
- Identify files each downstream agent should own.
- Identify files that require serial coordination because concurrent edits would
  create conflicts.

Stop when:

- The orchestrator has a file map, ownership map, command map, and conflict-risk
  list.

Constraints:

- Keep this stream read-only.
- Use repository evidence from code, tests, and committed fixtures.
- Return concise paths and commands.

## Recon Targets

Inspect:

- `/Users/albertonunez/.hermes/hermes-agent/gateway/crypto/relay_e2ee.py`
- `/Users/albertonunez/.hermes/hermes-agent/plugins/platforms/burnbar/adapter.py`
- `/Users/albertonunez/.hermes/hermes-agent/tests/gateway/`
- `OpenBurnBarCore/Sources/**/HermesRelayCrypto*.swift`
- `OpenBurnBarCore/Tests/**/HermesRelayCrossPlatformVectorTests.swift`
- `OpenBurnBarCore/Tests/**/Fixtures/HermesGatewayWireVector.json`
- `android/**/HermesGatewayWireVector.json`
- relevant BurnBar and Hermes security docs

## Handoff Output

Return:

```text
Active repos:
Core files:
Test files:
Fixture files:
Docs:
Parallel-safe ownership:
Serial coordination files:
Known passing commands:
Fastest next steps:
```

