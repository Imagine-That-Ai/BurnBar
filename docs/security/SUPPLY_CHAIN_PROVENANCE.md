# Supply chain provenance (GitHub Artifact Attestations + Sigstore)

OpenBurnBar ships privileged-input capabilities. Release artifacts therefore
carry GitHub Artifact Attestations with SLSA build-provenance predicates, plus
the existing Sigstore blob bundles used by the release publication and
platform-specific evidence gates.

The GitHub attestation action is pinned to
`96278af6caaf10aea03fd8d33a09a777ca52d62f` (`actions/attest-build-provenance`
v3.2.0) in each release lane. The action records attestations in GitHub's
artifact-attestation store; the bundle is verified with `gh attestation verify`.
The companion `cosign attest-blob` bundles remain published release evidence
and are verified with the lane-specific verifier shown below.

## Artifact × attestation × verifier matrix

| Release surface | GitHub build provenance | Supplemental Sigstore bundle | Verification |
|------------------|-------------------------|------------------------------|--------------|
| macOS DMG, ZIP, and `checksums-v*.txt` | `.github/workflows/release.yml` → `actions/attest-build-provenance@96278af6caaf10aea03fd8d33a09a777ca52d62f` → `https://slsa.dev/provenance/v1` | `cosign attest-blob` bundles and predicate sidecars for the DMG, ZIP, checksums, SBOM, VEX, source archive, and update metadata | `gh attestation verify` with signer workflow `.github/workflows/release.yml`, exact tag source digest/ref, and `--predicate-type https://slsa.dev/provenance/v1`; then `scripts/ci/verify-release-attestations.sh <tag>` |
| Linux AppImage, daemon binary, Arch `.pkg.tar.zst`, Debian `.deb`, RPM `.rpm`, and Linux checksums | `.github/workflows/linux-release.yml` → `actions/attest-build-provenance@96278af6caaf10aea03fd8d33a09a777ca52d62f` → `https://slsa.dev/provenance/v1` | `cosign attest-blob` bundles for the release subjects, sidecars, and package-closure evidence | `gh attestation verify` with signer workflow `.github/workflows/linux-release.yml`; the CI lane also runs `node scripts/linux-port/verify-linux-release.mjs --candidate --phase final --version <version>` |
| Windows direct-download ZIP/MSIX, Store MSIX, and `checksums-windows-v*.txt` | `.github/workflows/openburnbar-release-windows.yml` → `actions/attest-build-provenance@96278af6caaf10aea03fd8d33a09a777ca52d62f` → `https://slsa.dev/provenance/v1` | `cosign attest-blob` bundles for SBOM, VEX, ZIP/MSIX artifacts, checksums, and Windows domain-core evidence | `gh attestation verify` with signer workflow `.github/workflows/openburnbar-release-windows.yml`; inspect a supplemental bundle with `cosign verify-blob-attestation` and the workflow's exact certificate identity |
| SPDX SBOM and OpenVEX sidecars on each release lane | The sidecars are covered by the lane's release workflow evidence, but are not subjects of the three package-focused action steps above | `cosign attest-blob` bundle plus the corresponding predicate sidecar | Use the lane's release evidence verifier and confirm the sidecar digest is present in the release checksums/closure; do not treat VEX as a substitute for provenance |

The matrix distinguishes two storage and verification surfaces deliberately:
`gh attestation verify` checks the GitHub-hosted SLSA attestation, while the
lane-specific verifier checks the separately published Sigstore bundle and its
digest-bound predicate. Passing one does not silently stand in for the other.

### Legacy predicate sunset

The macOS release verifier accepts the previously published
`https://openburnbar.dev/attestations/release-artifact/v1` predicate only
through `v1.0.40+repair.37`. It rejects that identity for
`v1.0.40+repair.38` and every later tag; `https://slsa.dev/provenance/v1` is
the only accepted macOS release predicate after the sunset. Unknown predicate
identities and bundles whose signed statement type differs from the sidecar
are rejected. Linux and Windows platform predicates are separate contracts
and are not accepted as macOS release predicates.

