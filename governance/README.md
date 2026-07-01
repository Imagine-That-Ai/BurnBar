# Branch protection as code (`main`)

[`branch-protection.main.json`](branch-protection.main.json) is the **source of truth** for the
protection that `main` MUST carry. It exists so governance is reproducible from the repo instead of
living only in the GitHub UI (where it can be silently edited) or as a hardcoded constant inside a
verification script (where it drifts from the workflows it claims to gate).

If the live protection and this file disagree, **this file wins** and the live state is the bug.

Related: [`docs/GOVERNANCE.md`](../docs/GOVERNANCE.md),
[`scripts/ops/verify-github-governance.sh`](../scripts/ops/verify-github-governance.sh),
[`.github/CODEOWNERS`](../.github/CODEOWNERS), and the branch-protection findings in
`DILIGENCE_REPORT_2026-06-11.md` / `TECH_DEBT_AUDIT_2026-06-11.md`.

## How this MUST be applied — org ruleset with admin escrow

Author the desired protection here; **apply it as a GitHub organization-level ruleset** targeting
`refs/heads/main` (enforcement `active`), not as repo-level branch protection.

- **Bypass list excludes the daily-driver account.** The ruleset's `bypass_actors` MUST NOT contain
  the operator's everyday account, its PATs, or a bot it controls. Zero bypass is the desired state
  (this file encodes `enforce_admins: true`, empty `bypass_pull_request_allowances`, and
  `restrictions: null`).
- **Admin escrow via a second org owner.** The only break-glass path (temporarily relaxing the
  ruleset) is held by a *second* organization owner, so the person who authors code cannot also wave
  it past review from the same account.
- **Why org-level, not repo-level.** A repo admin can edit repo-level protection and toggle
  `enforce_admins` on themselves — the audit records this as "routine operating procedure" (206
  merges to `main` with zero human reviews under protection that *required* one). An org ruleset
  owned by a different owner removes that self-serve toggle: the daily account can neither edit the
  rule nor add itself to the bypass list.

The classic branch-protection field names are used here (rather than the ruleset JSON shape) so the
file stays directly diffable against the live `GET .../branches/main/protection` response consumed by
the drift check. When the operator translates it into a ruleset, the mapping is 1:1
(`required_approving_review_count` → pull-request rule, `contexts` → required-status-checks rule,
`allow_force_pushes: false` → `non_fast_forward`, `allow_deletions: false` → `deletion`, etc.).

## Required status checks — how the list was derived

