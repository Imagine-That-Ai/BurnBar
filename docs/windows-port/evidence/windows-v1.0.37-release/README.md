# Windows v1.0.37 Exact Release Evidence

This packet binds the current Windows physical and private-Store certification
campaign to protected tag `windows-v1.0.37`.

## Exact candidate

- Source commit: `2757652e89440eb647d21721895fc61ec89935d3`
- Release workflow: [29650389335](https://github.com/Imagine-That-Ai/BurnBar/actions/runs/29650389335)
- Workflow conclusion: `success`
- Release artifact: `windows-release-v1.0.37`
- Release artifact outer-archive SHA-256: `c25c5c48bb8bb782559d5fdeaedf6f281f8417a56df9a9501d5f5d734953978c`
- Provenance artifact outer-archive SHA-256: `15d8bb7224074055e2660e2b87ba06f4d77fbbf57168d1af5c8f6cebc6b4e3a9`

The two outer-archive digests above are the values reported by the GitHub
artifact API; the distribution-object digests remain pinned separately below.

Every downloaded distribution object matched
`checksums-windows-v1.0.37.txt`. Azure Artifact Signing, exact Imagine That AI
LLC signer verification, RFC 3161 timestamping, x64 hosted lifecycle, native
resource-layout validation, Store identity validation, signed Ed25519 update
feed, SPDX SBOM, OpenVEX, and Sigstore provenance passed in the release run.

## Current host evidence

The exact ARM64 direct MSIX passed clean install, sustained launch, uninstall,
reinstall, and a second sustained launch under Windows 11 Pro ARM64 in UTM.
The portable ARM64 layout and sustained launch passed, and the UIA
certification rerun passed 25/25 route/scenario runs. The external evidence ZIP
is recorded in [ARM64_VM_EVIDENCE.md](ARM64_VM_EVIDENCE.md).

This is VM validation, not physical ARM64 certification. The physical Intel
x64 run for `v1.0.37` is still required. Use
[PHYSICAL_X64_RUNBOOK.md](PHYSICAL_X64_RUNBOOK.md), never the historical
`v1.0.35` runbook. Private Partner Center preparation is in
[STORE_PRIVATE_SUBMISSION_RUNBOOK.md](STORE_PRIVATE_SUBMISSION_RUNBOOK.md).

## Release boundary

The Windows port and signed beta packages are complete. A public parity-release
claim remains fail-closed until the fresh physical x64, manual
accessibility/display, authorized staging cloud, physical media/Computer Use
safety, and controlled Store/update lifecycle receipts pass. Physical ARM64 is
an explicit beta limitation until qualifying hardware is available.
