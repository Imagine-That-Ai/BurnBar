# Branch Protection As Code (`main`)

[`branch-protection.main.json`](branch-protection.main.json) is the source of truth for the
protection that `main` must carry. It exists so governance is reproducible from the repo instead of
living only in the GitHub UI or in a hardcoded verifier constant.

If live protection and this file disagree, this file wins and live state must be repaired.

Related: [`docs/GOVERNANCE.md`](../docs/GOVERNANCE.md),
[`scripts/ops/verify-github-governance.sh`](../scripts/ops/verify-github-governance.sh), and
[`.github/CODEOWNERS`](../.github/CODEOWNERS).

## Current Contract

BurnBar's hard merge gates are:

- required status checks, including the trusted Domain Core aggregate gates;
- strict current-base checks;
- one independent approving review;
- CODEOWNER review for protected paths;
- dismissal of stale approvals after a new push;
- approval from someone other than the actor who made the latest push;
- required conversation resolution;
- no force pushes;
- no branch deletion;
- a squash-only, all-green merge queue whose 300-minute response timeout
  outlives the longest required workflow;
- exact-head merge discipline in the automation lane.

**Security-governance decision (2026-07-24):** the stale-base and scanner
findings retire the former solo-maintainer review exception.
`required_status_checks.strict` is `true`, one approving review and CODEOWNER
review are required, approvals are dismissed when the head changes, and the
latest pusher cannot approve their own update. The repository has two named
CODEOWNERS, so this closes both the protected-file two-PR bypass and the
post-approval push bypass.

Strict current-base checks and the merge queue now work together. Every required
workflow supports `merge_group`, and the queue's response timeout is governed
here so a valid cold macOS build cannot be ejected merely because the queue
stopped waiting first. `Domain Core Trusted Deletion Guard` runs on every PR and
is globally required. `Domain Core PR Gate` remains path-scoped evidence for
domain-core changes; promoting it as a classic global context would leave every
unrelated PR permanently pending.

The drift checker verifies this complete contract. Apply the same values to live
classic branch protection in the same change, then
`scripts/ops/check-branch-protection-drift.mjs` must report an exact match.

## Live Surface

The drift checker reads both GitHub surfaces:

- effective branch rules from `GET /repos/{owner}/{repo}/rules/branches/main`, plus the referenced
  org/repo ruleset details for `bypass_actors` and `enforcement`;
- classic branch protection from `GET /repos/{owner}/{repo}/branches/main/protection`.

Current live protection combines classic branch protection with a repository
merge-queue ruleset. The checker verifies both surfaces, including every
merge-queue parameter, instead of letting classic protection hide a missing or
shortened queue timeout.

The checker fails closed when referenced ruleset details cannot be read. An unread ruleset means the
automation did not verify bypass actors or enforcement.

## Required Status Checks

`required_status_checks.contexts` contains the exact check-run names currently required by GitHub for
PRs into `main`. These names were read from live branch protection on 2026-07-08 after the
solo-maintainer `strict: false` decision.

Keep the JSON and live GitHub protection in sync:

- When adding, renaming, or removing a required check, update
  `branch-protection.main.json` and live branch protection in the same change.
- Do not promote placeholder checks into `required_status_checks.contexts` until a workflow emits the
  exact context on PRs. A required context that never reports leaves every PR pending forever.
- Prefer stable aggregate gates (`Fast Feedback Gate`, `PR Native Gate`, etc.) for path-conditional
  workflows so unrelated PRs do not hang on missing checks.

`_pending_required_status_checks` remains the place for declared future gates that are not emitted
yet.

### The `diff-coverage (PR)` Pending Gate

`_pending_required_status_checks` holds `diff-coverage (PR)` — the re-armed diff-coverage gate.

As of 2026-07-08 an emitting workflow exists. The `diff-coverage-ts` job in
[`fast-feedback.yml`](../.github/workflows/fast-feedback.yml) reports the `diff-coverage (PR)`
check-run on every `pull_request`. It computes real per-line coverage for the changed TypeScript
surface (functions + extension) from the v8/istanbul `coverage-final.json` and intersects it with the
added runtime lines of `git diff origin/main HEAD`, failing below 80%
([`scripts/diff-coverage-ts.sh`](../scripts/diff-coverage-ts.sh)). It has no presence-based fallback:
the script fails closed with `method: istanbul_evidence_missing` when a changed runtime file has no
per-line coverage evidence. When no functions/extension TypeScript changed, the job reports a fast
pass, so the context still resolves on every PR at near-zero cost.

The context stays in `_pending_required_status_checks`, not yet in
`required_status_checks.contexts`, on purpose: making it required is an operator-only
branch-protection change, and it should be flipped only after the context is observed reporting green
on a real PR. Activation: move `diff-coverage (PR)` from `_pending_required_status_checks` into
`required_status_checks.contexts` in this file and add it to live branch protection in the same
change.

This gate covers the TypeScript surface only. Swift/native diff coverage
([`scripts/diff-coverage.sh`](../scripts/diff-coverage.sh)) still runs post-merge/nightly inside
[`openburnbar-pr-harness.yml`](../.github/workflows/openburnbar-pr-harness.yml), which is not a
`pull_request` gate.

### The `Domain Core Trusted Deletion Guard` Required Gate

This context is globally required after the legacy-deletion ledger landed and
the trusted `pull_request_target` workflow proved it resolves on every pull
request. For an exact-head deletion approval, rerun the trusted check manually
after approval; do not add a candidate-controlled `pull_request_review`
trigger.

## Drift Check

The scheduled/dispatch ops verification lane runs
[`scripts/ops/check-branch-protection-drift.mjs`](../scripts/ops/check-branch-protection-drift.mjs).
The PR lane runs the same drift logic's offline self-tests through the required Fast Feedback
aggregate gate, so edits to the checker are merge-blocking even though live GitHub/GCP credentials are
not exposed to PRs.

Workflow lint also runs
[`scripts/ci/verify-merge-queue-workflows.mjs`](../scripts/ci/verify-merge-queue-workflows.mjs),
which fails if the committed queue response timeout does not exceed the longest
job timeout in any workflow that handles `merge_group`.

The drift check fails closed on:

- required-check set differences in either direction;
- strict status checks differing from this file (currently `true`; any live
  mismatch — strict disabled when the file says true, or enabled when it says
  false — is drift);
- required review/CODEOWNER/last-push/stale-review settings differing from this file;
- conversation resolution disabled;
- admin enforcement disabled;
- force pushes or branch deletion enabled;
- a missing merge queue or any merge-queue parameter differing from the
  committed contract;
- any classic bypass allowance or ruleset `bypass_actors` entry;
- unreadable or unparseable referenced ruleset details.

## Consumers

`scripts/commercial-launch-gate.mjs` and `scripts/ops/verify-github-governance.sh` must consume
`required_status_checks.contexts` from this file. They must not carry a separate hand-maintained list.

The ops workflow boundary is enforced by
[`scripts/ci/verify-ops-plane-workflow-boundary.mjs`](../scripts/ci/verify-ops-plane-workflow-boundary.mjs):
PRs may run only creds-free self-tests, while live production drift checks stay on scheduled or manual
ops runs with protected credentials.
