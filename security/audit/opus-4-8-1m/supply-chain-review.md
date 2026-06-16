# Supply Chain & Secure SDLC Review — Opus 4.8 1M lane

Verdict: **Mature, SSDF/SLSA-aligned.** All three prior-review supply-chain findings (CG-1, qa.yml secrets, deploy submodule checkout) are **fixed** on this branch. Only minor residuals.

## K.1 Release-integrity checklist

| Control | Present | Evidence | Gap |
|---|---|---|---|
| GitHub Actions SHA-pinning | yes | 271/271 external `uses:` pinned to 40-hex SHAs; blocking verifier `scripts/ci/verify-github-action-pins.mjs:25-27` wired `workflow-lint.yml:46` | — |
| Least-priv CI tokens | yes | per-workflow `permissions:` blocks (`release.yml:3-7`, `deploy-production.yml:3-6`, etc.) | — |
| Secret scanning (CI) | yes | gitleaks `security-pr.yml:63-79` (PR+push, history-range); trufflehog in `release.yml:118-122` | — |
| Secret scanning (pre-commit) | yes | `.pre-commit-config.yaml:158-173` gitleaks + detect-secrets + detect-private-key | advisory (CI is hard gate) |
| Confidentiality guard | yes | `confidentiality-guard.yml:45-49` full tree + self-test | branch-protection requirement is GitHub-side |
| CODEOWNERS | partial | `.github/CODEOWNERS` (default `* @Ajnunezg`) | no explicit security-path rules (OPUS-F-012) |
| Branch protection / required checks | partial | wiring present (`security-pr.yml:42-43` push backstop) | actual ruleset unverifiable (OPUS-U-005) |
| App signing (Developer ID) | yes | `release.yml:388-457` ephemeral keychain, deep codesign `--options runtime --timestamp`, verify | — |
| Notarization + stapling | yes | `release.yml:490-539` `notarytool submit --wait` + `stapler staple/validate` | — |
| Update feed signing (Sparkle EdDSA) | yes | `release.yml:179-191,609-622` Ed25519 sign, fail-closed if empty | — |
| SBOM + provenance/VEX | yes | `release.yml:699-759` SPDX SBOM, OpenVEX, cosign keyless OIDC attest; `supply-chain-provenance.yml` re-attest | reproducible builds de-scoped (acknowledged) |
| Vendored submodule provenance | yes | `release.yml:574-578` libsignal pin verify; `license-posture.yml:61-71` LICENSE gate fail-closed | — |
| Deploy submodule checkout | **fixed** | `deploy-production.yml:46,68` `submodules: recursive` + re-sync | prior NB-2/C8 wedge resolved |
| Deploy approvals / rollback | yes | GitHub environments wired; auto-rollback `deploy-production.yml:228-247` | approval rules GitHub-side |
| Dependency integrity | yes | `npm ci` everywhere; lockfiles committed (Cargo.lock, Package.resolved) | — |
| Dependency review / CVE gate | yes | Dependency Review (`fail-on-severity: high`), npm audit, OSV-Scanner, cargo-audit | PR-only by design |
| Dependabot | yes | `.github/dependabot.yml` npm/gradle/cargo/swift/**github-actions** | — |
| No remote `curl\|sh` installers | yes | `verify-no-remote-shell-installers.sh` blocking | — |
| SAST (CodeQL) | yes | Swift+Kotlin+JS/TS+Python `security-extended`; Rust via `rust-sast.yml` | Swift CodeQL nightly not PR (documented) |
| No-suppressions meta-gate | yes | `check-no-suppressions.sh` blocks new disable/ignore/allow without `reason:` token; wired blocking + self-test | — |

## K.2 Supply-chain threat notes
- **Malicious dependency:** strong — lockfile-pinned, multi-scanner fail-closed; only postinstall runs local repo scripts (no remote fetch).
- **Compromised CI runner:** mitigated — least-priv tokens, ephemeral signing keychain created/destroyed per run, secrets minimized to consuming step.
- **Leaked CI secret:** mitigated — qa.yml secret scope narrowed (prior over-broad exposure **fixed**); fork PRs skip via `INTERNAL_RUN` guard.
- **Artifact tampering:** strong — sha256+sha512, GPG-signed checksums (best-effort OPUS-F-016), cosign attestations, SBOM+VEX, Sparkle EdDSA on update DMG verified in-client.
- **Release-key compromise:** single-signer model — Developer ID + notary + Sparkle EdDSA + GPG keys live in the GitHub `release` environment. Compromise of that environment = full release-chain compromise (inherent solo-operator residual; no HSM/multi-party signing).

## K.3 Prior-finding dispositions
- **CG-1 (coverage-gate gaming):** **FIXED** for Swift (`scripts/diff-coverage.sh` carve-outs reverted; unmeasured = uncovered); Android presence-fallback code path remains for local dev only (OPUS-F-011).
- **qa.yml secrets / green-washing:** **FIXED** (honest-conclusion exit, narrowed scope, version-pinned CLI).
- **deploy-production submodule checkout:** **FIXED**.
