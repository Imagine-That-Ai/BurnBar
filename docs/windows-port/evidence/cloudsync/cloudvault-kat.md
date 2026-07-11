# Evidence — CloudVault crypto KAT parity (Real)

**Ledger row:** `cloudvault-crypto-kat`
**Status claim:** Real
**Date recorded:** 2026-07-09

## What this proves

C# `OpenBurnBar.CloudSync.Crypto` matches the Swift `CloudVaultCrypto` known-answer tests (seal/open, envelopes, P-256 agreement, AAD context) via committed KAT vectors.

## Artifacts

| Artifact | Location |
|----------|----------|
| Crypto core | `windows/cloudsync/OpenBurnBar.CloudSync.Crypto/CloudVaultCrypto.cs` |
| AES-GCM box | `windows/cloudsync/OpenBurnBar.CloudSync.Crypto/AesGcmBox.cs` |
| Envelopes / P-256 / AAD | `CloudVaultEnvelopes.cs`, `P256KeyAgreement.cs`, `CloudVaultAadContext.cs` |
| Tests | `windows/tests/cloudsync/*` (KAT / seal / recovery suites) |

## Explicit non-claims

- Live Windows-seal → Mac-open cross-machine trip is **DeferredApproved** (`docs/windows-port/c5-e2ee-round-trip-deferral.md`), not Real.
- App Check / Firebase auth are separate Blocked rows.
