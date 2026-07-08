# Windows release runbook (Phase 5 · signed distribution)

The pipeline is [`.github/workflows/openburnbar-release-windows.yml`](../../.github/workflows/openburnbar-release-windows.yml).
It mirrors the **shape** of the macOS release (`.github/workflows/release.yml`) — build → sign →
package → sign the update feed → SBOM + OpenVEX + Sigstore — adapted to Windows.

## Trigger

- Push a `windows-v<X.Y.Z>` tag (e.g. `windows-v1.0.28`), **after** bumping the app manifest
  version (the `portable-verify` job enforces version consistency at tag time), **or**
- `workflow_dispatch` with a `version` input.

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

The cert-dependent steps are gated on these secrets and emit a `::warning:: deferred` when unset,
so the workflow is a faithful production pipeline that no-ops until the **W0** cert lands.

## Update-key management

The pinned update key is generated **offline, once**:

```
dotnet run --project windows/dist/OpenBurnBar.Dist.UpdateFeed.Tool -- gen-key
```

- Store `privateKeyBase64` as the `WINDOWS_UPDATE_SIGNING_KEY` secret (release-only).
- Pin `publicKeyBase64` into the shipped app as the trusted update key (see
  `OpenBurnBar.Dist.UpdateFeed.PinnedUpdateKey`). An all-zero placeholder pin is **rejected**
  (fail-closed), so a build that forgets to inject the real pin trusts *no* updates.

The release only needs the private secret — it recovers the public pin with
`derive-pubkey --private-key-env WINDOWS_UPDATE_SIGNING_KEY` and self-verifies the feed under it.

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

- Real MSIX/EXE build + Authenticode signing (`azure/trusted-signing-action`).
- winget manifest + Microsoft Store submission (a follow-up channel on top of the signed zip).
- Bumping `windows/app/OpenBurnBar.App/app.manifest` `assemblyIdentity version` to the release
  version at tag time (the version-consistency gate enforces this once the tag is cut).
