# Blocked Production Evidence

| Surface | Status | Reason | Local/Staging Evidence |
| --- | --- | --- | --- |
| Linux App Check production attestation | Blocked | No production Linux attestation provider credentials/config are available in this workspace. Non-production mock verification is explicitly disabled when `runtime.env === "Production"`. | `linuxAppCheck.test.ts` verifies fixture claims mint in non-production and cannot mint in production. |
| Stripe live checkout restore | Blocked | No live Stripe account/session credentials are available in this worker environment. | `LinuxSecurityEvidence` restores active, cancelled, payment-failed, and offline fixtures with source `stripe_checkout`. |
| Firebase staging cloud sync emulator trace | Blocked | No authenticated Firebase emulator/staging credentials are provided to this worker. | `LinuxSecurityEvidence` exercises the same client privacy guard: owner path allowed, other-user path denied, plaintext private field denied, watermark advances only after commit. |