This repository proves the wiring, action pin, permissions, verifier behavior,
and sunset boundary. It does **not** claim end-to-end provenance for a release
until a successful post-change tagged release has produced and passed the
exact `gh attestation verify` commands in this matrix.

## What we attest

| Artifact | Provenance | Attestation |
|----------|------------|-------------|
| macOS DMG + ZIP | GitHub Actions OIDC → SLSA build-provenance predicate | GitHub Artifact Attestation plus a published `cosign attest-blob` bundle |
| Linux AppImage + native packages | GitHub Actions OIDC → SLSA build-provenance predicate | GitHub Artifact Attestation plus platform release-closure and `cosign attest-blob` evidence |
| Windows ZIP + MSIX packages | GitHub Actions OIDC → SLSA build-provenance predicate | GitHub Artifact Attestation plus `cosign attest-blob` evidence |
| SPDX SBOM | Same workflow job as its release build | `cosign attest-blob` bundle + release evidence asset |
| Checksums file | SHA-256/SHA-512 entries for release subjects | GitHub Artifact Attestation where listed above + `cosign attest-blob` bundle |
| OpenVEX sidecar | Generated from the release SBOM | `cosign attest-blob` bundle + release evidence asset |

Workflows:

- [`.github/workflows/release.yml`](../../.github/workflows/release.yml) —
  builds macOS artifacts, creates GitHub SLSA attestations for the DMG, ZIP,
  and checksums, and publishes supplemental provenance evidence.
- [`.github/workflows/linux-release.yml`](../../.github/workflows/linux-release.yml)
  — creates GitHub SLSA attestations for AppImage/native packages and Linux
  checksums, then runs the signed package-closure verifier.
- [`.github/workflows/openburnbar-release-windows.yml`](../../.github/workflows/openburnbar-release-windows.yml)
  — creates GitHub SLSA attestations for Windows ZIP/MSIX/checksum subjects and
  publishes the platform's supplemental provenance evidence.
- [`.github/workflows/supply-chain-provenance.yml`](../../.github/workflows/supply-chain-provenance.yml)
  — standalone SBOM/VEX generation and provenance verification
  (`workflow_dispatch`); it does not fabricate release artifacts.
- [`.github/workflows/openburnbar-pr-harness.yml`](../../.github/workflows/openburnbar-pr-harness.yml)
  — PR SBOM + VEX + ecosystem deny checks.

## OIDC + cosign (keyless)

Release jobs request only the permissions needed by their lane:

```yaml
permissions:
  contents: read
  id-token: write
  attestations: write
```

`actions/attest-build-provenance` uses GitHub's OIDC identity and stores the
SLSA attestation in GitHub. The supplemental `cosign attest-blob` path also
uses keyless signing; no long-lived signing key is stored in the repository.
Operators may additionally configure `RELEASE_SIGNING_KEY` (GPG) for checksum
`.asc` files — that path is legacy-compatible, not a substitute for either
provenance attestation.

## SBOM + VEX on every PR and release

| Surface | SBOM | VEX |
|---------|------|-----|
| PR | `scripts/generate-sbom.py` from tracked SwiftPM, npm, Cargo, and Android/Gradle manifests | `scripts/supply-chain/generate-vex.py` |
| Release tag | Full SPDX via `scripts/generate-sbom.py` from the same tracked dependency surface | OpenVEX sidecar uploaded with release evidence |

VEX is a **triage artifact**: default generation marks `not_affected` with a
placeholder statement when no exceptions are filed. Update VEX when `npm audit`,
OSV-Scanner, or `cargo-deny` findings are accepted with documented rationale.

## Ecosystem deny checks

[`scripts/supply-chain/run-ecosystem-deny-checks.sh`](../../scripts/supply-chain/run-ecosystem-deny-checks.sh)
runs:

| Ecosystem | Tool | Config |
|-----------|------|--------|
| Rust (`crates/openburnbar-iroh`) | `cargo-deny` | [`crates/openburnbar-iroh/deny.toml`](../../crates/openburnbar-iroh/deny.toml) |
| Node (functions + extension) | `npm audit --audit-level=high` | lockfiles |
| SBOM inventory | SPDX package URLs | tracked SwiftPM, npm, Cargo, and Android/Gradle manifests |
| Cross-ecosystem | OSV-Scanner | `security-pr.yml` + harness |

