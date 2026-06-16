# Authentication, Authorization, and Identity Review

## A.5.1 Authentication

### Firebase Auth

- Users sign in via Apple, Google, or passkeys (`functions/src/callables/passkey.ts`).
- Firebase Auth issues an ID token consumed by callable functions.
- `assertAuth(context)` in `functions/src/auth.ts` validates the token and extracts `uid`.

### Sign in with Apple

- iOS/macOS use `ASAuthorizationAppleIDProvider`.
- Server-side verification is not re-verified on every call because Firebase Auth already validates the Apple token during sign-in and mints its own token.
- For direct Apple JWS receipt verification (App Store), `functions/src/appstore/verifyAppleJWS.ts` pins roots, replays to Apple, and binds tokens to UID.

### Passkeys (WebAuthn)

- Implemented in `functions/src/callables/passkey.ts`.
- Uses Firebase Auth's passkey capability for device escrow.
- Challenge/response flow appears standard; no custom crypto.

### App Check

- App Check helper in `functions/src/auth.ts`: `assertAppCheck(context)`.
- Callable wrappers (`enforceAuthAndAppCheck`) call it but **do not reject** unless the token is missing or explicitly configured to enforce.
- The client enables App Check (iOS `AppAttestProvider`, Android `PlayIntegrityAppCheckProviderFactory`).
- **Critical gap**: whether Firestore rules enforce App Check is a Firebase console toggle, not repo code. If disabled, an attacker with a valid Firebase Auth token can read/write owner-scoped data via REST.

**Finding**: FINDING-005 — App Check production enforcement unverifiable in repo.

## A.5.2 Authorization

### Callable Functions

- `assertOwnership(db, uid, resourcePath)` checks that the resource path starts with `users/{uid}`.
- Most callables use this before reading/writing Firestore.
- Example: `functions/src/callables/stripe.ts` uses ownership checks for customer portal.

### Firestore Rules

- `firestore.rules` uses:
  - `request.auth != null` for authenticated reads/writes.
  - `request.auth.uid == userId` for owner scoping.
  - `hasNoPlaintextSecretFields` to reject writes with plaintext secrets.
  - `isOperatorClaim()` for `ops/` collection.
- `session_logs` rules appear strict, but the prior audit (M-005) noted a fail-open edge if the document path shape changes; verify rule tests cover it.

### BOLA / IDOR

- Pattern is consistent: all user data under `users/{uid}` and ownership asserted.
- Risk: any function that accepts a raw path or `targetUid` without checking can be vulnerable.
- Review did not find such a function, but a comprehensive adversarial test suite is missing.

### Device Pairing / Escrow

- `functions/src/callables/deviceEscrow.ts` issues short-lived escrow tokens.
- `webAppCheck.ts` binds browser console to a device via WebAuthn/escrow.
- Prior audit item M-037 (phone-control cross-pairing) remains: a stolen escrow token or QR could pair an attacker's device.

## A.5.3 Identity and Tenant Isolation

- Single-tenant per Firebase project; tenant isolation relies on `uid` boundaries.
- No multi-tenant organization support visible.
- Service accounts (`functions/src/admin.ts`) use default admin credentials; no impersonation scoping.

## A.5.4 macOS/iOS Local Identity

- Local app does not have its own user identity; it relies on the macOS user session.
- Daemon runs as the same user; no separate authentication.

## A.5.5 Prior Audit Items (Auth)

| ID | Title | Status | Notes |
|---|---|---|---|
| M-001 | Remote Unlock helper missing from bundle | Open | Helper binary not packaged; feature unusable or unsafe |
| M-005 | session_logs rule fail-open | Partial | Rules updated; need regression test proof |
| M-007 | CloudVault AAD partial | Partial | Additional authenticated data added; verify all envelopes |
| M-023 | agentNotifications UID leak | Partial | Logging/notification payload reduced; verify |
| M-037 | Phone-control cross-pairing | Open | Escrow token binding needs hardening |
