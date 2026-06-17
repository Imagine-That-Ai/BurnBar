# Rerun Instructions

This audit is designed to be re-run on any future commit.

## Inputs

Record:

- run mode: `FULL_BASELINE`, `DELTA_REVIEW`, `VERIFY_FINDINGS`, `RELEASE_GATE`, or other mode
- repository root
- commit SHA
- branch or PR
- target release
- previous audit directory
- target score and claim set

## Baseline Command Sequence

```bash
git fetch origin
git rev-parse HEAD
git status --short --branch
find security/audit -maxdepth 1 -type f | sort
```

If the primary checkout is dirty or not on the target branch, create a clean worktree:

```bash
tmp="$(mktemp -d /private/tmp/burnbar-security-audit-main-XXXXXX)"
git worktree add --detach "$tmp" origin/main
cd "$tmp"
```

## Compare Previous State

If `security/audit/audit-state.json` exists:

1. Preserve existing finding, threat, claim, asset, flow, and test IDs.
2. Load previous findings and classify each as still open, improved, fixed with test, fixed without test, worsened, reopened, accepted risk, no longer applicable, or cannot verify.
3. Append new IDs; do not renumber old IDs.
4. Update `security-score.json` with previous/current raw and final scores.

If no previous state exists, run `FULL_BASELINE`.

## Required Code Evidence Pass

Review at minimum:

- `functions/src/auth.ts`
- `functions/src/config.ts`
- `functions/src/appCheckAttestation.ts`
- `functions/src/callables/highRiskOwnerAction.ts`
- `functions/src/security/endpointAuthorizationCatalog.generated.ts`
- `functions/src/callables/shared/validators.ts`
- `functions/src/callables/stripe.ts`
- `functions/src/callables/dataExport.ts`
- `functions/src/callables/dataDeletion.ts`
- `functions/src/callables/auditLog.ts`
- `functions/src/logging.ts`
- `firestore.rules`
- `storage.rules`
- `OpenBurnBarDaemon/`
- `OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/CloudVaultCrypto.swift`
- `OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/`
- `services/hosted-mcp/src/`
- `tools/openburnbar-mcp-remote/src/`
- `.github/workflows/`
- relevant tests under `functions/src/__tests__`, `OpenBurnBarDaemon/Tests`, `services/hosted-mcp`, `firestore-rules-tests`, and `AgentLensTests`

## Safe Local Checks

Run what is available and non-destructive:

```bash
node -e 'const fs=require("fs"); for (const f of ["security/audit/audit-state.json","security/audit/findings.json","security/audit/security-score.json"]) JSON.parse(fs.readFileSync(f,"utf8"));'
python3 -c 'import csv; list(csv.DictReader(open("security/audit/threat-register.csv")))'
bash scripts/ci/verify-resilience-wiring.sh
bash scripts/ci/check-no-suppressions.sh
```

Optional when toolchain is ready:

```bash
cd functions && npm test
cd services/hosted-mcp && npm test
cd OpenBurnBarDaemon && swift test
```

## Gates

Do not raise the final score significantly from documentation-only changes except to remove the audit-readiness cap.

Do not mark a finding fixed unless:

- implementation evidence exists, and
- a regression test exists, or
- the audit explicitly records why a test is not feasible and gives manual verification steps.

Do not remove the Major Claim Cap until:

- FINDING-001 is fixed with production-mode test evidence,
- daemon kill-switch/entitlement context is fixed or claims are narrowed,
- Firestore App Check deployment state is verified or claims are narrowed,
- broad Signal/E2EE claims are removed or flow-specific proof exists.

## Output Files

Every rerun must update all files under `security/audit/`:

1. `README.md`
2. `audit-state.json`
3. `repository-map.md`
4. `security-definition.md`
5. `architecture.md`
6. `assets.md`
7. `security-claims.md`
8. `authz-review.md`
9. `crypto-secrets-review.md`
10. `app-api-review.md`
11. `privacy-logging-review.md`
12. `cloud-ops-review.md`
13. `supply-chain-review.md`
14. `ai-agentic-review.md`
15. `threat-register.md`
16. `threat-register.csv`
17. `abuse-cases.md`
18. `findings.md`
19. `findings.json`
20. `evidence-map.md`
21. `security-test-plan.md`
22. `remediation-roadmap.md`
23. `security-score.md`
24. `security-score.json`
25. `release-gate.md`
26. `auditor-brief.md`
27. `open-questions.md`
28. `rerun-instructions.md`

