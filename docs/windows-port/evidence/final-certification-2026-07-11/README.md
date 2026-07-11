# Windows parity certification evidence - 2026-07-11

This bundle records the final automated evidence pass after the Windows parity
implementation landed. It is a certification input, not a public-release or
physical-hardware certification claim.

## Candidate identity

- Foundation implementation candidate commit:
  `778e735a69ea9d812db87146630223ac1a3a49d7`
- Foundation candidate tree: `97a56caca0f60cf62ecb027f24334899d21d2f72`
- Corrected signed runtime candidate commit:
  `9dbcaa791794944326ce9ffb18ed4d9771f31ecc`
- Initial signed release workflow, whose integrity passed but runtime package was
  later invalidated: [run 29160512069](https://github.com/Imagine-That-Ai/BurnBar/actions/runs/29160512069)
- Registration-only hosted x64 workflow:
  [run 29162867538](https://github.com/Imagine-That-Ai/BurnBar/actions/runs/29162867538)
- Corrected signed runtime workflow:
  [run 29166970379](https://github.com/Imagine-That-Ai/BurnBar/actions/runs/29166970379),
  completed successfully from the corrected signed runtime candidate
- Exact-candidate hosted x64 workflow: [run 29160940577](https://github.com/Imagine-That-Ai/BurnBar/actions/runs/29160940577)
- ARM64 UTM evidence archive SHA-256: `1a276bd023f5d6078fee4501ced80a94da9ba1db0414b774fd184fb4a843c7ad`
- Decisive ARM64 foundation host evidence:
  `arm64-utm/foundation-host-v6/host-evidence-provenance.json`
- Corrected signed candidate ARM64 import verification: 10,477/10,477 files,
  zero mismatches, in
  `arm64-utm/foundation-host-v6/signed-candidate-import-verification.json`
- Bound evidence collector: PR #1546 commit `05e6a0bb5c`, expected and actual
  SHA-256 `8844a50251d2239d6d8a0f4120436c3f143ce6f5006bf10c498ac953ec3ed137`

The foundation commit establishes the source/product implementation baseline.
The later signed runtime candidate contains the package-resource correction and
is the only candidate this bundle treats as passing signed sustained launch.
Git ancestry and the signed-candidate import receipt bind that successor to an
exact 10,477-file ARM64 tree with zero mismatches before lifecycle validation.
The foundation commit is the successor's merge base and ancestor. Their exact
eight-file delta is confined to release workflows, candidate export/evidence
tooling, and MSIX packaging/lifecycle gates; no Windows app/product source file
differs.
The collector commit only increases the UIA window discovery allowance and is
bound independently by content hash; it is not a third product candidate.

Run 29160940577 executes from `006294ccbded766c7ac4f6d6f7116586823c0912`,
the workflow-only byte-fidelity fix later merged as PR #1520. Its disposable
checkout verified all 10,476 exported blobs with zero mismatches before the x64
foundation harness ran.

## Proven gates and invalidated evidence

### Signed distribution

Run 29160512069 completed successfully with unsigned output forbidden. It built
native x64 and ARM64 engines, signed portable binaries and both MSIX packages
with Azure Artifact Signing, verified publisher and RFC 3161 timestamps, and
produced checksums, an Ed25519 feed, SBOM, OpenVEX, and Sigstore attestations.
Those integrity and provenance results remain valid, but they did not prove the
MSIX could remain launched.

| Artifact | SHA-256 |
|---|---|
| `OpenBurnBar-1.0.29-win-x64.zip` | `da459032be35f81b4387f6653036694dc5bbbf8ad933951f605426ac2f93a98f` |
| `OpenBurnBar-1.0.29-win-arm64.zip` | `4b130d8eca9a5404a5f9f72ef2f1bf7f09c8e8ca07cb26a2431649d55632a8ee` |
| `OpenBurnBar-1.0.29-x64.msix` | `59edfd752e18ffcbcceb05cff8d4e6a67851a3cbab84e615e9ddaad6d35c4238` |
| `OpenBurnBar-1.0.29-arm64.msix` | `964d661defde9b9f7953295e5b60827099f5e3e4834a67109fa7a7e46f48116a` |

The workflow's checksum file and signed update-feed metadata are preserved
under `hosted-windows/`. The ARM64 MSIX is the package that exposed the
post-registration XAML startup failure.

Run 29162867538 then registered the signed x64 MSIX on a clean hosted Windows
runner, verified version `1.0.29.0`, `X64` architecture, publisher, and install
location, removed it and proved it absent, and registered the same identity
again. It never launched the app, so it is registration evidence only and is
preserved as `hosted-windows/signed-x64-msix-registration-lifecycle-v1.json`.

### ARM64 Windows foundation

The Windows 11 Pro ARM64 UTM host imported 10,475 candidate files and reported
zero byte mismatches. The solution built with zero errors. Configuration
(35/35), chat runtime (20/20), app storage (18/18), SQLCipher storage (21/21),
and chat presentation (86/86) passed. All ten storage recovery cases passed,
and the evidence secret scan reported zero findings.

The decisive host run then captured all 53 required scenarios: 17 process
containment/error scenarios and 14 interactive UIA scenarios in signed-in
session 1, with 94 artifacts indexed, no missing scenarios, and zero secret
findings. The exact manifest, wrapper, candidate verification, aggregate UIA
result, 34 content-matched UIA/route JSON artifacts, and redacted process trace
are committed under `arm64-utm/foundation-host-v6/`. The process trace replaces
34 signed-in profile path occurrences with `%USERPROFILE%`; its raw and
committed hashes are recorded in `host-evidence-provenance.json`. PNG captures
are intentionally omitted from Git and remain content-addressed in
`foundation-host-evidence-manifest.json`.

Secret plaintext and protected key material are deliberately excluded.

The initial ARM64 lifecycle receipt is invalid. It sampled each process about
0.1 seconds after creation, before WinUI finished loading the flyout. Repeated
later launches exited with `XamlParseException` in
`FlyoutWindow.InitializeComponent`; Application Error event 1000 reported
exception `0xc000027b`. The root cause was a missing package-root
`resources.pri` in the manually packed MSIX. The original receipt and all its
observations are preserved, with explicit invalidation metadata, as
`arm64-utm/signed-arm64-msix-lifecycle-v1-invalidated.json`.

PR #1541 now generates and inspects the package resource index and requires
clean-install and reinstall launches to remain alive and responsive for 20
seconds with no matching WER or fatal WinUI diagnostics.

Run 29166970379 completed successfully from the exact fix commit. Both MSIX
packages contain a package-root `resources.pri`; the workflow also completed
the native x64 and ARM64 engines, distribution core, Authenticode signing,
checksums, update feed, SBOM, OpenVEX, and Sigstore jobs.

| Corrected artifact | SHA-256 |
|---|---|
| `OpenBurnBar-1.0.29-win-x64.zip` | `06cbe949bb3497d572f3aef4d8f2a1045fdbde6f07f486c5bef07e9bc783f9e1` |
| `OpenBurnBar-1.0.29-win-arm64.zip` | `eba13d15b99854ab5bae482e1599c315766e7f1f854947ddbf6bdab7cc168300` |
| `OpenBurnBar-1.0.29-x64.msix` | `ac5b63a258c2151c7f1c8f3092ff54720d8c97b375efa38754a2e4a1857e0f43` |
| `OpenBurnBar-1.0.29-arm64.msix` | `7350fd248f65fd9de6eb3b2b5804508d9b47386a9fa0d9028526d70791874d8b` |

The generic `checksums-windows-v1.0.29.txt`, `latest-windows.json`, and
`windows-update-feed-v1.0.29.json` files now describe these corrected bytes.
The corresponding pre-fix metadata remains available under filenames suffixed
with `run-29160512069`; it is historical evidence and must not be promoted.

The hosted x64 lifecycle receipt passed clean install, identity validation,
20-second responsive launch, uninstall, reinstall, and a second 20-second
responsive launch with zero crash events. The exact ARM64 package was then
transferred to Windows 11 Pro ARM64 under UTM; its byte count and SHA-256
matched, its Imagine That AI LLC signature and Microsoft timestamp were valid,
and the same lifecycle passed in the signed-in interactive session with zero
crash events or fatal WinUI diagnostics. The signed runtime gate is therefore
passed for this corrected candidate on the automated hosted x64 and virtualized
ARM64 surfaces represented by these receipts.

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
- Public update, rollback, Store/winget, and public release lifecycle. The local
  signed package install, sustained launch, uninstall, reinstall, and second
  sustained launch sequence is proven separately above; public promotion and
  update-channel behavior are not.

Until these gates have evidence, the implementation ledger may be complete but
the release must not be described as 100% physically certified parity.
