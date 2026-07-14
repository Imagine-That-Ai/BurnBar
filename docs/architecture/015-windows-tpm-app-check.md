# ADR 015: Windows TPM custom App Check

## Status

Accepted.

## Context

Firebase has no built-in Windows desktop attestation provider. Windows can create
a TPM-backed installation key and a CNG platform claim, but the opaque claim can
only be verified with `NCryptVerifyClaim` on Windows. Cloud Functions run on
Linux. A client-generated nonce and process-local replay set are not sufficient
for a production token mint.

## Decision

- Treat Windows custom App Check as the existing `windows_lower_trust` device
  class. It proves a TPM-backed installation key, not a measured app binary.
- Issue a short-lived nonce from an authenticated callable and bind it to the
  Firebase UID plus exact provisioned App Check app ID.
- Persist only the nonce hash and consume the challenge in a Firestore
  transaction before minting. Configure TTL cleanup on the expiry timestamp.
- Export only the TPM key's public CNG blob. The private key remains
  non-exportable in the Microsoft Platform Crypto Provider.
- Verify the platform claim in a bearer-authenticated HTTPS service running on
  Windows via `NCryptImportKey` and `NCryptVerifyClaim`. Cloud Functions accepts
  the response only when UID, app ID, challenge ID, and nonce all match.
- Store the Functions-to-verifier credential in Secret Manager. Missing URL,
  secret, real app ID, challenge, or verifier produces no token.
- Shipping OAuth composition always uses the TPM producer and App Check. Mock
  attestation remains limited to deterministic non-production tests/dev tooling.
- Do not use this lower-trust token to satisfy stronger high-risk owner-action
  attestation requirements.

## Consequences

The Linux Functions runtime does not approximate a Microsoft claim format, and
replay protection survives instance restarts and concurrency. Production now
requires a separately deployed Windows verifier, Firebase configuration, and
vTPM/physical-TPM certification. vTPM and physical hardware receipts remain
separate gates. See
[`WINDOWS_APP_CHECK_TPM_PRODUCTION.md`](../windows-port/WINDOWS_APP_CHECK_TPM_PRODUCTION.md).
