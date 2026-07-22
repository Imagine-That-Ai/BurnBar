# Windows v1.0.31 Exact-Head Release Evidence

This directory records independent verification of the signed Windows release
candidate produced from the protected `windows-v1.0.31` tag. It is supply-chain
and hosted-lifecycle evidence, not physical Windows certification.

## Candidate identity

- Source commit: `9a280a7d36c52276bba083e6d6906a31d698bee1`
- Protected tag: `windows-v1.0.31`
- Release workflow: [run 29423558731](https://github.com/Imagine-That-Ai/BurnBar/actions/runs/29423558731)
- Workflow event/ref: `push` / `refs/tags/windows-v1.0.31`
- Workflow conclusion: `success`
- Signing identity: `CN=Imagine That AI LLC, O=Imagine That AI LLC, L=Little Rock, S=Arkansas, C=US`

## Independent verification

- All six entries in `checksums-windows-v1.0.31.txt` matched the downloaded
  release files.
- Both portable layouts contain the Swift resource bundle and passed the native
  engine and public-production domain-core layout validators.
- Both update-feed entries verified under the public key pinned in the shipped
  application.
- All 15 Sigstore bundles verified with `cosign v3.1.1` under the release
  workflow's exact tag identity and GitHub Actions OIDC issuer. Each detached
  predicate matched the predicate in its DSSE bundle.
- The SPDX 2.3 SBOM is structurally valid and contains 617 packages and 4,573
  relationships. The OpenVEX 0.2 document is structurally valid and contains
  one `not_affected` statement.
- The signed x64 MSIX lifecycle receipt passed clean install, a responsive
  20-second launch with zero crash events, uninstall, reinstall, and a second
  responsive 20-second launch with zero crash events.

The machine-readable record is
[`exact-signed-artifacts-9a280a7d36.json`](exact-signed-artifacts-9a280a7d36.json).
The exact physical Intel handoff is
[`PHYSICAL_X64_RUNBOOK.md`](PHYSICAL_X64_RUNBOOK.md).

## Certification boundary

This record does not satisfy physical x64 or ARM64 performance, manual
Narrator/keyboard/DPI/high-contrast, live staging OAuth/App Check/CloudVault,
physical media/Computer Use safety, or public Store/update lifecycle gates.
Those gates require fresh evidence from their declared surfaces. Physical
ARM64 remains an explicit beta limitation until qualifying hardware is
available.
