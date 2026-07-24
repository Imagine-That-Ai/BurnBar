# P-15 installed account and billing proof

P-15 is a standalone Tier-A closure for the installed Linux Account route. It binds every receipt to the signed candidate, the aggregate release closure, the environment row, and a fresh challenge. It does not treat fixture UI, source tests, a browser page, or a successful daemon RPC as installed proof.

The production probe launches `/usr/bin/openburnbar-linux-desktop` through `tauri-driver` with fixture mode disabled and talks to the installed user daemon. It records redacted daemon-owned account status, live membership tier and entitlements, browser-PKCE handoff and cancellation when signed out, invalid cloud-erasure confirmation rejection, and the external Stripe billing boundary. Free users receive a checkout session; active paid members receive a Billing Portal session from `createStripeBurnBarProPortalSession` and must never be routed through a second checkout. Billing URLs are never opened by the proof; only an allowlisted hostname is retained. Authorization URLs, identities, credentials, checkout or portal session IDs, local paths, and payment data are forbidden from retained evidence.

Linux-native parity means browser PKCE and external Stripe checkout or Billing Portal rather than embedded credentials or StoreKit. The daemon owns Firebase auth and optional App Check credentials, uses the Firebase callable envelope, bounds the request and response, accepts only approved OpenBurnBar HTTPS return locations, and returns only exact Stripe HTTPS origins. The Tauri opener independently applies the same exact-host boundary. A missing or unavailable billing capability fails closed without falling back from portal to checkout. The proof never signs out an existing user, restores a purchase, submits payment, completes OAuth, or deletes cloud data.

The live sequence captures distinct Account-route screenshots and AT-SPI trees for identity, membership, daemon-unavailable, and recovered local-first states. It stops and restarts the real user daemon, permits one bounded refresh, rejects optimistic recovery, and restores the exact initial daemon state, desktop process set, and isolated home tree even after failure.

Run the focused contract locally:

```bash
node --test scripts/linux-port/p15-account-billing-proof.test.mjs scripts/linux-port/ownership-tests/P-15.test.mjs
```

The default runner requires the signed installed candidate, a supported live Linux desktop, `tauri-driver`, `WebKitWebDriver`, AT-SPI, a screenshot tool, and the package-managed daemon. Dependency injection exists only for deterministic contract and mutation tests.
