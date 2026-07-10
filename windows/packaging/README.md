# OpenBurnBar — Windows packaging manifests (Phase 5 / W10)

The distribution manifests for the Windows port. These mirror the macOS release
pipeline's channel set (see [`docs/WINDOWS_PORT_MASTER_PLAN.md`](../../docs/WINDOWS_PORT_MASTER_PLAN.md)
§9.11–9.12): **MSIX + portable zip; winget + Chocolatey**, with auto-update from the
**Ed25519-pinned** release feed (parity with macOS Sparkle; the feed key is pinned
**independent** of the Authenticode/Trusted-Signing certificate).

| Path | Channel | What it is |
|------|---------|------------|
| [`msix/Package.appxmanifest`](msix/Package.appxmanifest) | MSIX | Package identity, capabilities (`runFullTrust`, internet + local-network, `graphicsCaptureProgrammatic`), and the app extensions: `windows.protocol` (`openburnbar://`), two `windows.fileTypeAssociation`s (`.burnbarchat` / `.burnbarpane`), `windows.startupTask` (launch-at-login), `windows.toastNotificationActivation`. |
| [`msix/OpenBurnBar.Packaging.wapproj`](msix/OpenBurnBar.Packaging.wapproj) | MSIX | Windows Application Packaging Project that wraps the **unpackaged** app (`../../app/OpenBurnBar.App`) into a signable MSIX without changing the app project. |
| [`msix/New-MsixPackage.ps1`](msix/New-MsixPackage.ps1) | MSIX | Release-side deterministic packager: stages an already-published unpackaged app, stamps the resolved version + architecture into `AppxManifest.xml`, copies the reviewed visual assets, and invokes the Windows SDK's `MakeAppx`. |
| [`msix/Images/`](msix/Images/) | MSIX | Committed scale-100 tile/logo assets generated from the WinUI app icon; `scripts/verify.sh` fails if any required PNG is missing or mis-sized. |
| [`portable/portable-layout.json`](portable/portable-layout.json) | Portable zip | Declarative layout (+ [`portable-layout.schema.json`](portable/portable-layout.schema.json)) for the no-installer zip: entry point, `.portable` marker, README, checksum sidecar. |
| [`portable/New-PortableZip.ps1`](portable/New-PortableZip.ps1) | Portable zip | PS7 script that stages a self-contained `dotnet publish` output into the layout, zips it, and emits the SHA256 sidecar the winget/Choco manifests + update feed consume. |
| [`winget/manifests/.../0.1.0/`](winget/manifests/i/ImagineThat/OpenBurnBar/0.1.0/) | winget | The three-file manifest set (`version` / `installer` / `defaultLocale`) in the Microsoft winget-pkgs schema **1.6.0**, for the `ImagineThat.OpenBurnBar` package. |
| [`chocolatey/openburnbar.nuspec`](chocolatey/openburnbar.nuspec) | Chocolatey | nuspec (installs the portable zip; no Authenticode dependency) + [`tools/chocolateyinstall.ps1`](chocolatey/tools/chocolateyinstall.ps1) / [`chocolateyuninstall.ps1`](chocolatey/tools/chocolateyuninstall.ps1). |
| [`scripts/verify.sh`](scripts/verify.sh) | — | Host-portable validator (XML well-formedness, winget schema rules, JSON/nuspec/PowerShell checks). |

## Identity (mirrors the macOS app)

| macOS (`project.yml` / `OpenBurnBar-Info.plist`) | Windows packaging |
|--------------------------------------------------|-------------------|
| bundle id `com.openburnbar.app` | MSIX Identity `ImagineThat.OpenBurnBar`, Publisher `CN=Imagine That, …` |
| `CFBundleURLSchemes: openburnbar` | `windows.protocol` `Name="openburnbar"` |
| exported UTType `ai.burnbar.chat-thread` | file assoc `.burnbarchat` |
| exported UTType `ai.burnbar.chat-pane` | file assoc `.burnbarpane` |
| login-item / `SMAppService` autolaunch | `windows.startupTask` (ships disabled) |
| Sparkle `SUFeedURL` + `SUPublicEDKey` (Ed25519) | pinned-feed updater in app/PAL (**not** the App-Installer auto-update) |

## Validation (macOS ceiling)

`bash windows/packaging/scripts/verify.sh` runs on any host. HARD gates: XML
well-formedness (xmllint) of the appxmanifest / wapproj / nuspec; YAML parse + winget
1.6.0 structural rules (required keys, enums, SHA256/URL patterns, cross-manifest
consistency) of the three winget files; JSON parse of the portable layout. SOFT gates
(best-effort, network/deps permitting): full JSON-Schema validation of the winget YAMLs
+ portable layout, NuGet-core XSD validation of the nuspec, and `pwsh` parse of the
PowerShell scripts.

## Deferred release finishing (honest ceiling)

The unsigned workflow-dispatch rehearsal builds x64 + ARM64 portable and MSIX artifacts on a
Windows runner. The following remain gated on the W0 procurement item (Azure Trusted Signing
certificate/profile, Store account, winget publisher — Alberto, calendar-bound):

- **Actual Authenticode signing + timestamp** (Azure Trusted Signing). `<Identity Publisher>`
  must equal the signing certificate subject before the first signed release; the unsigned
  rehearsal intentionally retains the reviewed placeholder publisher.
- **Real artifact hashes**: the winget `InstallerSha256` (per arch), the winget
  `SignatureSha256` + `PackageFamilyName`, and the Chocolatey `checksum` values are
  release-stamped placeholders here (64 zero-hex, schema-valid). `New-PortableZip.ps1`
  emits the portable `.sha256`; the signed-MSIX hashes come from `SignTool`.
- **Store / winget / Choco submission**: the Microsoft Store listing, the
  `microsoft/winget-pkgs` manifest PR, and the Chocolatey community push.
- **`winget validate` / `choco pack` / AppxManifest XSD**: the Windows-only schema
  gates that complement the macOS well-formedness checks.

See [`windows/app/DEV_HOST_RUNBOOK.md`](../app/DEV_HOST_RUNBOOK.md) for the exact
Windows build/sign/record steps.
