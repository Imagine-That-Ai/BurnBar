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
- `openburnbar-pr-harness.yml` runs on `push` to `main`, nightly at
  `37 8 * * *` UTC, and manual dispatch. It is the full platform harness and
  should not be a daily PR merge blocker.
- `nightly-e2e.yml` runs nightly at `43 9 * * *` UTC and manual dispatch. It
  opens or closes a deduplicated failure issue via
  `.github/actions/ops-failure-issue`.
- `cursor-nightly-ci-repair.yml` runs at `15 11 * * *` UTC. It gathers the
  latest failed scheduled logs and starts a Cursor Cloud Agent through Cursor's
  API. Cursor works in the cloud and opens a repair PR when the failure is
  code-owned.

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

## Cursor Setup

The implemented path is `.github/workflows/cursor-nightly-ci-repair.yml`.
It runs a small GitHub Actions scheduler and calls the Cursor Cloud Agents API.
It does not depend on the operator's Mac, the Cursor desktop app, or a local
headless CLI install.

One secret is required:

```bash
gh secret set CURSOR_API_KEY --repo Imagine-That-Ai/BurnBar --body "$CURSOR_API_KEY"
```

Create the API key in Cursor Dashboard -> API Keys. Make sure the Cursor
account or team has GitHub access to `Imagine-That-Ai/BurnBar`, because Cursor
opens the repair PR from its own cloud agent. Without this secret, the workflow
exits with a notice and does not run the repair agent.

The workflow pins Cursor Cloud Agent runs to `composer-2.5`, the standard
Composer 2.5 model. It does not use the fast variant or the account default.

The workflow uses a restricted-autonomy pattern:

- GitHub Actions reads scheduled CI results and failed logs.
- GitHub Actions sends only the summary and capped failed-log excerpt to Cursor.
- Cursor starts from `main`, works in the cloud, and may open a PR.
- Cursor is instructed not to edit branch protection, required checks, release
  gates, workflow definitions, or tests just to hide a failure.
- If the failure is external infrastructure, credentials, GitHub outage,
  Apple/Xcode runner outage, or missing secrets, Cursor should report the
  operator action instead of changing code.

This keeps the agent useful without giving it direct control over branch
protection or publishing.

## Native Cursor Automations

Cursor also supports native Cloud Agent Automations at `cursor.com/automations`.
Use that UI if you want Cursor to own the schedule directly instead of GitHub
Actions.

Recommended settings:

```text
Trigger: scheduled, daily after 11:00 UTC
Repository: Imagine-That-Ai/BurnBar
Branch: main
Tools: GitHub pull request creation
Permission scope: Team Owned if available, otherwise Private
Prompt: use the operating rules below
```

Prompt:

```text
You are the OpenBurnBar nightly CI repair operator.

Goal:
Keep scheduled full-confidence CI lanes green without slowing daily PR
development.

Inspect these lanes:
- OpenBurnBar Full Harness: .github/workflows/openburnbar-pr-harness.yml
- OpenBurnBar Nightly E2E: .github/workflows/nightly-e2e.yml
- CodeQL: .github/workflows/codeql.yml
- Ops Confidence: .github/workflows/ops-confidence.yml
- Ops Plane Verify: .github/workflows/ops-plane-verify.yml

Rules:
- Do not modify branch protection, required checks, release gates, or workflow
  definitions to make a red run green.
- Do not skip, delete, downgrade, or mark tests continue-on-error to hide a
  failure.
- If the failure is external infrastructure, credentials, device access, or a
  human decision, report the exact operator action needed and do not change
  code.
- If the failure is code-owned, make the smallest durable fix.
- Open a PR. Do not merge it.
- Include failed workflow/run link, root cause, files changed, validations run,
  and residual risk in the PR body.
```

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
