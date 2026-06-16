# Supply Chain and Release Integrity Review

## A.10.1 Dependencies

| Ecosystem | Manager | Notable High-Risk Dependencies |
|---|---|---|
| Swift | SwiftPM | libsignal (AGPL), GRDB, GRDB-SQLCipher, Firebase iOS SDK |
| TypeScript/Node | npm/pnpm | Many; `functions/package.json`, `services/hosted-mcp/package.json` |
| Kotlin | Gradle | Firebase Android SDK, iroh Rust crate via JNI |
| Rust | cargo | libsignal-protocol, iroh |
| Python | pip/uv | `tools/openburnbar-mcp/server.py` dependencies |

### Dependency Management

- `scripts/supply-chain-audit.sh` runs license and vulnerability scans.
- `docs/SUPPLY_CHAIN.md` documents policy.
- No lockfile pinning visible for all ecosystems? Verify `Package.resolved`, `Cargo.lock`, `pnpm-lock.yaml`, `uv.lock`.

## A.10.2 CI/CD Security

### Workflows

- `.github/workflows/fast-feedback.yml` — PR gates.
- `.github/workflows/release.yml` — signs, notarizes, SBOM, VEX, cosign.
- `.github/workflows/deploy-production.yml` — production deploy.
- `.github/workflows/pr-review.yml` — automated review comments.

### Strengths

- macOS app is **signed, notarized, and stapled**.
- DMG and Sparkle appcast are signed.
- cosign attestations and VEX published.
- SBOM generated per release.

### Risks

- CI has access to signing keys, App Store API key, Firebase service account.
- A compromised maintainer account or malicious workflow can ship a malicious release.
- No reproducible build evidence visible.

## A.10.3 Release Integrity Artifacts

| Artifact | Produced | Location |
|---|---|---|
| Signed .app / .dmg | Yes | GitHub releases |
| Notarization ticket | Yes | Stapled in DMG |
| SBOM (SPDX/CycloneDX) | Yes | GitHub releases |
| VEX | Yes | GitHub releases |
| cosign signature | Yes | GitHub releases / registry |
| Checksums | Yes | GitHub releases |
| Sparkle appcast signature | Yes | Update server |

## A.10.4 Local Tooling

- `scripts/security/scan-publishable-tree.sh` scans for secrets before release.
- `scripts/generate-sbom.py` generates SBOM.
- Pre-commit hooks include gitleaks and detect-secrets.

## A.10.5 Prior Audit Items (Supply Chain)

| ID | Title | Status | Notes |
|---|---|---|---|
| M-040 | Dependency confusion / typosquatting | Partial | Pinning + lockfiles mitigate; need provenance verification |
