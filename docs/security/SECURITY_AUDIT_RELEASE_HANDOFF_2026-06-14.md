<!-- burnbar:confidential -->
> **BurnBar-Confidential: internal.** Do not publish to the public repo.

# Security Audit Release Handoff - 2026-06-14

This is the operator handoff for the OpenBurnBar multi-model audit synthesis and remediation pass. It exists to prevent two failure modes:

- treating raw model/run evidence as the final authority
- accidentally publishing open-vulnerability notes, scratch verdicts, or local proof gaps

## Current Authority

The authoritative local synthesis package is exactly these files:

- `security-audit/merged/00_model_coverage_matrix.md`
- `security-audit/merged/01_deduped_findings.jsonl`
- `security-audit/merged/02_skeptic_review.md`
- `security-audit/merged/03_ranked_findings.md`
- `security-audit/merged/04_release_blockers.md`
- `security-audit/merged/FINAL_REPORT.md`

Anything under `security-audit/model-runs/`, `security-audit/workbench/`, `.agent/runs/`, or `security/threat-model/` is input evidence or reviewer scratch material. It may be useful for private review, but it is not the final publishable report.

## Local Verification Gates

Run these before a review branch, tag, release, or external handoff:

```bash
node --test scripts/security/__tests__/scan-internal-content.test.mjs
node --test scripts/security/__tests__/verify-merged-audit-package.test.mjs
node scripts/security/verify-merged-audit-package.mjs
git diff --check
```

If preparing a public/publishable bundle, run:

```bash
node scripts/security/scan-internal-content.mjs --publishable
```

That command is expected to fail while this internal handoff, raw audit packages, or generated scan reports remain in the publishable tree. Move them under `internal/` or keep them out of the staged/published set before any public release.

## Live Verification Gates

Source and focused tests cannot prove deployed state. Before publication or release claims, collect fresh readback for:

- deployed Firebase Functions and rules hashes
- Firestore TTL policies for push/account-erasure collections
- App Check enforcement and token max-age settings
- Sentry project/client artifact scrubbing settings
- GCP IAM/KMS/Secret Manager rotation state after the committed-evidence incident
- GitHub branch protection / ruleset state for the release branch
- clean standard-user macOS Remote Unlock plus panic-halt smoke test

Preferred existing entry points:

```bash
bash scripts/ci/verify-ops-readiness.sh
VERIFY_OPS_PLANE_SUMMARY=.derived-data/security/verify-ops-plane-summary.json \
  bash scripts/ops/verify-production-ops-plane.sh
bash scripts/ops/verify-github-governance.sh
```

Do not convert source-level fixes into deployed-state claims until those readbacks are attached to the release evidence.

## Publication Rule

No public report should mention a finding as closed unless the final report links to the regression test or the live verification artifact that proves it. When a finding is source-fixed but not live-proven, keep it labeled as source-fixed pending deploy/readback.
