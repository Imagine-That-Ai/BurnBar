# Branch Protection As Code (`main`)

[`branch-protection.main.json`](branch-protection.main.json) is the source of truth for the
protection that `main` must carry. It exists so governance is reproducible from the repo instead of
living only in the GitHub UI or in a hardcoded verifier constant.

If live protection and this file disagree, this file wins and live state must be repaired.

Related: [`docs/GOVERNANCE.md`](../docs/GOVERNANCE.md),
[`scripts/ops/verify-github-governance.sh`](../scripts/ops/verify-github-governance.sh), and
[`.github/CODEOWNERS`](../.github/CODEOWNERS).

## Current Contract

BurnBar is intentionally solo-maintainer automation friendly. The hard merge gates are:

- required status checks;
- required conversation resolution;
- no force pushes;
- no branch deletion;
- exact-head merge discipline in the automation lane.

The following must not be reintroduced as permanent blockers for the daily maintainer lane unless the
owner intentionally changes the contract again:

- strict up-to-date status checks (`required_status_checks.strict`);
- required approving reviews;
- required CODEOWNER reviews;
- required last-push approval;
- stale-review dismissal as a merge blocker.

That is why the current desired file has `required_status_checks.strict: false` and a
`required_pull_request_reviews` object whose count/booleans are all non-blocking. Keeping the review
object present makes drift explicit without making self-approval a required gate.

## Live Surface

The drift checker reads both GitHub surfaces:

- effective branch rules from `GET /repos/{owner}/{repo}/rules/branches/main`, plus the referenced
  org/repo ruleset details for `bypass_actors` and `enforcement`;
- classic branch protection from `GET /repos/{owner}/{repo}/branches/main/protection`.

Current live protection is classic branch protection with no effective ruleset rules. If an org or
repo ruleset is later added, the checker verifies ruleset-owned governance fields on the ruleset
surface itself instead of letting classic protection hide a downgraded ruleset.

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

## Drift Check

The scheduled/dispatch ops verification lane runs
[`scripts/ops/check-branch-protection-drift.mjs`](../scripts/ops/check-branch-protection-drift.mjs).
The PR lane runs the same drift logic's offline self-tests through the required Fast Feedback
aggregate gate, so edits to the checker are merge-blocking even though live GitHub/GCP credentials are
not exposed to PRs.

The drift check fails closed on:

- required-check set differences in either direction;
- strict status checks being enabled when this file says false, or disabled if this file is changed
  back to true;
- required review/CODEOWNER/last-push/stale-review settings differing from this file;
- conversation resolution disabled;
- admin enforcement disabled;
- force pushes or branch deletion enabled;
- any classic bypass allowance or ruleset `bypass_actors` entry;
- unreadable or unparseable referenced ruleset details.

## Consumers

`scripts/commercial-launch-gate.mjs` and `scripts/ops/verify-github-governance.sh` must consume
`required_status_checks.contexts` from this file. They must not carry a separate hand-maintained list.

The ops workflow boundary is enforced by
[`scripts/ci/verify-ops-plane-workflow-boundary.mjs`](../scripts/ci/verify-ops-plane-workflow-boundary.mjs):
PRs may run only creds-free self-tests, while live production drift checks stay on scheduled or manual
ops runs with protected credentials.
