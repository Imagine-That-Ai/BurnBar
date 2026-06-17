# Supply Chain and Secure SDLC Review

## Threat Model

| Threat | Existing controls | Missing controls / gaps | Evidence |
|---|---|---|---|
| malicious dependency | lockfiles, npm audit, OSV, dependency review | periodic Swift/Kotlin/Rust review | `.github/workflows/security-pr.yml` |
| compromised maintainer | dependency review and scans | provenance for all ecosystems incomplete | security PR workflow |
| compromised CI runner | pinned actions, limited permissions, production environment | live branch protection not verified | `.github/workflows/fast-feedback.yml`, `codeql.yml` |
| leaked CI secret | gitleaks and masked secrets | production deploy long-lived fallbacks | `security-pr.yml`, `deploy-production.yml` |
| malicious PR | fast feedback, CodeQL, security PR checks, no-suppression gate | live required checks unknown | workflows and `check-no-suppressions.sh` |
| artifact tampering | SBOM, OpenVEX, cosign attestation | reproducibility/notarization not complete | `supply-chain-provenance.yml` |
| release key compromise | production environment and rollback | WIF-only deploy not enforced | `deploy-production.yml` |
| poisoned tool/model dependency | hosted MCP tool registry, scopes, rate limits | adversarial tool-output tests should expand | `toolRegistry.ts` |

## Release Integrity Checklist

| Control | Status | Gap |
|---|---|---|
| branch protections | unknown live state | verify with GitHub API |
| required reviews | unknown live state | verify with GitHub API |
| status checks | partial | verify branch protection required checks |
| least-privilege CI tokens | mostly defensible | audit all workflows |
| pinned actions | strong in key workflows | audit every workflow |
| secret scanning | defensible | confirm full-history schedule |
| dependency review | defensible | none major |
| artifact signing/attestation | partial | reproducibility/notarization de-scoped |
| SBOM | partial | ensure shipped artifacts consume it |
| deployment approvals | partial | live reviewers unknown |
| rollback process | partial | drill evidence missing |

## Recommendations

1. Remove `FIREBASE_TOKEN` and service-account JSON fallback from production deploy.
2. Verify branch protection live state during each release-gate audit.
3. Add a static workflow policy for WIF-only production deploy.
4. Expand provenance to shipped app artifacts.
5. Attach SBOM and attestation references to releases.

