# BurnBar HPKE v3 Orchestrator Prompt

Goal: Coordinate the HPKE v3 migration from a tmux session by dispatching every
implementation workstream through Claude with the `ultracode` keyword and by
integrating only verified, reviewable changes.

Success means:

- Create and manage one tmux session named `burnbar-hpke-v3`.
- Launch each implementation workstream in its own tmux window through Claude.
- Include the literal word `ultracode` in every Claude task prompt.
- Assign Python, Swift, Kotlin, vector, security-review, and release work from
  the plan files in `plans/agents/`.
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
tmux new-window -t burnbar-hpke-v3 -n security
tmux new-window -t burnbar-hpke-v3 -n release
tmux attach -t burnbar-hpke-v3
```

## Claude Launch Commands

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

Security review:

```bash
claude "ultracode: read plans/agents/burnbar-hpke-v3-security-review-agent.md and run the review after implementation lands. Report severity-ranked findings, claim verdicts, tests run, and final submit/hold verdict."
```

Release:

```bash
claude "ultracode: read plans/agents/burnbar-hpke-v3-release-agent.md and prepare the upstream PR packaging after implementation and security review. Report PR body, docs touched, test evidence, blockers, and residual risk."
```

## Orchestrator Loop

1. Start the tmux session and launch Python, Swift, Kotlin, and vector workers.
2. Poll worker panes for completion summaries.
3. Read each changed file before integrating it with other workstreams.
4. Resolve conflicts in favor of the frozen v3 wire contract in the master plan.
5. Run the targeted Hermes gateway tests after Python and vectors finish.
6. Launch the security-review worker after implementation tests pass.
7. Launch the release worker after security review reports no blocking P1.
8. Inspect `git status --short --branch` and `git diff --stat` before staging.
9. Stage only HPKE v3 migration files and related docs/tests.
10. Commit only after final tests and staged-set review pass.

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

