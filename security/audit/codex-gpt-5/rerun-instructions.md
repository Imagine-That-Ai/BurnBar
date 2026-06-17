# Rerun Instructions

Model/run namespace: `codex-gpt-5`

## Inputs

Record run mode, repository root, commit SHA, branch or PR, target release, previous audit directory, target score, and claim set.

## Clean Main Worktree

If the primary checkout is dirty or not on the target branch, create a clean worktree:

```bash
tmp="$(mktemp -d /private/tmp/burnbar-security-audit-main-XXXXXX)"
git worktree add --detach "$tmp" origin/main
cd "$tmp"
```

## State Handling

For this namespace, load:

- `security/audit/codex-gpt-5/audit-state.json`
- `security/audit/codex-gpt-5/findings.json`
- `security/audit/codex-gpt-5/security-score.json`

Preserve existing IDs. Append new IDs. Do not renumber.

Classify previous findings as still open, improved, fixed with test, fixed without test, worsened, reopened, accepted risk, no longer applicable, or cannot verify.

## Required Evidence Pass

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

## Safe Local Checks

```bash
node -e 'const fs=require("fs"); for (const f of ["security/audit/codex-gpt-5/audit-state.json","security/audit/codex-gpt-5/findings.json","security/audit/codex-gpt-5/security-score.json"]) JSON.parse(fs.readFileSync(f,"utf8"));'
python3 -c 'import csv; list(csv.DictReader(open("security/audit/codex-gpt-5/threat-register.csv")))'
bash scripts/ci/verify-resilience-wiring.sh
bash scripts/ci/check-no-suppressions.sh
```

## Gates

Do not raise the score significantly from documentation-only changes except to remove an audit-readiness cap.

Do not mark a finding fixed without implementation evidence and a regression test, unless the audit records why a test is infeasible and gives manual verification steps.

Do not remove the Major Claim Cap until FINDING-001 is fixed with production-mode test evidence, daemon kill-switch/entitlement context is fixed or claims are narrowed, Firestore App Check deployment state is verified or claims are narrowed, and broad Signal/E2EE claims are removed or flow-specific proof exists.

## Required Files

Every rerun should update the same 28 files under `security/audit/codex-gpt-5/`.