`required_status_checks.contexts` lists the **exact check-run names** (a check-run is named after the
job's `name:`, with matrix values expanded) for the jobs that actually run on `pull_request → main`.
These were read from `.github/workflows/*` on 2026-06-30:

| Context (check-run name) | Workflow file | Job id | Notes |
| --- | --- | --- | --- |
| `Fast Feedback Gate` | `fast-feedback.yml` | `fast-feedback-gate` | Aggregate gate (`if: always()`, `needs:` all fast jobs) — the single stable context for that workflow. |
| `Secret Detection (gitleaks)` | `security-pr.yml` | `secret-detection` | |
| `Dependency Review (CVE check)` | `security-pr.yml` | `dependency-review` | `if: github.event_name == 'pull_request'` — runs on PRs only (skipped on `merge_group`). |
| `npm Audit (Node package locks)` | `security-pr.yml` | `npm-audit` | |
| `Remote Installer Policy` | `security-pr.yml` | `remote-installer-policy` | |
| `Production Deploy Auth Policy` | `security-pr.yml` | `production-deploy-auth-policy` | |
| `CODEOWNERS Security Trees` | `security-pr.yml` | `codeowners-security-trees` | |
| `Vendored Agent Provenance` | `security-pr.yml` | `vendored-agent-provenance` | |
| `Signal Activation Parity (fail-closed default)` | `security-pr.yml` | `signal-activation-parity` | |
| `Browser Target Policy (SSRF / DNS-rebinding)` | `security-pr.yml` | `browser-target-policy` | |
| `OSV Scanner (open source vulnerabilities)` | `security-pr.yml` | `osv-scanner` | |
| `Hosted MCP Security Smoke` | `security-pr.yml` | `hosted-mcp-security-smoke` | |
| `Hosted MCP Isolation Proofs (local, deterministic)` | `security-pr.yml` | `hosted-mcp-isolation-proofs` | |
| `Firestore Security Rules Tests` | `security-pr.yml` | `firestore-rules-tests` | |
| `Analyze (javascript-typescript)` | `codeql-pr.yml` | `analyze` (matrix) | Matrix `language: javascript-typescript`. |
| `Analyze (python)` | `codeql-pr.yml` | `analyze` (matrix) | Matrix `language: python`. |
| `PR Native Gate` | `pr-native-fast.yml` | `pr-native-gate` | Aggregate gate (`if: always()`); the SwiftPM/XcodeGen jobs are path-conditional and must NOT be required directly. |
| `App build + test (AgentLens)` | `app-pr-gate.yml` | `app-build-test` | |
| `Daemon Swift tests (proxy + router + quota)` | `daemon-pr-gate.yml` | `daemon-swift` | |
| `Release build (debug-only escape hatches compiled out)` | `daemon-pr-gate.yml` | `release-build-verification` | |
| `Android ktlint` | `android-ktlint.yml` | `android-ktlint` | |

`"PR Security Gate"` is a **workflow name** (`security-pr.yml`), not a check-run — GitHub cannot
require a workflow, only its jobs — so it expands into the thirteen `security-pr.yml` job contexts
above (which include `Firestore Security Rules Tests`).

### The `diff-coverage (PR)` placeholder

`_pending_required_status_checks` holds `diff-coverage (PR)` — the re-armed diff-coverage gate. It is
**segregated on purpose**: no workflow emits it yet, and a required context that is never reported
leaves every PR pending forever. Keep it here as declared intent, and promote it into
`required_status_checks.contexts` (and the live ruleset) in the *same* change that lands its emitting
workflow — never before. Context: the previous diff-coverage gate was gamed with presence-based
carve-outs on the privileged-input files and then dropped from CI (`DILIGENCE_REPORT_2026-06-11.md`),
so re-arming it is future-required work, not something to fake-require today.

### Application nuances (read before wiring live)

- **`security-pr.yml` has no aggregate gate job.** Each of its thirteen jobs is its own required
  context, which is brittle (rename a job → silently drop a gate). A future `pr-security-gate` job
  with `if: always()` and `needs:` all security jobs — mirroring `Fast Feedback Gate` /
  `PR Native Gate` — would collapse these into one stable context. Until then, keep this table and
  the JSON in sync when security jobs are added, renamed, or removed.
- **`Dependency Review (CVE check)` is PR-only** (skipped on `merge_group`). If a merge queue is
  enabled for `main`, confirm the queue does not stall on a required check that never reports there.
- **`app-pr-gate.yml` / `daemon-pr-gate.yml` jobs are draft-guarded**
  (`if: ... || github.event.pull_request.draft == false`) and have no `if: always()` gate. Draft PRs
  can't merge, so this doesn't block merges, but the required checks stay unreported on drafts —
  another reason to add aggregate gate jobs.

## Drift check (future, fail-closed)

A scheduled job (not wired here — the CI surface is mid-reconciliation) MUST diff the live protection
against this file and **fail closed** on any divergence, in particular:

- `required_pull_request_reviews == null` (**`reviews: null`**) — protection wiped or downgraded so no
  review is required. This is the single most dangerous drift and MUST be a hard failure.
- `enforce_admins` disabled, `allow_force_pushes`/`allow_deletions` enabled, review count below 1,
  code-owner reviews off, stale-review dismissal off, last-push approval off, or conversation
  resolution off.
- Any `bypass_pull_request_allowances` user/team/app, or any ruleset `bypass_actors` entry that
  includes the daily-driver account.
- Required `contexts` present live but **missing** from this file, or vice versa (set difference in
  either direction), normalizing GitHub's `contexts` vs `checks[].context` representations.

## Reworking `verify-github-governance.sh`

[`scripts/ops/verify-github-governance.sh`](../scripts/ops/verify-github-governance.sh) currently
hardcodes the required set in a `DEFAULT_REQUIRED_CHECKS` constant, which has already drifted (it
omits the native, app, and daemon gates entirely). It SHOULD be reworked to **read the required-check
set and the review/admin invariants from this file** and diff the live `GET .../protection` against
it, rather than carrying a hand-maintained constant. Preserve the invariants that script already
enforces (`enforce_admins`, no force-push/deletions, exactly-one approving review, code-owner
reviews, dismiss-stale, last-push approval, conversation resolution, zero bypass) — this file encodes
all of them, plus `require_last_push_approval: true`, so sourcing from here strengthens the bar rather
than weakening it.

That rework is intentionally **out of scope for this change** (the workflow/CI surface is being
edited concurrently); this file is the prerequisite artifact the rework will consume.
