# Supply chain provenance (SLSA + cosign)

OpenBurnBar ships privileged-input capabilities. Release artifacts therefore carry **SLSA build provenance** and **Sigstore cosign attestations** in addition to SPDX SBOMs and OpenVEX sidecars.

## What we attest

| Artifact | Provenance | Attestation |
|----------|------------|-------------|
| Release DMG + ZIP | GitHub Actions OIDC → SLSA v1 predicate | `cosign attest` (keyless via `id-token: write`) |
| SPDX SBOM | Same workflow job as release build | Attached attestation + GitHub artifact |
| Checksums file | SHA-256/512 in `checksums-v*.txt` | Signed blob attestation |
| OpenVEX sidecar | Generated from SBOM at build time | Uploaded alongside SBOM |

Workflows:

- [`.github/workflows/release.yml`](../../.github/workflows/release.yml) — builds, SBOM, VEX, cosign attestations on tag releases.
- [`.github/workflows/supply-chain-provenance.yml`](../../.github/workflows/supply-chain-provenance.yml) — standalone re-attestation / provenance verification (`workflow_dispatch`).
- [`.github/workflows/openburnbar-pr-harness.yml`](../../.github/workflows/openburnbar-pr-harness.yml) — PR SBOM + VEX + ecosystem deny checks.

## OIDC + cosign (keyless)

Release jobs request:

```yaml
permissions:
  contents: read
  id-token: write
  attestations: write
```

Cosign uses GitHub's OIDC identity (`sigstore/cosign-installer` + `cosign attest`). No long-lived signing key is stored in the repository. Operators may additionally configure `RELEASE_SIGNING_KEY` (GPG) for checksum `.asc` files — that path is legacy-compatible, not a substitute for Sigstore attestations.

## SBOM + VEX on every PR and release

| Surface | SBOM | VEX |
|---------|------|-----|
| PR | `scripts/generate-sbom.py` from tracked SwiftPM, npm, Cargo, and Android/Gradle manifests | `scripts/supply-chain/generate-vex.py` |
| Release tag | Full SPDX via `scripts/generate-sbom.py` from the same tracked dependency surface | OpenVEX sidecar uploaded to GitHub Release |

VEX is a **triage artifact**: default generation marks `not_affected` with a placeholder statement when no exceptions are filed. Update VEX when `npm audit`, OSV-Scanner, or `cargo-deny` findings are accepted with documented rationale.

## Ecosystem deny checks

[`scripts/supply-chain/run-ecosystem-deny-checks.sh`](../../scripts/supply-chain/run-ecosystem-deny-checks.sh) runs:

| Ecosystem | Tool | Config |
|-----------|------|--------|
| Rust (`crates/openburnbar-iroh`) | `cargo-deny` | [`crates/openburnbar-iroh/deny.toml`](../../crates/openburnbar-iroh/deny.toml) |
| Node (functions + extension) | `npm audit --audit-level=high` | lockfiles |
| SBOM inventory | SPDX package URLs | tracked SwiftPM, npm, Cargo, and Android/Gradle manifests |
| Cross-ecosystem | OSV-Scanner | `security-pr.yml` + harness |

## Bit-reproducible notarized builds — explicitly de-scoped

**We do not target bit-identical reproducibility of the shipped, notarized macOS artifact.**

Rationale (aligned with [`plans/2026-05-30-sota-security-remediation.md`](../../plans/2026-05-30-sota-security-remediation.md)):

1. **Apple codesign + notarization** embed timestamp counters, CD hashes, and ticket-specific metadata. Two builds from identical sources diverge after `codesign --timestamp` and `notarytool submit`.
2. **Stapling** (`stapler staple`) further binds the artifact to Apple's notary response bytes.
3. **Secure timestamp authority (TSA) counters** are intentionally non-deterministic.

What we **do** pursue instead:

- **SLSA provenance** tying each release artifact to a specific Git commit, workflow run, and builder identity.
- **Cosign attestations** over DMG/ZIP/SBOM digests for downstream verification.
- **Pre-sign payload checksums** (`checksums-v*.txt`) for integrity before notarization transforms the outer container.
- Optional **pre-signing reproducibility experiments** on unsigned `.app` bundles — informative only, not a release gate.

If Apple or the community ships practical notarized-repro tooling, revisit in a dedicated ADR; until then, provenance + attestations are the SOTA bar for this product class.

## Verification commands

```bash
# Local deny sweep
./scripts/supply-chain/run-ecosystem-deny-checks.sh

# Generate SBOM + VEX locally
./scripts/generate-sbom.py --version dev --repo-root . --output /tmp/openburnbar-dev.spdx.json
python3 scripts/supply-chain/generate-vex.py --sbom /tmp/openburnbar-dev.spdx.json --output /tmp/openburnbar-dev.vex.json

# Verify cosign attestation (after release)
cosign verify-attestation --type slsaprovenance \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp 'https://github.com/.+/\.github/workflows/release\.yml@refs/tags/v.*' \
  ghcr.io/example/openburnbar@sha256:…
```

Replace the identity regexp with your org/repo when configuring external verifiers.

## Related docs

- [`PRIVILEGED_INPUT_THREAT_MODEL.md`](PRIVILEGED_INPUT_THREAT_MODEL.md) — privileged-input threat trees
- [`PRIVILEGED_SOCKET_AUTH.md`](PRIVILEGED_SOCKET_AUTH.md) — peer code-sign auth + kill switch
- [`../THREAT_MODEL.md`](../THREAT_MODEL.md) — product-wide boundaries
