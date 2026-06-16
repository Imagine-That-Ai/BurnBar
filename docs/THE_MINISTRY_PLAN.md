# The Ministry Plan

This file is kept as a historical pointer. The implementation plan has been
executed; the current operator documentation lives in `docs/THE_MINISTRY.md`.

## Current Status

The Ministry is implemented in `tools/openburnbar-mcp/ministry.py` and exposed
through `ministry_*` tools in `tools/openburnbar-mcp/server.py`.

The audit closure marks the plan as built and verified by proving:

- authenticated local gateway quota read: 24 model rows
- focused Ministry tests: 12 passed
- full local MCP Python tests: 59 passed
- Python compile check for `ministry.py` and `server.py`
- N=2 proven-headless selector run with provider diversity:
  - `custom:OpenBurnBar-glm-5.2-40` via Z.ai, landed commit in a disposable probe
  - `gpt-5.4-mini` via OpenAI, landed commit in a disposable probe
- no remaining `ministry/*` branches, no `bb-ministry` worktrees, and no
  `bb-ministry-probe-*` temp directories after verification

## Canonical Runbook

Use `docs/THE_MINISTRY.md` for:

- tool surface
- wand store semantics
- selection and proof behavior
- command contract
- fan-out runbook
- verification commands

This file should not be used as an execution checklist.
