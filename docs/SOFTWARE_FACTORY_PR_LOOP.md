# BurnBar Software Factory PR Loop

BurnBar uses a software-factory PR loop to reduce CI/review babysitting while keeping `main` protected.

This is the operating model:

- Implementation agents produce coherent, validated PRs.
- Cursor/Bugbot/Cloud Agent may implement scoped fixes.
- Codex is the independent reviewer and approval gate.
- GitHub CI and branch protection are the mechanical merge gate.
- Selected PRs should end as `MERGED`, `CLOSED`, or `OPEN_WITH_NAMED_BLOCKER`.

The always-on machine owns the recurring automation and authenticated GitHub CLI setup. Other BurnBar machines should pull these repo instructions; they only need `gh` installed and authenticated if they will perform GitHub lifecycle actions themselves.

Cross-agent visibility rule:

- When Codex, Cursor/Bugbot, or Cursor Cloud Agent reacts to another agent's feedback, the PR should include a `Cross-agent receipt`.
- Keep it short: saw, reaction, status, next owner.
- Include review/comment/thread ids and commit SHAs when available.
- This is the human management surface; do not hide team handoff state only in automation logs.

Privileged repair-loop authority model:

- Secrets-bearing `workflow_run` repair loops must authenticate provenance before checkout, agent invocation, PR comments, pushes, or cloud-agent handoff.
- The authority signal is the base repository's trusted repair branch, not public PR title/body text. The markers `codex-nightly-ci-repair` and `cursor-nightly-ci-repair` are display-only.
- `workflow_run.pull_requests` is correlation-only. A continuation must also bind the GitHub-authoritative head repository, repair branch, bot author, non-fork head, base branch, and exact head SHA.
- The provenance classifier runs read-only and emits sanitized scalar outputs. Privileged jobs run only after `safe=true`, then re-fetch the trusted base-repo repair branch and re-check the validated SHA before giving code to an agent.

## Agent Prompt

Paste this into a BurnBar agent when you need it to remember the factory model permanently:

```text
Remember this permanently for BurnBar.

BurnBar uses a software-factory PR loop. The goal is velocity with safety.

Do not force tiny PRs. Do not make vague mega-PRs.

Ship the smallest reviewable coherent unit.

Use the right lane:

1. Fast lane
Mechanical, dependency, lint, docs, small bug, or narrow feature work.
Run cheap relevant checks, open a clear PR, request/label factory review, then move on.

2. Structured large lane
Use this when the change is genuinely atomic and splitting it would make review or validation worse.
Large PRs are allowed, but the PR body must include:
- review map
- major areas touched
- invariants preserved
- validation matrix
- known risks
- rollback or containment notes

3. Spike lane
Exploratory or uncertain work.
Open as draft. Say what is being learned. List exit criteria. Do not ask the factory to merge it.

4. Reject lane
Known-broken, vague, mixed-goal, or mystery work.
Do not hand this to the factory as a normal PR. Keep working, split it, or mark it draft with a named blocker.

Normal agent flow:
- finish the coherent unit
- run cheap local checks
- commit
- push
- open PR
- explain change, reason, validation, risks
- request/label factory review
- move on unless Alberto explicitly asks you to watch CI

The factory handles:
- Codex review
- Cursor/Bugbot scoped fixes
- CI waiting
- re-review
- merge
- close
- named blockers

Every selected PR should end as:
- MERGED
- CLOSED
- OPEN_WITH_NAMED_BLOCKER

Cursor/Bugbot/Cloud Agent can fix.
Codex approves.
GitHub branch protection decides mergeability.

When agents react to each other, leave a Cross-agent receipt in the PR:
- saw
- reaction
- status
- next owner

Do not use the factory to launder sloppy work into main.
Good attempts go in. Finished outcomes come out.
```

## Local Machine Notes

On the always-on automation machine:

```bash
command -v gh
gh auth status
```

`gh` should be installed, authenticated, and available in login shells. The recurring Codex automation should run from the BurnBar workspace and may use `/opt/homebrew/bin/gh` as a fallback for PR lifecycle hygiene.
