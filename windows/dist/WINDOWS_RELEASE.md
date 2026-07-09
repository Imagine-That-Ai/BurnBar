# Windows release runbook (Phase 5 · signed distribution)

The pipeline is [`.github/workflows/openburnbar-release-windows.yml`](../../.github/workflows/openburnbar-release-windows.yml).
It mirrors the **shape** of the macOS release (`.github/workflows/release.yml`) — build → sign →
package → sign the update feed → SBOM + OpenVEX + Sigstore — adapted to Windows.

## Trigger

- Push a `windows-v<X.Y.Z>` tag (e.g. `windows-v1.0.28`), **after** bumping the app manifest
  version (the `portable-verify` job enforces version consistency at tag time), **or**
- `workflow_dispatch` with a `version` input.

Manual dispatch has an `allow_unsigned` switch for Windows-runner build/package validation only. It
lets the workflow publish the WinUI app, stage portable zips, and try MSIX packaging up to the
signing boundary without Authenticode or update-feed signing. It is rejected for `windows-v*` tag
releases: real tags must have Azure Trusted Signing plus the pinned update-feed key configured.

## Jobs

1. **resolve-release** — derive `X.Y.Z` from the tag/input.
2. **portable-verify** *(ubuntu, always runs)* — the security kernel proof: `dotnet test` over
   `windows/tests/dist`, an end-to-end signer round-trip (good pin verifies, wrong pin fails
   closed), `xmllint` on the props, and `verify-version-consistency.sh` with
   `OPENBURNBAR_REQUIRE_CURRENT_WINDOWS_VERSION=1`.
3. **build-sign** *(windows-latest)* — `dotnet publish` the WinUI app for `win-x64` + `win-arm64`,
   **Authenticode-sign** via Azure Trusted Signing, package zips + checksums, then **sign the
   update feed** with the pinned Ed25519 key and self-verify it.
4. **supply-chain** *(ubuntu)* — SPDX **SBOM** over the artifacts, **OpenVEX** sidecar, and keyless
   **Sigstore** (`cosign attest-blob`) provenance over every artifact.

## Authenticode vs. macOS notarization — the honest difference

macOS **notarizes** then **staples** a ticket onto the DMG *after the fact*. **Authenticode has no
staple analog.** Instead it embeds an **RFC-3161 timestamp countersignature at sign time**, so the
signature remains valid after the signing cert expires — there is nothing to staple later. The
pipeline therefore signs **and timestamps in one step** (`timestamp-rfc3161`) and never "staples".

## Secrets (named; never hardcoded)

| Secret | Purpose |
| --- | --- |
| `WINDOWS_CODESIGN_ENDPOINT` | Azure Trusted Signing endpoint (region URL) |
| `WINDOWS_CODESIGN_ACCOUNT_NAME` | Trusted Signing account name |
| `WINDOWS_CODESIGN_CERT_PROFILE_NAME` | Certificate profile name |
| `WINDOWS_CODESIGN_AZURE_TENANT_ID` | Azure AD tenant (auth) |
| `WINDOWS_CODESIGN_AZURE_CLIENT_ID` | Service-principal client id (auth) |
| `WINDOWS_CODESIGN_AZURE_CLIENT_SECRET` | Service-principal secret (auth) |
| `WINDOWS_UPDATE_SIGNING_KEY` | **base64 of the 32-byte Ed25519 private seed** — the pinned update key's private half. Independent of Authenticode. |

| Variable | Purpose |
| --- | --- |
| `WINDOWS_UPDATE_PUBLIC_KEY` | The matching public key (`publicKeyBase64`) the updater pins; release CI confirms it matches `WINDOWS_UPDATE_SIGNING_KEY`. |

The signed-release path is fail-closed. `scripts/ci/verify-windows-release-signing-preflight.sh`
runs before build/signing and exits with a specific error if the Azure identity validation is still
pending (`WINDOWS_CODESIGN_CERT_PROFILE_NAME` missing), if the Trusted Signing secrets are partial,
if `WINDOWS_UPDATE_SIGNING_KEY` is absent, or if `WINDOWS_UPDATE_PUBLIC_KEY` is absent. The only
path that can continue unsigned is an explicit manual `allow_unsigned` dry-run, and that path never
applies to `windows-v*` tag releases.

## Update-key management

The pinned update key is generated **offline, once**:

```
dotnet run --project windows/dist/OpenBurnBar.Dist.UpdateFeed.Tool -- gen-key
```

- Store `privateKeyBase64` as the `WINDOWS_UPDATE_SIGNING_KEY` secret (release-only).
- Store `publicKeyBase64` as the `WINDOWS_UPDATE_PUBLIC_KEY` repo variable and pin that same value
  into the shipped app as the trusted update key (see `OpenBurnBar.Dist.UpdateFeed.PinnedUpdateKey`).
  An all-zero placeholder pin is **rejected**
  (fail-closed), so a build that forgets to inject the real pin trusts *no* updates.

The release only needs the private secret — it recovers the public pin with
`derive-pubkey --private-key-env WINDOWS_UPDATE_SIGNING_KEY`, checks it equals
`WINDOWS_UPDATE_PUBLIC_KEY`, and self-verifies the feed under it.

## macOS ↔ Windows parity

| Concern | macOS | Windows (this lane) |
| --- | --- | --- |
| Code signing | Developer-ID codesign | Authenticode (Azure Trusted Signing) |
| Post-sign ticket | notarize + **staple** | RFC-3161 timestamp at sign time (**no staple**) |
| Update authenticity | Sparkle EdDSA + pinned `SUPublicEDKey` | pinned Ed25519 over a canonical descriptor (`WINDOWS_UPDATE_SIGNING_KEY`) |
| Content integrity | Sparkle signs the DMG bytes | signed descriptor binds the artifact `sha256` (+ url/size/version/critical) |
| Library validation | hardened-runtime library validation | R19 hardening trio ([`DLL_HARDENING.md`](DLL_HARDENING.md)) |
| Supply chain | SBOM + OpenVEX + Sigstore | SBOM + OpenVEX + Sigstore (same tools) |

## Deferred (needs the W0 cert + Windows runner)

- Real signed MSIX/EXE release (`azure/trusted-signing-action`) until Azure identity validation is
  accepted and `WINDOWS_CODESIGN_CERT_PROFILE_NAME` is set. Unsigned manual dry-runs can still prove
  the build/package path up to that boundary.
- winget manifest + Microsoft Store submission (a follow-up channel on top of the signed zip).
- Bumping `windows/app/OpenBurnBar.App/app.manifest` `assemblyIdentity version` to the release
  version at tag time (the version-consistency gate enforces this once the tag is cut).
