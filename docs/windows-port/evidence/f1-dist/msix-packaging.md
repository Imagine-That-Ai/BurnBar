# Ledger row: dist-msix-signed

**What this proves:** Exact candidate `84585a2b1a` completed unsigned x64 and
ARM64 publish, ZIP packaging, Windows SDK MakeAppx packaging, checksum creation,
expanded-content SPDX generation, OpenVEX generation, and keyless Sigstore
attestation in [run 29125738592](https://github.com/Imagine-That-Ai/BurnBar/actions/runs/29125738592).
The compact machine-readable receipt is
[`ci-run-84585a2b1a.json`](ci-run-84585a2b1a.json).

**Independent checks:** all four release files matched the emitted checksum
manifest; the portable executables reported PE machine codes `0x8664` and
`0xaa64`; both MSIX manifests contained `OpenBurnBar.App.exe`, version
`1.0.29.0`, and the expected processor architecture. The SPDX 2.3 document
contained 371 packages / 370 dependency packages. All seven predicates matched
their artifact, commit, run, ref, and repository, and all seven Sigstore bundles
verified cryptographically against GitHub Actions OIDC and the public
transparency log.

**Operational residual:** this is an explicitly unsigned rehearsal, not a
release. Azure Artifact Signing / Authenticode, RFC 3161 timestamps, the pinned
Ed25519 production update feed, clean install/update/rollback on physical x64
and ARM64 devices, and Store/winget/Chocolatey publication remain open gates.
