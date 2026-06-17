# Supply Chain and Secure SDLC Review

## K.1 Supply Chain Threat Model

| Threat | Existing controls | Missing controls / gaps | Evidence |
|---|---|---|---|
| Malicious dependency | lockfiles, npm audit, OSV scanner, dependency review | Swift/Kotlin/Rust dependency posture should be periodically reviewed | `.github/workflows/security-pr.yml:81-147,221-240` |
| Compromised maintainer | dependency review and scans | provenance for all dependency ecosystems not complete | security PR workflow |
| Dependency confusion | package manager lockfiles and ecosystem checks | private package namespace policy not fully reviewed | package manifests |
| Compromised CI runner | pinned actions, limited permissions, production environment | self-hosted runner posture unknown if any; live branch protection not verified | `.github/workflows/fast-feedback.yml`, `codeql.yml` |
| Leaked CI secret | gitleaks, GitHub secret masking, environment secrets | production deploy long-lived fallback paths | `.github/workflows/security-pr.yml:51-79`, `deploy-production.yml:109-119,193-201` |
| Malicious PR | fast feedback, CodeQL PR mode, security PR checks, no-suppression gate | live required checks/branch protection not verified | `.github/workflows/fast-feedback.yml`, `security-pr.yml`, `check-no-suppressions.sh` |
| Artifact tampering | SBOM, OpenVEX, cosign attestations | reproducible/notarized build chain not complete | `.github/workflows/supply-chain-provenance.yml:59-93,111-113` |
| Release key compromise | production environment and rollback | WIF-only deploy not enforced | `.github/workflows/deploy-production.yml` |
| Poisoned model/tool/plugin dependency | hosted MCP tool registry, scopes, rate limits | adversarial tool-output tests should expand | `services/hosted-mcp/src/toolRegistry.ts` |

## K.2 Release Integrity Checklist

| Control | Status | Evidence | Gap |
|---|---|---|---|
| Branch protections | Unknown live state | workflow comments reference branch protection | verify with GitHub API |
| CODEOWNERS | Not reviewed in this run | repository may contain ownership files | include in next rerun |
| Required reviews | Unknown live state | GitHub settings external | verify with GitHub API |
| Status checks | Partially defensible | workflows exist | verify branch protection required checks |
| Least-privilege CI tokens | Mostly defensible | permissions blocks in workflows | check all workflows |
| Pinned actions | Strong in key workflows | `fast-feedback.yml`, `codeql.yml` | audit every workflow |
| Secret scanning | Defensible | gitleaks in `security-pr.yml` | confirm full-history scheduled scans |
| Dependency review | Defensible | `security-pr.yml:81-99` | none major |
| Artifact signing/attestation | Partial | `supply-chain-provenance.yml:59-93` | reproducibility/notarization de-scoped |
| SBOM | Partial | CycloneDX/OpenVEX generated | ensure release artifacts consume it |
| Deployment approvals | Partial | production environment configured | live reviewers unknown |
| Rollback process | Partial | deploy workflow rollback step | drill evidence missing |

## Secure SDLC Evidence

- Fast CI runs lint, typecheck, generated rules checks, tests, and AGPL checks: `.github/workflows/fast-feedback.yml`.
- CodeQL covers Swift, JavaScript/TypeScript, and Python: `.github/workflows/codeql.yml`.
- Security PR workflow runs gitleaks, dependency review, npm audit, OSV, policy gates, hosted MCP security smoke, and Firestore emulator tests: `.github/workflows/security-pr.yml`.
- No-suppression gate blocks new lint/type suppressions without reasons or allowlist: `scripts/ci/check-no-suppressions.sh:1-24`.
- Resilience wiring gate blocks raw `await fetch` in `functions/src` outside the approved wrapper: `scripts/ci/verify-resilience-wiring.sh:1-48`.
- Supply-chain provenance workflow emits SBOM/OpenVEX and cosign attestation: `.github/workflows/supply-chain-provenance.yml:59-93`.

## Recommendations

1. Remove `FIREBASE_TOKEN` and service-account JSON fallback from production deploy.
2. Verify branch protection live state during every release-gate audit.
3. Add a static workflow policy for WIF-only production deploy.
4. Expand provenance to the app artifacts that are actually shipped.
5. Attach SBOM and attestation references to release notes.

