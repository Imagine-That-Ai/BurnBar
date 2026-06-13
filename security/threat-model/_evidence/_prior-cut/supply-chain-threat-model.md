# Supply Chain and Build Security Threat Model

## Repository Evidence

| Surface | Evidence | Security value | Gaps |
| --- | --- | --- | --- |
| PR security gate | `.github/workflows/security-pr.yml` runs gitleaks, dependency review, npm audit, OSV, hosted MCP smoke/isolation, rules tests, policy checks | broad automated gate | some actions tag-pinned; some tests non-blocking |
| Release workflow | `.github/workflows/release.yml` includes tests, notarization, Sparkle signing, SBOM/VEX, checksums, cosign attestations | release integrity | live branch/env protection not proven |
| Deploy workflow | `.github/workflows/deploy-production.yml`, `deploy-firestore.yml` | production deploy path | legacy credential fallbacks and live IAM unknown |
| CodeQL/SAST | `.github/workflows/codeql*.yml`, `rust-sast.yml` | static analysis | coverage and PR gating need verification |
| Dependency manifests | SwiftPM, npm, Gradle, Rust, Python surfaces | dependency visibility | Dependabot coverage incomplete for some paths |
| SBOM/VEX/provenance | `docs/security/SUPPLY_CHAIN_PROVENANCE.md`, supply-chain workflow | artifact transparency | bit-for-bit reproducibility de-scoped |
| Vendored agent runtime | `third_party/hermes-agent/`, `docs/security/AGENT_RUNTIME_PROVENANCE.md` | runtime provenance tracking | source/pyc verifier not wired by default in release CI |

## Supply-Chain Attack Paths

| Attack path | Impact | Existing controls | Missing controls |
| --- | --- | --- | --- |
| Malicious GitHub Action tag update | CI secret theft or artifact tampering | some pinned hashes, permissions | SHA-pin all third-party actions or use trusted mirror |
| Compromised npm/Swift/Rust/Gradle dependency | RCE in build/app/backend | lockfiles, npm audit, OSV, dependency review | full transitive SBOM review, Sigstore/npm provenance where possible |
| Malicious vendored Hermes/Nous runtime | Agent runtime compromise | manifest/docs/verifier script | mandatory release gate proving source/runtime correspondence |
| PR exfiltrates CI secrets | secret compromise | PR security workflow, permissions | ensure no privileged secrets on untrusted PRs |
| Release workflow compromised | malicious signed app | notarization/signing/cosign/checksums | separate signing authority, environment approvals, artifact provenance verification |
| Firebase deploy credential compromise | backend/rules takeover | GitHub env/secrets, auth checks | OIDC-only deploy, remove legacy tokens/SA key fallback |
| Dependency confusion | malicious package resolution | lockfiles/local packages | registry allowlists and package manager config |
| Model/provider supply chain | malicious provider output/model behavior | provider routing, output filters | model/provider risk register and retention/config controls |
| Agent tool/plugin registry compromise | malicious tool description/schema | code-reviewed registry | signing/attestation for plugins/tools |

## Dependency Risk Summary

- Node Functions and hosted MCP have strong test scripts and audit gates, but some dependency version ranges remain.
- Swift/Rust/Android have substantial build surfaces; exact SCA coverage should be verified in CI.
- Python local MCP dependencies appear weaker than Node surfaces from repository evidence.
- Docker/container scanning evidence was not fully established.
- Third-party action tags are not uniformly SHA-pinned.
- Vendored agent runtime provenance remains one of the most auditor-relevant supply-chain questions.

## Release Integrity Checklist

Before Cure53:

- SHA-pin or justify every third-party GitHub Action.
- Prove branch protection/rulesets require security gates before release/deploy.
- Prove GitHub environment approvals protect production secrets.
- Remove or justify legacy Firebase token/service-account-key fallbacks.
- Generate SBOM for app, Functions, hosted MCP, local MCP, Rust, Android, and vendored runtime.
- Generate AIBOM/model/provider inventory: models, providers, embedding services, prompt/memory tools, tool registry.
- Ensure vendored agent source/runtime verifier is blocking in release.
- Verify notarization, Sparkle, checksums, cosign attestations, and release artifact hashes for latest release.
- Run secret scanning and review historical leaks.
- Document signing key storage, access, rotation, and break-glass.

## Minimum Bar Before Audit

| Item | Acceptance |
| --- | --- |
| CI action pinning | All third-party actions pinned by SHA or documented exception with compensating control. |
| Release provenance | Latest release has SBOM, VEX, checksums, notarization/Sparkle, cosign attestations, and reproducible build inputs. |
| Vendored runtime proof | Verifier proves runtime/source correspondence and blocks release on mismatch. |
| Dependency coverage | Dependabot/SCA covers all package roots including tools and packages. |
| Secret exposure | gitleaks/secret scanning clean or all findings triaged. |
| Production deploy protection | GitHub environment/branch protection export attached to audit brief. |
| CI secrets | No production secrets exposed to untrusted PR jobs. |
