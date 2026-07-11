# Ledger row: dist-msix-signed

**Unsigned rehearsal:** Exact candidate `84585a2b1a` completed unsigned x64 and
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

**Signed evidence run:** Exact candidate `29b01c27a9` completed Azure Artifact
Signing / Authenticode for OpenBurnBar-owned portable binaries and both MSIX
packages in [run 29135662853](https://github.com/Imagine-That-Ai/BurnBar/actions/runs/29135662853).
The workflow verified 56 portable signatures and both MSIX signatures with
`Get-AuthenticodeSignature`, requiring `Valid` status, the expected signer
subject, and an RFC 3161 timestamp certificate. It finalized checksums after all
signing mutations, signed the Ed25519-pinned update feed, generated the SPDX
SBOM and OpenVEX sidecar, and emitted 10 keyless Sigstore bundles. The compact
machine-readable receipt is
[`ci-run-29b01c27a9-signed.json`](ci-run-29b01c27a9-signed.json).

**Post-download checks:** the downloaded `windows-release-v1.0.29` artifact
passed `shasum -a 256 -c checksums-windows-v1.0.29.txt` for the x64/ARM64 zips
and x64/ARM64 MSIX packages. The downloaded
`windows-update-feed-v1.0.29.json` verified under the pinned public key with
`verify-feed: all 2 entr(y/ies) authenticated under the pinned key`. All 10
downloaded predicates bind to commit `29b01c27a9` and run `29135662853`.

**Operational residual:** the signed run proves the release pipeline, signing
profile, update-feed signing, and supply-chain evidence path. It is not yet a
public release tag. Clean install, update, rollback, uninstall, and reinstall
remain separate certification gates on physical x64 and ARM64 Windows devices;
Store, winget, and Chocolatey publication remain external release operations.
