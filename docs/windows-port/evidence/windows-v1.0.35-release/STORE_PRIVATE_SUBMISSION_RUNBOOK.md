# Windows v1.0.35 Private Microsoft Store Submission

This runbook prepares the first non-public Microsoft Store submission for the
exact signed-source candidate at tag `windows-v1.0.35`. It does not authorize a
public listing, production rollout, package flight, or update-feed publication.

Microsoft documents that packaged MSIX desktop apps support private audience
distribution and package flighting. A package flight can be created only after
the app has a published non-flighted submission, so the first controlled step is
a **Private audience** submission restricted to a reviewed known-user group:

- [Win32 Store distribution options](https://learn.microsoft.com/en-us/windows/apps/distribute-through-store/how-to-distribute-your-win32-app-through-microsoft-store)
- [Known user groups](https://learn.microsoft.com/en-us/windows/apps/publish/create-known-user-groups)
- [Package flights](https://learn.microsoft.com/en-us/windows/apps/publish/package-flights)
- [Store categories and subcategories](https://learn.microsoft.com/en-us/windows/apps/publish/publish-your-app/msi/categories-and-subcategories)

## Authorization boundary

Before selecting **Start submission**, obtain explicit operator authorization
that names all of the following:

- Store product `BurnBar` / `9PKMSDP99CJ6`.
- Exact version `1.0.35.0` and source commit
  `2cfa9db885dafef7f1f451a9e05a8ee775351d44`.
- **Private audience**, never Public audience.
- The known-user group and every Microsoft-account email in it.
- Permission to upload both exact Store MSIX files below.
- Permission to submit the private build for Microsoft certification.

Starting a draft, creating a known-user group, uploading a package, and
submitting for certification each change external Partner Center state. Stop at
the corresponding boundary when the authorization does not name that action.
Never infer public-release authorization from private-test authorization.

## Exact Partner Center identity

| Field                  | Required value                            |
| ---------------------- | ----------------------------------------- |
| Product name           | `BurnBar`                                 |
| Store ID               | `9PKMSDP99CJ6`                            |
| Package identity name  | `ImagineThatAiLLC.BurnBar`                |
| Publisher              | `CN=5AE4835A-8FC9-48CF-9453-81F465AD2216` |
| Publisher display name | `Imagine That Ai LLC`                     |
| Package family name    | `ImagineThatAiLLC.BurnBar_txkpd5gwvjf3t`  |
| Version                | `1.0.35.0`                                |

The generated machine-readable packet is
`store-submission-v1.0.35.json`. Reconcile every displayed Partner Center value
against it before upload. A case or identity mismatch is a hard stop.

## Exact packages

Upload both packages from the same release artifact. Microsoft Store selects
the compatible architecture for each device:

| Architecture | File                                  | SHA-256                                                            |     Bytes |
| ------------ | ------------------------------------- | ------------------------------------------------------------------ | --------: |
| x64          | `OpenBurnBar-1.0.35-store-x64.msix`   | `a5fe60b3b0816f4b59482031e9e139725741665db0e2fd2150054a0f3f804d64` | 233252966 |
| ARM64        | `OpenBurnBar-1.0.35-store-arm64.msix` | `eafc14b7a9d6b408d7ce1cf9f82228228d878c2ae416670d70de94fe797ece2c` | 227534083 |

These packages are intentionally unsigned. Microsoft Store is the final signer.
Do not upload the direct-download MSIX files and do not Authenticode-sign the
Store-identity packages. Partner Center accepts `.msix` uploads and validates
each package before the submission can proceed:

- [Upload MSIX packages](https://learn.microsoft.com/en-us/windows/apps/publish/publish-your-app/msix/upload-app-packages)

Before upload, independently run `Get-FileHash -Algorithm SHA256` on both files
and retain the output in the Store lifecycle evidence directory.

## Submission fields

Use these values unless Partner Center presents a more restrictive required
field. Do not invent policy or age-rating answers.

| Surface         | Value                                     |
| --------------- | ----------------------------------------- |
| Pricing         | Free                                      |
| Visibility      | Private audience                          |
| Discoverability | Only the authorized known-user group      |
| Category        | Developer tools                           |
| Subcategory     | Utilities                                 |
| Privacy policy  | `https://burnbar.ai/legal/privacy-policy` |
| Support         | `https://burnbar.ai/support`              |
| Terms           | `https://burnbar.ai/legal/terms`          |
| Website         | `https://burnbar.ai`                      |

Market selection, organizational licensing, certification notes, and any
schedule must be reviewed at action time. Do not enable public discoverability,
automatic public promotion, gradual public rollout, or a public acquisition
date during the private certification campaign.

### Short description

> One bar to watch, steer, and remember every coding-agent session.

### Full description

> BurnBar is a Windows companion for AI coding agents. It watches Claude Code,
> Codex, Cursor, and other agent sessions from a native tray flyout, keeps usage
> and provider quota in view, remembers context across sessions, and helps you
> continue work across desktop and mobile devices. Local data is encrypted,
> cloud sync is end-to-end encrypted, sensitive actions require explicit
> approval, and the direct-download channel verifies updates with a separately
> pinned Ed25519 key.

### Feature list

- Live coding-agent sessions, usage, quota, and cost in the Windows tray.
- Searchable session history, projects, memory, chat, and mission workflows.
- Explicit approvals, audit integrity, and panic-stop controls for Computer Use.
- End-to-end encrypted device pairing and cloud synchronization.
- Native x64 and ARM64 packages with Windows accessibility and theme support.

### Search terms

`AI`, `coding agent`, `Claude`, `Codex`, `Cursor`, `developer tools`, `usage`,
`quota`, `productivity`, `tray`

## Listings and screenshots

At least one desktop screenshot is required. Microsoft recommends at least four;
desktop screenshots must be PNG files at least 1366 by 768 pixels and no larger
than 50 MB:

- [Store screenshots and images](https://learn.microsoft.com/en-us/windows/apps/publish/publish-your-app/msix/screenshots-and-images)

Capture four clean Windows screenshots from the exact x64 package during the
physical certification run:

1. Tray flyout with live agent usage and quota.
2. Dashboard or Insights with real, redacted test data.
3. Session/chat or mission workflow with no private prompt content.
4. Settings/device safety surface showing native Windows presentation.

Use 100% DPI at 1920 by 1080 or larger. Keep the app crisp and fully visible;
exclude desktop clutter, unrelated windows, notifications, account emails,
tokens, filesystem paths, device identifiers, and production data. Preserve the
raw captures in physical evidence, scan them for secrets, then export separate
listing copies. Do not use macOS screenshots for the Windows listing.

## Age rating and declarations

Complete the Partner Center questionnaire from observed product behavior. The
app includes network communication, user-authored content, AI-provider output,
optional cross-device messaging/media, and explicitly approved Computer Use.
Answer every question literally and retain the generated rating receipt. Do not
choose a lower rating to improve reach.

Review package capability declarations and certification notes against the
exact Store manifest. Explain that sensitive desktop input is user-approved and
that Store packages omit direct-download update metadata. Do not claim physical
ARM64 certification; describe ARM64 hardware coverage as an explicit beta
limitation.

## Controlled lifecycle sequence

After Microsoft certifies and publishes the private-audience submission, use the
physical x64 laptop while signed into an authorized Microsoft account:

1. Prove Store discovery is limited to the known-user group.
2. Install from Store, launch, and hold responsive operation for 20 seconds.
3. Exercise launch, protocol, file, toast, startup, and single-instance routes.
4. Prove repair, uninstall, reinstall, and state preservation behavior.
5. Publish only an explicitly authorized private successor package to prove
   upgrade and recovery behavior.
6. Prove valid, tampered, downgrade, and offline direct-feed behavior separately.
7. Verify Store and direct-download identity coexistence matches the documented
   channel contract.
8. Verify winget eligibility without opening a public manifest PR.

Record all 14 canonical `store-update-lifecycle` assertions through
`new-release-certification-supplemental-receipt.ps1`. Every assertion needs raw,
hashed evidence from the exact candidate and device. A draft submission,
successful package upload, or Microsoft certification result alone is not a
Store/update lifecycle PASS.

## Evidence return

Return and preserve:

- Explicit private-submission authorization and known-user-group membership.
- Partner Center product/submission IDs and timestamps.
- Uploaded package names, byte counts, and independently measured hashes.
- Validation and Microsoft certification results.
- Private Store URLs or acquisition identifiers, redacted where necessary.
- Physical install/update/repair/rollback/uninstall/reinstall observations.
- Activation, feed-rejection, coexistence, and winget evidence.
- Final supplemental receipt path, SHA-256, and validator output.

No Store evidence may contain credentials, access tokens, private account data,
or an unrestricted acquisition link.
