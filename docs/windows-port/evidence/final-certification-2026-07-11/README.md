# Windows parity certification evidence - 2026-07-11

This bundle records the final automated evidence pass after the Windows parity
implementation landed. It is a certification input, not a public-release or
physical-hardware certification claim.

## Candidate identity

- Product candidate commit: `778e735a69ea9d812db87146630223ac1a3a49d7`
- Candidate tree: `97a56caca0f60cf62ecb027f24334899d21d2f72`
- Signed release workflow: [run 29160512069](https://github.com/Imagine-That-Ai/BurnBar/actions/runs/29160512069)
- Exact-candidate hosted x64 workflow: [run 29160940577](https://github.com/Imagine-That-Ai/BurnBar/actions/runs/29160940577)
- ARM64 UTM evidence archive SHA-256: `1a276bd023f5d6078fee4501ced80a94da9ba1db0414b774fd184fb4a843c7ad`

Run 29160940577 executes from `006294ccbded766c7ac4f6d6f7116586823c0912`,
the workflow-only byte-fidelity fix later merged as PR #1520. Its disposable
checkout verified all 10,476 exported blobs with zero mismatches before the x64
foundation harness ran.

## Proven gates

### Signed distribution

Run 29160512069 completed successfully with unsigned output forbidden. It built
native x64 and ARM64 engines, signed portable binaries and both MSIX packages
with Azure Artifact Signing, verified publisher and RFC 3161 timestamps, and
produced checksums, an Ed25519 feed, SBOM, OpenVEX, and Sigstore attestations.

| Artifact | SHA-256 |
|---|---|
| `OpenBurnBar-1.0.29-win-x64.zip` | `da459032be35f81b4387f6653036694dc5bbbf8ad933951f605426ac2f93a98f` |
| `OpenBurnBar-1.0.29-win-arm64.zip` | `4b130d8eca9a5404a5f9f72ef2f1bf7f09c8e8ca07cb26a2431649d55632a8ee` |
| `OpenBurnBar-1.0.29-x64.msix` | `59edfd752e18ffcbcceb05cff8d4e6a67851a3cbab84e615e9ddaad6d35c4238` |
| `OpenBurnBar-1.0.29-arm64.msix` | `964d661defde9b9f7953295e5b60827099f5e3e4834a67109fa7a7e46f48116a` |

The workflow's checksum file and signed update-feed metadata are preserved
under `hosted-windows/`. The ARM64 MSIX is the package used by the UTM lifecycle
pass.

### ARM64 Windows foundation

The Windows 11 Pro ARM64 UTM host imported 10,475 candidate files and reported
zero byte mismatches. The solution built with zero errors. Configuration
(35/35), chat runtime (20/20), app storage (18/18), SQLCipher storage (21/21),
and chat presentation (86/86) passed. All ten storage recovery cases passed,
and the evidence secret scan reported zero findings.

The committed JSON files are metadata and summaries only. Secret plaintext and
protected key material are deliberately excluded.

### Physical iPhone companion

The mobile app built, signed, installed, and launched on Alberto's physical
iPhone 17 Pro Max. The test result contains 1,281 executions: 1,240 passed, 13
failed, and 28 skipped. This proves the physical-device compile/install/launch
gate; it does not claim a green mobile suite. The failures are preserved in
`physical-ios/physical-ios-summary.json`.

## Open certification gates

- Physical Windows 11 x64 and ARM64 hardware, including GPU/WebView2 fallback
  and measured performance.
- Manual Narrator and keyboard-only coverage, plus 150%/200% DPI, high contrast,
  reduced motion, and reduced transparency.
- Live staging OAuth, App Check/TPM, CloudVault, offline, sign-out, and
  cross-device flows.
- End-to-end Computer Use, media, call, screen-share, and malicious-file safety
  on physical Windows targets.
- Public update, rollback, Store/winget, and public release lifecycle.

Until these gates have evidence, the implementation ledger may be complete but
the release must not be described as 100% physically certified parity.
