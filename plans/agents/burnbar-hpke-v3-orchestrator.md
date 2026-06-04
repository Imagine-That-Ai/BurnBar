# BurnBar HPKE v3 Orchestrator Prompt

Goal: Coordinate the HPKE v3 migration from a tmux session by dispatching every
implementation workstream through Claude with the `ultracode` keyword and by
integrating only verified, reviewable changes.

Success means:

- Create and manage one tmux session named `burnbar-hpke-v3`.
- Launch each implementation workstream in its own tmux window through Claude.
- Include the literal word `ultracode` in every Claude task prompt.
- Assign recon, architecture, Python, Swift, Kotlin, vector, tests, docs,
  integration, regression, security-review, and release work from the plan files
  in `plans/agents/`.
- Collect evidence from each Claude worker: files changed, tests run, command
  output summary, blockers, and residual risk.
- Integrate completed work in dependency order.
- Run final Hermes gateway and vector tests from the orchestrator window.
- Keep unrelated dirty-tree changes out of the final staged set.

Stop when:

- Every workstream has reported completion or a concrete blocker.
- Final tests pass from the orchestrator window.
- The final diff is scoped, reviewable, and ready for security review or commit.

Constraints:

- Use Claude for workstream execution.
- Use Codex as the orchestrator that reads worker outputs, resolves conflicts,
  and verifies the final state.
- Preserve existing user or concurrent-agent changes unless they are explicitly
  part of the HPKE v3 migration.
- Keep all branch actions auditable with `git status`, `git diff --stat`, and
  targeted test output.

## Session Setup

Run from the BurnBar checkout:

```bash
cd /Users/albertonunez/Documents/Windsurf/BurnBar
tmux new-session -d -s burnbar-hpke-v3 -n orchestrator
tmux new-window -t burnbar-hpke-v3 -n python
tmux new-window -t burnbar-hpke-v3 -n swift
tmux new-window -t burnbar-hpke-v3 -n kotlin
tmux new-window -t burnbar-hpke-v3 -n vectors
tmux new-window -t burnbar-hpke-v3 -n recon
tmux new-window -t burnbar-hpke-v3 -n architecture
tmux new-window -t burnbar-hpke-v3 -n tests
tmux new-window -t burnbar-hpke-v3 -n docs
tmux new-window -t burnbar-hpke-v3 -n integration
tmux new-window -t burnbar-hpke-v3 -n regression
tmux new-window -t burnbar-hpke-v3 -n security
tmux new-window -t burnbar-hpke-v3 -n release
tmux attach -t burnbar-hpke-v3
```

## Claude Launch Commands

Recon:

```bash
claude "ultracode: read plans/agents/burnbar-hpke-v3-recon-agent.md and execute exactly that workstream. Report file map, ownership boundaries, current tests, blockers, and speed recommendations."
```

Architecture:

```bash
claude "ultracode: read plans/agents/burnbar-hpke-v3-architecture-agent.md and execute exactly that workstream. Report frozen protocol decisions, compatibility policy, conflict risks, blockers, and residual risk."
```

Python:

```bash
claude "ultracode: read plans/agents/burnbar-hpke-v3-python-agent.md and implement exactly that workstream. Report files changed, tests run, command results, blockers, and residual risk."
```

Swift:

```bash
claude "ultracode: read plans/agents/burnbar-hpke-v3-swift-agent.md and implement exactly that workstream. Report files changed, tests run, fixture path, generator command, blockers, and residual risk."
```

Kotlin:

```bash
claude "ultracode: read plans/agents/burnbar-hpke-v3-kotlin-agent.md and implement exactly that workstream. Report Android participation decision, files changed, tests run, vector status, blockers, and residual risk."
```

Vectors:

```bash
claude "ultracode: read plans/agents/burnbar-hpke-v3-vector-agent.md and implement exactly that workstream. Report fixture path, verifier path, generator command, tests run, blockers, and residual risk."
```

Tests:

```bash
claude "ultracode: read plans/agents/burnbar-hpke-v3-test-agent.md and implement exactly that workstream. Report tests added or updated, commands run, failures found, blockers, and residual risk."
```

Docs:

```bash
claude "ultracode: read plans/agents/burnbar-hpke-v3-docs-agent.md and implement exactly that workstream after implementation shape is visible. Report docs changed, claims updated, commands run, blockers, and residual risk."
```

Integration:

```bash
claude "ultracode: read plans/agents/burnbar-hpke-v3-integration-agent.md and execute exactly that workstream after core workers report. Report overlaps reconciled, files inspected, tests run, blockers, and residual risk."
```

Regression:

```bash
claude "ultracode: read plans/agents/burnbar-hpke-v3-regression-agent.md and execute exactly that workstream after integration. Report regression matrix, commands run, pass/fail status, blockers, and residual risk."
```

Security review:

```bash
claude "ultracode: read plans/agents/burnbar-hpke-v3-security-review-agent.md and run the review after implementation lands. Report severity-ranked findings, claim verdicts, tests run, and final submit/hold verdict."
```

Release:

```bash
claude "ultracode: read plans/agents/burnbar-hpke-v3-release-agent.md and prepare the upstream PR packaging after implementation and security review. Report PR body, docs touched, test evidence, blockers, and residual risk."
```

## Orchestrator Loop

1. Start the tmux session and launch recon and architecture first.
2. Launch Python, Swift, Kotlin, vectors, and tests once the architecture guard
   has frozen the wire contract.
3. Poll worker panes for completion summaries.
4. Read each changed file before integrating it with other workstreams.
5. Resolve conflicts in favor of the frozen v3 wire contract in the master plan.
6. Launch docs after implementation shape is visible.
7. Launch integration after core workers report.
8. Run the targeted Hermes gateway tests after Python and vectors finish.
9. Launch regression after integration passes.
10. Launch the security-review worker after implementation and regression tests
    pass.
11. Launch the release worker after security review reports no blocking P1.
12. Inspect `git status --short --branch` and `git diff --stat` before staging.
13. Stage only HPKE v3 migration files and related docs/tests.
14. Commit only after final tests and staged-set review pass.

## Final Evidence

Return this summary:

```text
tmux session: burnbar-hpke-v3
Claude keyword: ultracode
workers completed:
tests run:
files changed:
security verdict:
release readiness:
single biggest residual risk:
```
