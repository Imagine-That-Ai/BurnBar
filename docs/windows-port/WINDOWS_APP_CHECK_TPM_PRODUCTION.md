# Windows TPM App Check production path

**Status:** protocol and production code are implemented. Deployment plus real
vTPM/physical-TPM certification remain external gates and must not be inferred
from portable tests.

## Trust path

1. The signed-in Windows client calls `issueWindowsAppCheckChallenge` with its
   Firebase ID token and exact App Check app ID.
2. The callable stores a two-minute challenge in Firestore. Only a SHA-256 hash
   of the nonce is persisted.
3. `TpmAttestationProducer` uses the Microsoft Platform Crypto Provider to create
   `NCryptCreateClaim(NCRYPT_CLAIM_PLATFORM)` over that server nonce. It sends the
   raw claim and the public CNG blob for the non-exportable TPM-backed key.
4. `mintWindowsAppCheckToken` calls the configured HTTPS verifier service. The
   service imports the public key and executes `NCryptVerifyClaim` on Windows.
5. Functions checks the verifier response is bound to the authenticated UID,
   exact app ID, challenge ID, and nonce, then consumes the Firestore challenge
   transactionally. Replays cannot mint.
6. Firebase Admin mints the custom App Check token. The Windows credential
   provider attaches it as `X-Firebase-AppCheck`; `submitDomainCoreShadowSamples`
   and other enforced callables retain their existing App Check gate.

Cloud Functions never parses or approximates the opaque Microsoft claim on
Linux. The verifier must run on Windows Server 2019 or newer: the
`NCRYPT_CLAIM_PLATFORM` claim type requires the Windows 10 RS5 generation of
the CNG API.

This is intentionally the existing `windows_lower_trust` device class: it proves
the nonce was answered by a TPM-backed installation key, not a measured hash of
the running executable. High-risk owner actions remain behind their stronger
attestation/device-proof gates; this custom token does not upgrade Windows into
the Apple App Attest trust class.

## Required configuration

Windows app:

- `OPENBURNBAR_GOOGLE_OAUTH_CLIENT_ID`
- `OPENBURNBAR_FIREBASE_WEB_API_KEY`
- `OPENBURNBAR_APPCHECK_APP_ID`

Cloud Functions:

- `WINDOWS_APP_CHECK_APP_ID` (same Firebase app ID)
- `APP_CHECK_ALLOWED_APP_IDS` (must include that ID)
- `WINDOWS_TPM_VERIFIER_URL` (absolute HTTPS `/verify` URL)
- Secret Manager secret `WINDOWS_TPM_VERIFIER_TOKEN` (minimum 32 characters;
  bound only to `mintWindowsAppCheckToken`)

Enable Firestore TTL on the `expiresAt` field for the
`windows_app_check_challenges` collection group so consumed/expired challenge
receipts are eventually deleted; transactional replay enforcement uses the
stored document until TTL cleanup.

Windows verifier service:

- `OPENBURNBAR_TPM_VERIFIER_APP_ID` (same Firebase app ID)
- `OPENBURNBAR_TPM_VERIFIER_TOKEN` (same service credential)
- standard ASP.NET Core HTTPS endpoint/certificate configuration

The verifier rejects plain HTTP, wrong app IDs, malformed CNG blobs, stale
claims, and invalid bearer credentials. Missing configuration leaves the TPM
verifier unregistered, so minting fails closed. There is no production debug or
mock fallback.

## Build and deploy

Build the Windows verifier on a Windows host:

```powershell
dotnet publish windows/cloudsync/appcheck/OpenBurnBar.CloudSync.AppCheck.Verifier.Windows/OpenBurnBar.CloudSync.AppCheck.Verifier.Windows.csproj `
  -c Release -r win-x64 --self-contained false
```

Run it as a locked-down Windows service behind its configured TLS certificate.
Only the Functions egress path should reach `/verify`. Rotate the shared service
credential by updating both sides before retiring the old deployment.

## Certification evidence contract

R14-A (Windows 11 vTPM) and R14-B (physical manufacturer-backed TPM) are separate
receipts. Each receipt must contain:

- exact app and verifier commit SHA plus published artifact hashes;
- Windows edition/build/architecture and `Get-Tpm` output with device identifiers
  redacted;
- verifier Windows Server build, HTTPS certificate identity, and deployment ID;
- Firebase project/app ID and App Check enforcement state, with secrets redacted;
- a fresh challenge -> `NCryptCreateClaim` -> `NCryptVerifyClaim` ->
  `createToken` trace using correlation IDs or hashes, never raw tokens/nonces;
- successful `submitDomainCoreShadowSamples` from the exact Windows artifact;
- negative proofs for missing App Check header, wrong app ID, modified claim,
  expired challenge, and replay of the already-consumed challenge;
- verifier and Functions log scan showing no ID token, App Check token, bearer
  secret, raw claim, or nonce was logged.

The receipt is **BLOCKED**, not failed, when the Firebase app ID, deployed Windows
verifier, staging account, vTPM/physical TPM, or enforcement permission is absent.
Portable tests and a macOS cross-build are supporting evidence only. R14-B remains
blocked until a named physical Windows device passes the same matrix.

## Local deterministic checks

```bash
npm run build --prefix functions
cd functions && npx vitest run src/__tests__/windowsAppCheck.test.ts src/__tests__/windowsAppCheckConfig.test.ts
dotnet test windows/tests/cloudsync-appcheck/OpenBurnBar.CloudSync.AppCheck.Tests.csproj
dotnet test windows/tests/cloudsync-app/OpenBurnBar.App.CloudSync.Tests.csproj
dotnet build windows/cloudsync/appcheck/OpenBurnBar.CloudSync.AppCheck.Verifier.Windows/OpenBurnBar.CloudSync.AppCheck.Verifier.Windows.csproj
```