## Bit-reproducible notarized builds — explicitly de-scoped

**We do not target bit-identical reproducibility of the shipped, notarized
macOS artifact.**

Rationale (aligned with
[`plans/2026-05-30-sota-security-remediation.md`](../../plans/2026-05-30-sota-security-remediation.md)):

1. Apple codesign + notarization embed timestamp counters, CD hashes, and
   ticket-specific metadata. Two builds from identical sources diverge after
   `codesign --timestamp` and `notarytool submit`.
2. Stapling (`stapler staple`) further binds the artifact to Apple's notary
   response bytes.
3. Secure timestamp authority (TSA) counters are intentionally
   non-deterministic.

What we **do** pursue instead:

- GitHub SLSA attestations tying each selected release subject to a specific
  Git commit, workflow run, builder identity, and file digest.
- Supplemental Sigstore blob attestations for release artifacts, SBOM/VEX,
  checksums, source/update metadata, and platform evidence.
- Pre-sign payload checksums (`checksums-v*.txt`) for integrity before
  notarization transforms the outer container.
- Optional pre-signing reproducibility experiments on unsigned `.app` bundles
  — informative only, not a release gate.

If Apple or the community ships practical notarized-repro tooling, revisit in a
dedicated ADR; until then, provenance + attestations are the SOTA bar for this
product class.

## Verification commands

```bash
# Local deny sweep
./scripts/supply-chain/run-ecosystem-deny-checks.sh

# Generate SBOM + VEX locally
./scripts/generate-sbom.py --version dev --repo-root . --output /tmp/openburnbar-dev.spdx.json
python3 scripts/supply-chain/generate-vex.py --sbom /tmp/openburnbar-dev.spdx.json --output /tmp/openburnbar-dev.vex.json

# Verify the GitHub-hosted SLSA attestation for one exact release subject.
gh attestation verify "$ASSET" \
  --repo Imagine-That-Ai/BurnBar \
  --signer-workflow Imagine-That-Ai/BurnBar/.github/workflows/release.yml \
  --source-digest "$RELEASE_COMMIT" \
  --source-ref "refs/tags/$TAG" \
  --signer-digest "$RELEASE_COMMIT" \
  --cert-oidc-issuer https://token.actions.githubusercontent.com \
  --deny-self-hosted-runners \
  --predicate-type https://slsa.dev/provenance/v1

# Verify the published macOS Sigstore blob bundles for all required subjects.
scripts/ci/verify-release-attestations.sh vX.Y.Z

# Linux CI release-closure verification.
node scripts/linux-port/verify-linux-release.mjs --candidate --phase final --version X.Y.Z

# For one-off macOS asset inspection, use SLSA after the sunset.
cosign verify-blob-attestation \
  --bundle OpenBurnBar-X.Y.Z-macOS.dmg.sigstore.json \
  --type https://slsa.dev/provenance/v1 \
  --certificate-identity https://github.com/Imagine-That-Ai/BurnBar/.github/workflows/release.yml@refs/tags/vX.Y.Z \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  OpenBurnBar-X.Y.Z-macOS.dmg
```

For a release at or before `v1.0.40+repair.37`, the macOS compatibility
verifier may be run against its historical
`https://openburnbar.dev/attestations/release-artifact/v1` sidecars. Do not
use that predicate for a later tag.

Do not check the SOTA release-attestation signoff box until the verifier exits
0 against the exact release tag being claimed and the GitHub-hosted
attestation is independently present.

## Related docs

- [`PRIVILEGED_INPUT_THREAT_MODEL.md`](PRIVILEGED_INPUT_THREAT_MODEL.md) —
  privileged-input threat trees
- [`PRIVILEGED_SOCKET_AUTH.md`](PRIVILEGED_SOCKET_AUTH.md) — peer code-sign auth
  + kill switch
- [`../THREAT_MODEL.md`](../THREAT_MODEL.md) — product-wide boundaries
