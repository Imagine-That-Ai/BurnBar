# Windows v1.0.35 Exact-Candidate Release Evidence

This directory records independent verification of the corrected signed
Windows candidate produced from protected tag `windows-v1.0.35`. It closes the
automated exact-candidate release gate. It is not physical Windows, staging, or
Store lifecycle certification.

## Candidate identity

- Source commit: `2cfa9db885dafef7f1f451a9e05a8ee775351d44`
- Pull request: [#1832](https://github.com/Imagine-That-Ai/BurnBar/pull/1832)
- Protected tag: `windows-v1.0.35`
- Release workflow: [run 29557726093](https://github.com/Imagine-That-Ai/BurnBar/actions/runs/29557726093)
- Workflow event/ref: `push` / `refs/tags/windows-v1.0.35`
- Workflow conclusion: `success`
- Direct-download signer: `CN=Imagine That AI LLC, O=Imagine That AI LLC, L=Little Rock, S=Arkansas, C=US`

## Independent verification

- The release and provenance artifact archives matched GitHub's SHA-256
  digests `8d6dba18dbce4cc153d21482447d19f824c12beaf1a9af6c0f29af175b44b702`
  and `c4747bd563da998fa1b45660465828a18da3db4e0a4b132d82494d064a1fd9a3`.
- Every entry in `checksums-windows-v1.0.35.txt` matched the downloaded object.
- Both portable ZIPs and both direct MSIX packages passed the native-engine and
  public-production domain-core validators with the Core and Kernel Swift
  resource bundles present and manifest-bound.
- Both Store MSIX packages contain the reserved Partner Center identity and
  both resource bundles, and omit `AppxSignature.p7x` as required before Store
  ingestion.
- Both update-feed entries authenticated under the repository's pinned Ed25519
  key and matched the downloaded portable ZIP hashes and sizes.
- All 18 Sigstore bundles verified with `cosign v3.1.1` under the exact release
  workflow identity, GitHub Actions issuer, repository, tag ref, workflow SHA,
  and `push` trigger. Every predicate matched its object's SHA-256 and size.
- The SPDX 2.3 SBOM contains 925 packages and 7,051 relationships. The OpenVEX
  0.2 document contains one statement.
- The hosted signed x64 lifecycle passed clean install, a responsive 20-second
  launch with zero crash events, uninstall, reinstall, and a second responsive
  20-second launch with zero crash events.

The machine-readable record is
[`exact-signed-artifacts-2cfa9db885.json`](exact-signed-artifacts-2cfa9db885.json).
The physical Intel handoff is [`PHYSICAL_X64_RUNBOOK.md`](PHYSICAL_X64_RUNBOOK.md).

## Physical performance gate

The physical handoff is pinned to independent harness commit
`f44ad39aee2129016a931a9bf40a913f2138fc4e`. That harness promotes the reviewed
Windows performance proposal into the active, machine-readable release contract
at `scripts/windows-port/release-performance-budgets.json` (SHA-256
`779abf7596911f8d255e0bc82e490e47c025ca3e4ef24842c65107081291f926`).
A performance receipt cannot pass from prose assertions alone: it must bind the
exact budget, report all 18 numeric measurements with required sample and
duration floors, attach hashed raw evidence, and survive independent threshold
re-evaluation. The older evidence-namespace proposal remains historical and is
not consumed by the validator.

## Certification boundary

This record does not satisfy physical x64 performance, physical ARM64, manual
Narrator/keyboard/DPI/high-contrast, live staging OAuth/App Check/CloudVault,
physical media/Computer Use safety, or controlled Store/update lifecycle gates.
Physical ARM64 remains an explicit beta limitation until qualifying hardware is
available. No Store submission, public update-feed publication, production
change, or broad rollout was performed by this verification.
