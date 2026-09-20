# Nightly CI Repair Runbook

OpenBurnBar uses two CI loops:

1. Fast merge checks for daily PR velocity.
2. Full-confidence checks after merge, nightly, and on demand.

The repair loop should run in the cloud. Do not depend on the primary operator's
Mac being awake.

## GitHub Actions Schedule

- `fast-feedback.yml` runs on PRs and merge groups. Branch protection should
  require `Fast Feedback Gate`.
- `security-pr.yml`, `confidentiality-guard.yml`, and `license-posture.yml`
  run on PRs, merge groups, and pushes to `main`. Branch protection should
  require their fast safety checks.
- `openburnbar-pr-harness.yml` runs nightly at `37 8 * * *` UTC and on manual
  dispatch (the per-push `main` trigger was removed in the 2026-07-31 CI-cost
  hardening). It is the full platform harness and should not be a daily PR
  merge blocker.
- `nightly-e2e.yml` runs nightly at `43 9 * * *` UTC and manual dispatch. It
  opens or closes a deduplicated failure issue via
  `.github/actions/ops-failure-issue`.
- `codex-nightly-ci-repair.yml` is the repair loop. It runs daily at
  `45 12 * * *` UTC, after every monitored confidence lane's maximum runtime.
  If the latest completed runs are green, it exits. If they are red, it
  gathers their failed logs and runs the official OpenAI Codex Action as the
  repair operator.
- Once a Codex repair PR exists, the next daily sweep (or a manual dispatch)
  inspects that PR. If the repair PR is red, Codex continues it. If the PR is
  pending or green, the workflow does not spawn another agent. The former
  per-completion `workflow_run` fan-out was removed in the 2026-07-31 CI-cost
  hardening because it self-cascaded hundreds of skipped runs per day; the
  Cursor twin of this loop (`cursor-nightly-ci-repair.yml`) was retired at the
  same time.

After this workflow change lands on `main`, update branch protection so the
required PR checks are:

```text
Fast Feedback Gate
guard
BurnBar AGPL product posture
Secret Detection (gitleaks)
Dependency Review (CVE check)
npm Audit (Node package locks)
Remote Installer Policy
Vendored Agent Provenance
Signal Activation Parity (fail-closed default)
Browser Target Policy (SSRF / DNS-rebinding)
OSV Scanner (open source vulnerabilities)
Hosted MCP Security Smoke
Hosted MCP Isolation Proofs (local, deterministic)
Firestore Security Rules Tests
```

Then verify the live GitHub policy:

```bash
bash scripts/ops/verify-github-governance.sh
```

## Codex Setup

The implemented path is `.github/workflows/codex-nightly-ci-repair.yml`.
It runs a small GitHub Actions scheduler and the official OpenAI Codex Action
(`openai/codex-action`) as the cloud worker. It does not depend on the
operator's Mac or a local CLI install.

One secret is required:

```bash
gh secret set OPENAI_API_KEY --repo Imagine-That-Ai/BurnBar --body "$OPENAI_API_KEY"
```

Without this secret, the workflow exits with a notice and does not run the
repair operator.

The workflow pins Codex runs to `gpt-5.5` with a workspace-write sandbox.

The workflow uses a restricted-autonomy pattern:

- GitHub Actions reads scheduled CI results and failed logs.
- GitHub Actions sends only the summary and a capped, sanitized failed-log
  excerpt to Codex.
- Codex edits the prepared `codex/nightly-ci-repair` branch in the Actions
  checkout; the workflow commits, pushes, and opens or updates the PR after
  Codex exits.
- The authoritative repair identity is the base-repository branch
  `codex/nightly-ci-repair` after GitHub provenance validation. The
  `codex-nightly-ci-repair` marker in the PR body is display-only and is not
  an authority signal.
- Only the daily or manual trigger can create the first repair PR.
- If an existing repair PR is only waiting on pending checks or already green,
  the loop waits instead of spawning another agent.
- Codex is instructed not to edit branch protection, required checks, release
  gates, workflow definitions, or tests just to hide a failure.
- If the failure is external infrastructure, credentials, GitHub outage,
  Apple/Xcode runner outage, or missing secrets, Codex reports the operator
  action instead of changing code.

This keeps the agent useful without giving it direct control over branch
protection or publishing.

The Cursor twin of this loop (`cursor-nightly-ci-repair.yml` plus the native
Cursor Cloud Agent Automation) was retired in the 2026-07-31 CI-cost
hardening. Do not configure `CURSOR_API_KEY` or recreate the Cursor
automation; Codex is the only nightly repair plane.

## Manual Triage Commands

```bash
gh run list --workflow openburnbar-pr-harness.yml --branch main --limit 5
gh run list --workflow nightly-e2e.yml --branch main --limit 5
gh run list --workflow codeql.yml --branch main --limit 5
gh run view <run-id> --json status,conclusion,jobs
gh run view <run-id> --log-failed
```

For PR velocity, use:

```bash
gh pr checks <pr-number>
```

That command should tell you whether the fast merge gate is green. It should
not require waiting for the full harness.

## Swift SAST lanes (W0-10, 2026-09-01)

The nightly `codeql.yml` Swift lane runs a Metal toolchain **preflight**
(`xcrun -f metal`) immediately after checkout, before any heavy Swift prep: a
missing Metal toolchain now fails in seconds with a `::error::` naming the fix
(the lane now runs `xcodebuild -downloadComponent MetalToolchain` itself; if
that cannot install it, pick a runner image whose Xcode bundles the toolchain) instead of dying ~75 minutes into the
traced build with `cannot execute tool 'metal'` (run 33517666151). The traced
xcodebuild invocation lives in `scripts/ci/codeql-swift-build.sh` and the
When `xcrun -f metal` finds no compiler, the lane first installs the Xcode `MetalToolchain` component (`xcodebuild -downloadComponent MetalToolchain`) and re-checks; Metal is a toolchain component, so no DerivedData cache can supply it. The
lane is still bounded by the hosted-runner 150-minute cap: **if the traced
Swift build exceeds the cap, park it as `OPEN_WITH_NAMED_BLOCKER: traced
Swift build exceeds cap` — never raise `timeout-minutes`, never drop `swift`
from the matrix.** Separately, `semgrep-swift.yml` runs Semgrep on a pinned
snapshot of the public `p/swift` ruleset (`scripts/ci/semgrep/p-swift.pinned.yaml`, no token) on schedule + dispatch and uploads its SARIF as a
plain artifact — it is **observe-only**: not in the Fast Feedback Gate
`needs:` list, not a required context, no code-scanning upload. Promote it
to a gate only after its false-positive rate is known.
