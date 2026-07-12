# Ledger row: firebase-oauth-windows / appcheck-tpm / cloudvault-live-roundtrip

**What this proves:** Production composition roots for Desktop OAuth loopback,
Windows App Check provider, and CloudVault seal→open live round-trip are shipped
and unit-tested. OAuth builds DesktopOAuthLoopbackFlow when
OPENBURNBAR_GOOGLE_OAUTH_CLIENT_ID and OPENBURNBAR_FIREBASE_WEB_API_KEY are set.
App Check uses WindowsAppCheckProvider with injectable attestation producers.
CloudVaultLiveRoundTrip seals and opens through the production AES-GCM core with
random vault keys (integrity fail-closed on mismatch).

**Tests:** windows/tests/cloudsync/CloudVaultLiveRoundTripTests.cs,
windows/tests/cloudsync-app/DesktopOAuthCredentialsProviderTests.cs,
windows/cloudsync App Check suites.

**Operational residual:** operator secrets and physical/vTPM claim mint on a
given machine. Composition is production code, not sample authentication.
