# Ledger row: firebase-oauth-windows / appcheck-tpm / cloudvault-live-roundtrip

**What this proves:** Production composition roots for Desktop OAuth loopback,
Windows App Check provider, and CloudVault seal→open live round-trip are shipped
and unit-tested. OAuth builds DesktopOAuthLoopbackFlow when
OPENBURNBAR_GOOGLE_OAUTH_CLIENT_ID and OPENBURNBAR_FIREBASE_WEB_API_KEY are set.
App Check production OAuth now requires `TpmAttestationProducer`, a live HTTP
transport, the provisioned app ID, and a server-issued challenge. Functions
consumes challenges transactionally and delegates opaque CNG claim verification
to the Windows-hosted `NCryptVerifyClaim` service. See
[`WINDOWS_APP_CHECK_TPM_PRODUCTION.md`](../../WINDOWS_APP_CHECK_TPM_PRODUCTION.md).
CloudVaultLiveRoundTrip seals and opens through the production AES-GCM core with
random vault keys (integrity fail-closed on mismatch).

**Tests:** windows/tests/cloudsync/CloudVaultLiveRoundTripTests.cs,
windows/tests/cloudsync-app/DesktopOAuthCredentialsProviderTests.cs,
windows/cloudsync App Check suites.

**Operational residual:** deploy the verifier and Functions configuration, then
capture the R14-A vTPM and R14-B physical-TPM evidence contracts on named Windows
hosts. Portable coverage and macOS cross-builds do not certify either hardware
gate.
