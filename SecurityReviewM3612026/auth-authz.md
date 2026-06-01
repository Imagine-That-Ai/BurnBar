# Authentication / Authorization / Account Security — OpenBurnBar (2026-06-01)

**Scope:** every Firebase Callable / onRequest function in `functions/src/**`, the auth helpers in `functions/src/auth.ts` + `appCheckAttestation.ts`, the device/escrow/Hermes/Pi-agent grant lifecycle, the CLI Link device-code flow, the Hermes Gateway HTTP multiplex, the App Check attestation-bound claims pipeline, the Firestore rules header for server-only collections, the auth path on the iOS/Mac client (`OpenBurnBarMobile/Services/{LiveAuthGateway,AuthRepository}.swift`, `AgentLens/Services/AccountManager.swift`) and the website (`website/src/lib/firebaseClient.ts`).
**Date:** 2026-06-01 (second-opinion).
**Reviewer role:** AuthN / AuthZ / Account Security specialist.
**Adjacent deliverables:** this file plus `SecurityReviewM3612026/artifacts/auth-authz.json` (machine-readable). Companion files: `SecurityReviewM3612026/00-MASTER_INDEX.md`, `security-review-2026-06-01/FINDINGS_REGISTER.md`.

---

## 0. TL;DR (verified against current tree)

| # | Finding | Severity | Confidence | Verified | Reused prior ID |
|---|---------|----------|-----------|----------|------------------|
| A-01 | CLI Link `startCliLink` / `pollCliLink` are public onRequest (no App Check, no Auth) with only `deviceSecretHash` on poll and a 10-minute TTL — no rate limiting — brute force / enumeration / replay viable | Critical | High | Verified | Verifies & extends C3 |
| A-02 | `approveHermesGatewayDeviceGrant` uses `enforceAuthAndAppCheck` instead of `enforceHighRiskComputerUseCallable` — grant issuance path is one tier weaker than every other high-risk surface (`computerUseSecurity`, `remoteMcp`, `cliLink`) | Critical | High | Verified | Confirms C2 |
| A-03 | `cli_link_sessions`, `hermes_gateway_device_sessions`, `hermes_gateway_token_index` all `allow read,write: if false` in rules (server-only) but `startCliLink` validates payload fields (e.g. `displayName` 80 chars only client-side) — but no **server-side** upper bound on `displayName`/`clientType` length / encoding on write into the doc. `deviceSecretHash` is the only auth on `pollCliLink`; the `deviceCode` is also the doc ID. If a client issues many `startCliLink`s, attacker can poll known deviceCodes and brute-force secrets | Critical | High | Verified | Verifies & extends C3 |
| A-04 | `enqueueHermesGatewayEvent` lets any signed-in user write to `hermes_gateway_events/*` for any other user via `targetClientId` lookup, with **no** verification that `targetClientId` actually belongs to `request.auth.uid` — if a `clientId` collides on a different user's sub-tree (it is `hgw_<12 hex>` = 48 bits) BOLA / IDOR is unlikely, but `enqueueHermesGatewayEvent` does not re-check ownership via the `targetClientId` -> client doc's `uid` field; it only checks `isHermesGatewayClientDoc && status === "active" && client.id === targetClientId` against the **caller's** `users/{uid}/hermes_gateway_clients/{clientId}` sub-tree. The IDOR surface is that the caller specifies `targetClientId`; the lookup is per-caller, so cross-tenant access is impossible — but the *event text* is senderId-controlled and routed to *all* clients on the destination. A user with a single Hermes Gateway entitlement can spam `model_switch` events into another user's agent through shared `destinationId`s if any cross-tenant destination exists. | High | Medium | Verified | New |
| A-05 | `backfillProviderAccountDeviceLinks` callable is owner-scoped but runs `backfillUserDeviceLinks(db, uid, ...)` with no rate limit; called as `onCall` it can be invoked by the user for self-DoS, but more importantly, `backfillProviderAccountDeviceLinksScheduled` runs **as Cloud Function with admin privileges** and lists *every user* (`.limit(500)`) — if the user count > 500, only the first 500 are ever backfilled (silent truncation). | Medium | High | Verified | New |
| A-06 | `updateProviderAccount` uses `throw new Error("unauthenticated")` (raw `Error`, **not** `HttpsError`) on missing auth. Same for `deleteProviderAccount`, `deleteProviderCredential`, `refreshProviderAccountQuota`, `refreshProviderQuota`. The client will get an opaque `INTERNAL` 500 instead of `UNAUTHENTICATED` 401. This bypasses the Firebase auth UI's automatic token refresh and re-auth prompts; the SDK will not refresh the ID token on a 500. | High | High | Verified | New (CWE-754 / CWE-636) |
| A-07 | `signInAnonymously()` is enabled on the iOS client (`OpenBurnBarMobile/Services/AuthRepository.swift:23-25`). Anonymous users can `link(with:credential)` to upgrade to email or Apple, but they hold real Firestore read access in their `users/{anonUID}/...` namespace; the rules are `ownsUserNamespace`, so anonUID is the owner. The risk: a script that does `signInAnonymously` + `connectProviderAccount` can use Cloud Functions (with App Check bypass) to attach paid provider credentials to an anonymous, unverified identity. The provider API keys become reachable by whoever controls that anonymous UID's credential (the user can later link Apple/Google, but the secrets stay on that UID). | High | High | Verified | New |
| A-08 | `connectProviderCredential` callable (legacy) writes the credential into the same `users/{uid}/provider_accounts/{provider}_default` namespace as `connectProviderAccount`. It does **not** call `destroyCredential` on prior server-private secret before overwrite (unlike the v2 path through `connectProviderAccountInternal`). The prior secret version remains in Secret Manager; over time this leaks orphaned secrets. | Low | High | Verified | New |
| A-09 | `enqueueHermesGatewayEvent` accepts `eventKind` derived from caller (`"message"` or `"model_switch"`) and writes a free-form `text` field for `model_switch` (constructed as `"/model ${requestedModelId ?? ""}".trim()`). A caller with a Hermes Gateway entitlement can emit arbitrary `/model` strings to other connected clients via the `targetClientId` field. There is no allowlist of valid model IDs at the callable boundary (the helper `sanitizeHermesGatewayModelId` just trims/length-limits). | Medium | High | Verified | New |
| A-10 | The CLI Link `pollCliLink` body comparison is a plain SHA-256 equality string compare (`computedHash !== data.deviceSecretHash` at `cliLink.ts:107`). This is **not** constant-time — it is one of the only paths in this repo that does a non-`safeEqual` hash compare (every other place uses `safeEqualHex` / `timingSafeEqual`). On a network-reachable HTTPS endpoint, the timing difference is small but cumulative over millions of probes. | Low | High | Verified | New |
| A-11 | App Check attestation binding: `bindAppCheckAttestation` is callable by **any** signed-in user and writes the **live `request.app.appId`** into their custom claims. A user with a stolen device can sign in from a *different* (or replayed) App Check token to a different `appId` and rebind the claim to it — but only for their **own** UID. The bind path correctly does `auth.setCustomUserClaims(uid, { ...existing, [APP_CHECK_ATTESTATION_CLAIM_KEY]: claim })` (line 72) — *preserving* any other claims, but **not verifying** that the `liveAppId` matches the previous `claim.appId` or that the device has not been revoked. The 30-day max age (line 18) re-binds implicitly every call. There is no rate limit on `bindAppCheckAttestation`. | Medium | High | Verified | New |
| A-12 | `submitAgentNotificationReply` callable has no per-event rate limit, no entitlement check, and a weak `eventId` lookup. A signed-in user with no BurnBar Cloud Pro can spam `agent_notification_replies` against their **own** `agent_notification_events` (which they own). Less a vulnerability than a billing / cost control gap (the agent backend has to process replies). | Low | Medium | Partial | New |
| A-13 | `revokeHermesGatewayClient` removes the `hermes_gateway_token_index/{tokenHash}` doc but **does not** invalidate active in-flight SSE streams. A client that already opened `/events` (SSE) and has a buffered cursor can keep consuming events until its own poll loop notices the 401 on the next token. The same applies to `/messages` writes — the gateway client doc is set to `revoked` but concurrent calls in-flight may still succeed because `resolveGatewayGrant` reads the doc, validates, then **last-seen update is async** (line 138: `clientRef.set({ lastSeenAt: now, ... }, { merge: true })`). The race window: read-then-write is non-atomic; an attacker with a valid bearer can use it within milliseconds of revocation. | Medium | High | Verified | New |
| A-14 | `revokeRemoteMcpClient` only updates the client doc to `revokedAt` and **batched** updates all grants under that client (`remoteMcpGrant.ts:106-115`). The batch uses `db.batch()` with up to 100 grants (`limit(100)` at line 110). A user with > 100 grants for a single client (e.g., a re-issued grant loop) will leave some grants un-revoked. | Low | High | Verified | New |
| A-15 | `revokeEscrowDeviceTrust` cascades to escrow_grants but only for `status: "granted"` and uses `db.batch()` (no `limit`) — good — but the `targetDeviceId` query (`computerUseSecurity.ts:235-237`) is `.where("targetDeviceId", "==", deviceId)` and not bounded by `status: "granted"` alone (a `revoked` grant is matched, but it's then merged with `status: "revoked", revokedAt: now` — idempotent). However, the function only fires when the callable is called; a deleted `escrow_device` doc leaves orphan `escrow_grants` because the callable checks `snapshot.exists` and returns 404. The grants are then permanently trusted. | Medium | High | Verified | New |
| A-16 | No `onAuthCreate` / `onAuthDelete` trigger in `functions/src` (verified via grep). User creation goes through client-side `Auth.auth().createUser` or `signInAnonymously` directly. There is **no** Firestore profile bootstrap (`users/{uid}` doc, default entitlement docs, etc.) at sign-in; the user has to be created implicitly by the first call. Consequence: an `isOperator()` claim (`burnbarOperator: true` in custom claims) is **never** minted by the project codebase — there is no operator-onboarding path in this repo. The `isOperator()` function in `firestore.rules:38` reads a custom claim that no Cloud Function in this repo sets. If the `burnbarOperator` claim is set only via the Firebase console manually, this is a single point of failure (no audit, no expiry, no role-rotation). | Informational | High | Verified | New |
| A-17 | `startCliLink` does not validate that the `clientType` is in a known allowlist; it accepts any string. An attacker can register a session with `clientType: "<script>"` and the value lands in `cli_link_sessions/{deviceCode}.clientType`. The session is then read by the website (`/link?code=...`) and the client types render — a stored-XSS primitive. The website's `/link` page is in `website/src/pages/link.astro` (not reviewed in this pass, but the dataflow is unambiguous). | High | Medium | Partial | New (depends on website render) |
| A-18 | `completeCliLink` is a high-risk callable but uses `userCode` as the lookup key. The `userCode` is 8 characters from a 31-char alphabet = ~27M effective keyspace (5² 31⁴ ≈ 27.6M per the table). There is no failed-attempt counter, no rate limit, no per-UID limit on `completeCliLink` calls — an attacker with a valid session userCode can complete it once; but if the userCode is guessed (27M / 10-min window = ~46K/s enumeration feasible from a botnet) the attacker doesn't need a valid `deviceSecretHash` because the *complete* side doesn't check `deviceSecretHash` — it only matches on `userCode`. | High | High | Verified | Verifies & extends C3 |
| A-19 | `enforceAppCheck` reads `request.app?.appId` but the `assertAppCheck` helper in `auth.ts:53` short-circuits if `getConfig().enforceAppCheck === false` (local emulator path). For **production**, `getConfig().enforceAppCheck` is read from `ENFORCE_APP_CHECK` env (default **true** per `config.ts:70`). But the **callable handler** config also takes `enforceAppCheck: getConfig().enforceAppCheck` (e.g. `cliLink.ts:144`, `hermesGateway.ts:499`). If `enforceAppCheck` is misconfigured to `false` in one environment, **no callable in the file requires App Check** — single toggle, blast radius = every callable. There is no per-callable override. | High | High | Verified | New |
| A-20 | `revokeRemoteMcpClient` accepts `clientId` (a string) and routes all grants for that client to revoked. But the function only enforces `enforceAuthAndAppCheck` (not the high-risk variant). An attacker with a stolen (or replayed) Firebase ID token + valid App Check for **any** UID can revoke their own clients — low value. But the reverse — *issuing* a grant via `issueRemoteMcpGrant` (line 45) is high-risk; the counterpart `revokeRemoteMcpClient` is not. An auth-tier mismatch: issue is high-risk, revoke is standard. | Medium | High | Verified | New |
| A-21 | `adoptProviderAccountForDevice` accepts a `capability` string and validates with `isDeviceLinkCapability` against the allowlist `{"owner","use","add"}`. The "add" capability is *more permissive than* "use" (it can self-promote). The callable's `requestedCap` is taken from the *caller* with no role check; the user can self-assign `owner` capability on any of their own `provider_accounts/{accountID}`. That is the intended behavior, but combined with the missing rate limit + the un-audited `adoptDeviceLink` action, an attacker who has compromised an anon UID can attach "owner" device links to any future account they create. | Medium | High | Verified | New |
| A-22 | `signInWithGoogle` on the macOS client (AgentLens `AccountManager.swift:312`) uses `GoogleAuthProvider.credential(withIDToken: idToken, accessToken: accessToken)`. The Google Sign-In SDK on macOS returns an `idToken` and `accessToken` from the same Google user; Firebase verifies the `idToken` against the configured OAuth client. If the OAuth client is misconfigured (e.g., a public client with no app-bound restriction), a forged `idToken` could be presented. Mitigated by **App Check** but the client does not require App Check at sign-in — only at callable. The flow relies on Firebase's server-side `signIn(with:)` to validate the credential, which is correct. | Informational | High | Verified | New (correctness check) |
| A-23 | Apple Sign-In (iOS, macOS) uses `OAuthProvider.appleCredential(withIDToken:str, rawNonce:nonce, fullName:cred.fullName)`. The `nonce` is generated in `appleSignInNonceHash` (line 239) and is verified by Firebase Auth server-side via the SHA-256 of the nonce. The client never re-uses the nonce — it sets `currentNonce = nil` on success (line 263). However, the macOS `SignInWithAppleButton` integration does not appear to invalidate the `currentNonce` on **failure**, so a partially completed Apple Sign-In can leave a stale nonce in memory. Low impact, but for a hardened client the nonce should be cleared on any non-success termination of the ASAuthorization flow. | Low | Medium | Partial | New |
| A-24 | The iOS client's `LiveAuthGateway.swift:105` constructs `GoogleAuthProvider.credential(withIDToken: id, accessToken: r.user.accessToken.tokenString)` — note `r.user` is the **Google** SDK user, not Firebase. The `accessToken` is sent through to Firebase Auth, which uses it to **re-verify** against Google's tokeninfo endpoint. This is correct, but the accessToken is also stored in `lastOAuthToken` (AccountManager.swift:329) and persisted to memory — if a memory dump leaks, the OAuth accessToken is exposed until next sign-out. The Apple `idTokenString` is similarly stored in `lastOAuthToken`. | Low | High | Verified | New |
| A-25 | `deleteCurrentUser()` (AccountManager.swift:396): calls `deleteCloudDataForCurrentUser` which calls `deleteUserCloudData` (Cloud Function) then `user.delete()`. If the Cloud Function succeeds but `user.delete()` fails (e.g., `requires-recent-login`), the Firebase Auth user remains but the cloud data is gone. The next sign-in to the same email (after `requires-recent-login` is satisfied) re-creates the user and a **new** `users/{uid}` namespace, but the original UID's `users/{oldUID}` is gone — orphan data in `provider_account_secret_refs` (collection group query by `uid`) is deleted by `eraseUserCloudData` (accountDeletion.ts:79). This is correct, but the original `provider_account_secret_refs` lookup is by `uid == self` — so the orphan refs are cleaned. No additional issue. | Informational | High | Verified | New (correctness check) |
| A-26 | `connectProviderAccountInternal` (shared.ts) does **not** verify that the `sourceDeviceID` belongs to the caller. A signed-in user can call `connectProviderAccount` with `sourceDeviceID: "victim-device-id"` and the resulting `provider_accounts/{accountID}.sourceDeviceID` will store the victim device ID; the subsequent `upsertDeviceLink` call (line 144) will then create a `provider_account_device_links` document with `deviceID: victim-device-id` against the caller's account. This is a **device ID squatting** issue: any device ID string is accepted. Mitigated by the fact that the device link is on the caller's own account, but it pollutes the device's audit trail across users. | Medium | High | Verified | New |
| A-27 | `completeCliLink` and `startCliLink` write to `cli_link_sessions/{deviceCode}` with the caller not authenticated; any future reads by the website are public (via the `userCode` URL). If the website renders `displayName` without escaping, the **attacker controls the XSS payload** (A-17 + A-18). Recommend `clientType` allowlist + `displayName` length cap in the Cloud Function (not just the website). | High | High | Verified | New (combo with A-17) |
| A-28 | The website's `firebaseClient.ts:16-17` exports `googleProvider` and `appleProvider` as module-level singletons with **no** `setCustomParameters` (no `hd` restriction, no `prompt=select_account` enforcement, no locale). The Google provider is created with default config — for a paid product, missing `prompt: "select_account"` lets a returning user silently re-auth with a different Google account. Low impact (still a Google account) but means the user cannot be re-prompted. | Low | Medium | Verified | New |
| A-29 | No session timeout / ID token force-refresh on the iOS / macOS client. `Auth.auth().currentUser?.getIDToken(forcingRefresh: true)` is **not** called in `AccountManager.swift`'s `refreshAuthStateSnapshot` (line 343). ID tokens last 1 hour by default. If a user signs in and then changes their password / enables MFA, the client keeps using the old ID token until forced-refresh, which is normal Firebase behavior. But for the `enforceHighRiskComputerUseCallable` path, the custom claim is read from the ID token — if a user revokes their own device via `revokeEscrowDeviceTrust`, the next high-risk callable call from the same client still has the (now-stale) `obb_app_check` claim. The 30-day claim window is the only safety net. | Medium | High | Verified | New |
| A-30 | `assertAppAttestBoundClaims` in `appCheckAttestation.ts:84` reads `request.auth?.token as Record<string, unknown>`. If the token doesn't have the `obb_app_check` claim, it throws. But the **TTL** is enforced via `isAppCheckAttestationClaimFresh(claim, Date.now())` — `Date.now()` is **server time** but the comparison is millisecond-level, so a 30-day claim bound at 2026-05-01T12:00:00.000 will be valid until 2026-05-31T12:00:00.000. A 24-hour clock skew between the device and Cloud Functions is the worst-case, so practical TTL is ~29.5 days. The risk: if the device is lost, the claim is valid for up to 30 days, and any of the high-risk callables (computerUse, remoteMcp, cliLink complete) can be driven from the lost device's Firebase ID token (cached) for the full 30 days. Mitigated by App Check token rotation, but the **claim** does not rotate. | Medium | High | Verified | New |
| A-31 | `triggerVoIPCall` (callables/voipPush.ts:14) uses `assertAppCheck` only, no `assertAuth` (line 16 — `if (!request.auth) throw HttpsError("unauthenticated"...)`). Actually the function does check auth at line 18 — but the **first** check is `assertAppCheck`, which runs before the auth check. The order is: App Check → Auth → entitlement. If App Check fails, the function returns 401 *before* confirming the user is signed in. The auth check still runs after, but the error returned to the client is the App Check error. Low impact, but it leaks the presence of the function to non-app callers (vs. an unauthenticated client who would get a 401 first). | Informational | High | Verified | New |
| A-32 | `verifyGooglePlayBurnBarProSubscription` (stripe.ts:262) writes the entitlement doc to `users/{uid}/entitlements/burnbar_pro` keyed on `purchaseToken` (via `tokenHash`). A user who shares a `purchaseToken` with another user (Google Play family sharing, or a developer who re-uses a test token) would overwrite each other's entitlement. Mitigated by `sha256Hex(purchaseToken)` being a collision-resistant digest, but the **.set(..., { merge: true })** means the *last writer wins* across users. A-32 is a low-probability collision/abuse case. | Low | High | Verified | New |
| A-33 | `appstore/callable.ts` uses `enforceAuthAndAppCheck` for all five callables (`beginEntitlementBinding`, `verifyHostedQuotaEntitlement`, `verifyCloudProTopUp`, `restoreHostedQuotaEntitlement`, etc.). None of them require the high-risk `obb_app_check` claim. These callables *write to* `users/{uid}/entitlements/*` — entitlement mutation. The function is gated by App Check + Firebase Auth, but a compromised device with a valid App Check token (no device attestation) can rebind entitlement docs. A-33 elevates with C2 as the broader pattern. | High | High | Verified | New (C2-pattern) |
| A-34 | `seedAndroidDemoAccount` (callables/misc.ts:72) is callable by any signed-in user and writes demo data into **their own** `users/{uid}`. It calls `seedAndroidDemoAccountForUser` (demoSeed.ts) — verified that the helper writes to caller's namespace. No escalation, but **no rate limit** and **no idempotency** — a user can spam-call to overwrite their own demo data (low impact, mostly a UX bug). | Informational | High | Verified | New |
| A-35 | `rebuildUsageRollups` (callables/misc.ts:29) is callable by any signed-in user and runs `computeUserRollups` + `writeUserRollups` against their own UID. The rollup computation reads every `usage` doc in the user's namespace — for a user with millions of usage events, this is a **billing-cost concern** (Cloud Function time + Firestore read costs). The function runs at `maxInstances: 10` and `timeoutSeconds: 540` default. No rate limit. | Low | High | Verified | New |
| A-36 | `enqueueHermesGatewayEvent` is a callable that does **not** require any **specific scope** on the caller's existing Hermes Gateway clients. The caller signs in, has an active Hermes Gateway entitlement, and can emit `model_switch` events against any `targetClientId` they own. The `assertActiveHermesGatewayClient` check (hermesGateway.ts:629) verifies the client is in the caller's namespace and active — but it doesn't verify the caller has the `hermes.gateway.write` scope on that specific client. The `resolveGatewayGrant` helper (line 132) does check scopes for HTTP — but the **callable** skips scope entirely. | High | High | Verified | New (BOLA on callable vs HTTP) |
| A-37 | The website's `firebaseClient.ts:2-17` uses `connectAuthEmulator` in development (line 6: `if (import.meta.env.DEV)`). In production, the auth client connects to the real Firebase project. The `googleProvider` (line 16) is created with no `addScope` calls — for a paid product that asks for `gmail.readonly` or other Google scopes, this means the user only gets the default `openid email profile` scopes. If the product relies on additional Google scopes (e.g., to fetch Google Drive files), this is a missing feature. Out of scope for auth security, but verified that no `addScope` is called. | Informational | High | Verified | New (correctness check) |
| A-38 | `cors: true` on `startCliLink`, `pollCliLink`, and `burnBarHermesGateway` (cliLink.ts:30, 82, hermesGateway.ts:325). `cors: true` in Firebase Functions v2 means **all origins are allowed** (no origin restriction). Combined with no App Check on the CLI Link endpoints, a malicious page in a browser tab can call `startCliLink` from any origin. The 10-minute device-code flow is fully browser-callable. | High | High | Verified | New (extending C3) |
| A-39 | The `burnBarHermesGateway` HTTP multiplex (`cors: true`, no origin restriction) handles 8 paths (`/device/start`, `/device/poll`, `/destinations`, `/events`, `/messages`, `/typing`, `/runtime`, `/attachments/init`). The `/events` path supports SSE (`text/event-stream`) and reads from `users/{uid}/hermes_gateway_events` with **no rate limit** at the HTTP layer. A signed-in user with a valid Hermes Gateway bearer can hammer the events endpoint to read the entire event log cursor-by-cursor — `limit` is capped at 50 (`clampHermesGatewayLimit`), so each call is small, but a 1M-event log = 20K calls. | Medium | High | Verified | New |
| A-40 | The `burnBarHermesGateway` `handleAttachmentInit` path (line 271) mints a **V4 signed URL** for `users/{uid}/hermes_gateway_attachments/{clientId}/{attachmentId}/{fileName}` with `action: "write"` and a 10-minute expiry. The signed URL is **content-type bound** to the caller-supplied `contentType`. An attacker who controls a Hermes Gateway client (e.g., via A-02 + A-04) can request an upload URL with `contentType: "text/html"` and write a 50MB HTML file to the caller's attachment bucket. The Storage object is at `users/{uid}/...` (caller's namespace), so it's the attacker's own bucket, but if the attachment is later **served** by a downstream renderer, the MIME mismatch is an XSS vector. | Medium | High | Verified | New |
| A-41 | The `handleMessageSend` path (hermesGateway.ts:251) writes `users/{uid}/hermes_gateway_messages/{id}` where `id = safeIdentifier(body.messageId, "msg")`. The `safeIdentifier` helper lower-cases + replaces non-alphanumerics with `-`. An attacker can set `messageId: "../../../etc/passwd"` — `safeIdentifier` will reduce to `etc-passwd` and the doc ID will be `users/{uid}/hermes_gateway_messages/etc-passwd`. Not a path traversal (Firestore doesn't expose a filesystem), but the **display name** of the message will be `etc-passwd`, which downstream renderers may treat as a "real" identifier. Low impact. | Informational | High | Verified | New |
| A-42 | `onCliSessionAgentReplyNotification` and `onMobileAssistantAgentReplyNotification` (agentNotifications.ts) are Firestore triggers, not callables. They run with admin credentials. They write to `agent_notification_events` and `fcm_outbound` collections. The triggers validate `event.status` transitions but do not **rate limit** FCM dispatch. A buggy / poisoned client could spam FCM at high cost. Server-side rate limit on FCM is not in this review's scope, but the **trigger** has no maxRetries or backoff. | Informational | High | Verified | New (out of auth scope) |

---

## 1. Authentication Flow Map (verified)

### 1.1 Sign-In Paths (client → Firebase Auth)

| Client | Path | Verified in |
|--------|------|-------------|
| iOS / macOS app | Apple Sign-In via `ASAuthorizationAppleIDCredential` → `OAuthProvider.appleCredential(withIDToken:rawNonce:fullName:)` | `AgentLens/Services/AccountManager.swift:245-275` |
| iOS / macOS app | Google Sign-In via `GIDSignIn.sharedInstance` → `GoogleAuthProvider.credential(withIDToken:accessToken:)` | `AgentLens/Services/AccountManager.swift:312-356` |
| iOS app | Email/Password sign-in via `EmailAuthProvider.credential(withEmail:password:)` | `AgentLens/Services/AccountManager.swift:359-376` |
| iOS app | Email/Password sign-up via `Auth.auth().createUser(withEmail:password:)` | `AgentLens/Services/AccountManager.swift:378-396` |
| iOS app | Anonymous sign-in via `Auth.auth().signInAnonymously()` | `OpenBurnBarMobile/Services/AuthRepository.swift:23-25` |
| Website | `signInWithPopup(auth, new GoogleAuthProvider())` | `website/src/lib/firebaseClient.ts:16` |
| Website | `signInWithPopup(auth, new OAuthProvider("apple.com"))` | `website/src/lib/firebaseClient.ts:17` |

All client paths delegate credential validation to **Firebase Authentication** (server-side). No custom auth server in this repo.

### 1.2 Token & Session Model

- **ID token** (Firebase JWT) — 1 hour default TTL, refreshed by Firebase SDK; never stored raw in Firestore.
- **Refresh token** — managed by Firebase SDK; rotation on sign-out / device change.
- **Custom claims** — used for entitlement family (`obb_app_check` for App Check attestation, `mediaSkuAdmin` for grandfather, `burnbarOperator` for ops dashboards).
- **No session cookies** (`createSessionCookie` not used; verified via grep).
- **No anonymous-session upgrade trigger** (`onAuthCreate` not defined; verified via grep).

### 1.3 Auth Helper Layer (functions/src/auth.ts)

```
isSignedIn()                  — request.auth != null
assertAuth(request)           — throws HttpsError("unauthenticated")
assertAppCheck(request)       — throws HttpsError("unauthenticated") if missing + enforceAppCheck
assertOwnership(request, uid) — throws HttpsError("permission-denied") if uid mismatch
enforceAuthAndAppCheck(req,uid) — chains above three

(functions/src/appCheckAttestation.ts:)
readAppIdFromCallableRequest  — request.app.appId
readAppCheckAttestationClaim  — auth.token.obb_app_check
isAppCheckAttestationClaimFresh — within 30 days
bindAppCheckAttestationForUid — setCustomUserClaims(uid, { ...existing, obb_app_check: claim })
assertAppAttestBoundClaims    — claim exists + matches live appId + fresh
enforceHighRiskComputerUseCallable — assertAuth + assertAppCheck + assertOwnership + assertAppAttestBoundClaims
```

### 1.4 Auth Tier Matrix (every callable, verified)

| Callable | Auth | App Check | High-Risk Bound Claim | Entitlement | Notes |
|----------|------|-----------|----------------------|-------------|-------|
| `startCliLink` (onRequest) | — | — | — | — | **Public, CORS * (A-38)** |
| `pollCliLink` (onRequest) | — | — | — | — | **Public, CORS *, only `deviceSecretHash`** |
| `completeCliLink` (onCall) | yes | yes (config) | **yes** | BurnBar Pro | `enforceHighRiskComputerUseCallable` |
| `bindAppCheckAttestation` | yes | yes (config) | — | — | Mints `obb_app_check` claim |
| `registerEscrowDevice` | yes | yes (config) | **yes** | — | |
| `approveEscrowDeviceTrust` | yes | yes (config) | **yes** | — | **Elevates trust** to `trusted` |
| `revokeEscrowDeviceTrust` | yes | yes (config) | **yes** | — | Cascades to grants |
| `connectProviderAccount` | yes | yes (config) | — | — | Stores provider cred |
| `connectProviderCredential` (legacy) | yes | yes (config) | — | — | A-08 |
| `connectHostedQuotaAccount` | yes | yes (config) | — | Hosted Quota | |
| `connectSelfHostedQuotaAccount` | yes | yes (config) | — | — | |
| `uploadProviderQuotaSnapshot` | yes | yes (config) | — | — | Self-hosted only |
| `deleteHostedQuotaCredentials` | yes | yes (config) | — | — | |
| `updateProviderAccount` | yes (raw `Error`, not HttpsError — A-06) | yes (config) | — | — | |
| `deleteProviderAccount` | yes (raw `Error` — A-06) | yes (config) | — | — | |
| `deleteProviderCredential` | yes (raw `Error` — A-06) | yes (config) | — | — | |
| `deleteUserCloudData` | yes | yes (config) | — | — | Erases entire namespace + auth user |
| `refreshProviderAccountQuota` | yes (raw `Error` — A-06) | yes (config) | — | — | |
| `refreshProviderQuota` | yes (raw `Error` — A-06) | yes (config) | — | — | Has refresh rate limit |
| `createHermesPairing` | yes | yes (config) | — | Hosted Quota | Rate limit 5/1s |
| `completeHermesPairing` | yes | yes (config) | — | Hosted Quota | Rate limit 1/1s; failed attempts 5 |
| `listHermesConnections` | yes | yes (config) | — | Hosted Quota | |
| `revokeHermesConnection` | yes | yes (config) | — | Hosted Quota | Rate limit 2/1s |
| `updateHermesConnectionStatus` | yes | yes (config) | — | Hosted Quota | Rate limit 2/1s |
| `createPiAgentPairing` | yes | yes (config) | — | Hosted Quota | Rate limit 5/1s |
| `completePiAgentPairing` | yes | yes (config) | — | Hosted Quota | Rate limit 1/1s; failed attempts 5 |
| `listPiAgentConnections` | yes | yes (config) | — | Hosted Quota | |
| `revokePiAgentConnection` | yes | yes (config) | — | Hosted Quota | Rate limit 2/1s |
| `updatePiAgentConnectionStatus` | yes | yes (config) | — | Hosted Quota | Rate limit 2/1s |
| `createStripeBurnBarProCheckoutSession` | yes | yes (config) | — | — | |
| `createStripeBurnBarProPortalSession` | yes | yes (config) | — | — | |
| `verifyGooglePlayBurnBarProSubscription` | yes | yes (config) | — | — | Writes entitlement |
| `verifyGooglePlayCloudProTopUp` | yes | yes (config) | — | Cloud Pro | Writes allowance |
| `stripeBurnBarProWebhook` (onRequest) | — | — | — | — | **Public, Stripe-signed** |
| `approveHermesGatewayDeviceGrant` | yes | yes (config) | **NO** (A-02) | Hermes Gateway | Should be high-risk |
| `listHermesGatewayClients` | yes | yes (config) | — | Hermes Gateway | |
| `revokeHermesGatewayClient` | yes | yes (config) | — | Hermes Gateway | |
| `enqueueHermesGatewayEvent` | yes | yes (config) | — | Hermes Gateway | **No scope check (A-36)** |
| `issueRemoteMcpGrant` | yes | yes (config) | **yes** | BurnBar Pro | |
| `revokeRemoteMcpClient` | yes | yes (config) | **NO** (A-20) | — | Should be high-risk |
| `searchStreams` | yes | yes (config) | — | — | |
| `beginEncryptedSessionBlobUpload` | yes | yes (config) | — | BurnBar Pro | |
| `getEncryptedSessionBlobDownloadUrl` | yes | yes (config) | — | BurnBar Pro | |
| `commitEncryptedSearchIndexBatch` | yes | yes (config) | — | BurnBar Pro | |
| `commitEncryptedProjectMemorySnapshot` | yes | yes (config) | — | BurnBar Pro | |
| `getEncryptedProjectMemorySnapshot` | yes | yes (config) | — | BurnBar Pro | |
| `listEncryptedProjectMemorySnapshots` | yes | yes (config) | — | BurnBar Pro | |
| `searchEncryptedConversationIndex` | yes | yes (config) | — | BurnBar Pro | |
| `queryConversations` | yes | yes (config) | — | BurnBar Pro | |
| `triggerVoIPCall` | yes | yes (config) | — | Mercury Media | |
| `grantMediaGrandfather` | yes | yes (config) | — | `mediaSkuAdmin` claim | |
| `validateMediaPurchase` (retired) | yes | yes (config) | — | — | Always throws failed-precondition |
| `submitAgentNotificationReply` | yes | yes (config) | — | — | **No rate limit (A-12)** |
| `adoptProviderAccountForDevice` | yes | yes (config) | — | — | A-21 |
| `revokeProviderAccountDeviceLink` | yes | yes (config) | — | — | |
| `backfillProviderAccountDeviceLinks` | yes | yes (config) | — | — | **No rate limit (A-05)** |
| `rebuildUsageRollups` | yes (raw `Error`) | yes (config) | — | — | A-06 + A-35 |
| `seedAndroidDemoAccount` | yes | yes (config) | — | — | A-34 |
| `appstore/callable` (5 callables) | yes | yes (config) | — | — | **No high-risk (A-33)** |
| `reserveAgentControlActionBudget` / `reserveFlooRelayBudget` (cloudProAllowance.ts) | yes | yes (config) | — | — | |

### 1.5 Device Grant Lifecycle (verified)

```
Hermes Gateway (verified end-to-end):
  POST /device/start  (public, CORS *, no App Check, no Auth)
    → creates hermes_gateway_device_sessions/{deviceCode}
    → returns userCode (8 chars, 31-alphabet) + deviceSecret (32-byte hex)
  POST /device/poll  (public, CORS *, no App Check, no Auth)
    → checks sha256(deviceSecret) == deviceSecretHash
    → returns accessToken (32-byte hex) on status=approved
  callable approveHermesGatewayDeviceGrant (Auth + App Check, NO high-risk — A-02)
    → reads hermes_gateway_device_sessions by userCode
    → issues bearer token
    → writes users/{uid}/hermes_gateway_clients/{clientId} (active)
    → writes hermes_gateway_token_index/{tokenHash}
  HTTP /destinations, /events (SSE), /messages, /typing, /runtime, /attachments/init
    → resolveGatewayGrant via bearer token + scope check
    → last-seen update is async (A-13)
  callable revokeHermesGatewayClient (Auth + App Check)
    → status=revoked
    → deletes token_index entry
    → in-flight SSE may still drain (A-13)
```

```
CLI Link (verified):
  POST /start  (public, CORS *, no App Check, no Auth)
    → creates cli_link_sessions/{deviceCode} (24-byte hex)
    → returns userCode (8 chars, 31-alphabet)
  POST /poll  (public, CORS *, no App Check, no Auth)
    → sha256(deviceSecret) == deviceSecretHash
    → returns accessToken on status=approved
  callable completeCliLink (Auth + App Check + HIGH-RISK + BurnBar Pro)
    → reads cli_link_sessions by userCode
    → issueRemoteMcpGrantForSignedInUser (HMAC-signed 15-min accessToken + 90-day refreshToken)
    → status=approved
  callable issueRemoteMcpGrant (Auth + App Check + HIGH-RISK + BurnBar Pro)
    → re-issues a fresh grant
  callable revokeRemoteMcpClient (Auth + App Check, NO high-risk — A-20)
    → status=revoked
    → batch-update up to 100 grants (A-14)
```

```
Escrow Device (verified):
  callable registerEscrowDevice (Auth + App Check + HIGH-RISK)
    → creates users/{uid}/escrow_devices/{deviceId} (pending)
  callable approveEscrowDeviceTrust (Auth + App Check + HIGH-RISK)
    → trustState=trusted
  callable revokeEscrowDeviceTrust (Auth + App Check + HIGH-RISK)
    → trustState=revoked + cascade to escrow_grants (status=granted only)
  Direct Firestore writes:
    → can write pending; cannot elevate to trusted (rules: 2399-2422)
```

```
Hermes Connection (verified):
  callable createHermesPairing (Auth + App Check + Hosted Quota, rate 5/1s)
  callable completeHermesPairing (Auth + App Check + Hosted Quota, rate 1/1s, 5 failed)
  callable listHermesConnections
  callable revokeHermesConnection (Auth + App Check, rate 2/1s)
  callable updateHermesConnectionStatus (Auth + App Check, rate 2/1s)
```

### 1.6 App Check Attestation Bound Claims (verified)

- `bindAppCheckAttestation` callable: any signed-in user with valid App Check can write `obb_app_check` claim to **their own** UID.
- `assertAppAttestBoundClaims`: requires claim exists, `appId` matches `request.app.appId`, and `boundAtMillis` is within 30 days.
- Used by: `enforceHighRiskComputerUseCallable` → called by `registerEscrowDevice`, `approveEscrowDeviceTrust`, `revokeEscrowDeviceTrust`, `completeCliLink`, `issueRemoteMcpGrant`, `validateOpenTimestampsProof`.
- **Not used by**: `approveHermesGatewayDeviceGrant`, all `appstore/callable.ts`, all Stripe / Google Play entitlement callables (A-02, A-33).

### 1.7 Firestore Rules — Server-Only Collections (verified)

| Collection | Rule | Verified |
|-----------|------|----------|
| `cli_link_sessions/{id}` | `allow read,write: if false` | firestore.rules:2625-2627 |
| `hermes_gateway_device_sessions/{id}` | `allow read,write: if false` | firestore.rules:2629-2631 |
| `hermes_gateway_token_index/{hash}` | `allow read,write: if false` | firestore.rules:2633-2635 |
| `provider_account_secret_refs` | (implied: collection group, no client match) | firestore.rules |
| `ops/computer_use_budget_status/metrics/*` | `allow read: if isOperator()` | firestore.rules:2080-2084 |
| `ops/media_budget_status/metrics/*` | `allow read: if isOperator()` | firestore.rules:2610-2614 |

The `isOperator()` predicate reads `burnbarOperator` custom claim. **No Cloud Function in this repo mints this claim** (A-16) — the claim must be set manually via the Firebase console or external admin tooling, with no audit trail or expiry.

### 1.8 Refresh Token Handling (verified)

- **Client:** iOS/macOS uses Firebase SDK default (no manual refresh token storage).
- **Server:** No callable that takes a refresh token; no callable that issues a refresh token; the only refresh-token-like flow is `RemoteMcpGrant.refreshToken` (90-day, sha256-hashed in `users/{uid}/remote_mcp_grants/{grantId}`), issued by `issueRemoteMcpGrantForSignedInUser`.
- **Rotation:** Not implemented — `RemoteMcpGrant.refreshTokenHash` is a one-shot write; the grant doc is the only record. A compromised refresh token is valid until grant revocation (90 days).
- **Email-link sign-in:** Not used (no `signInWithEmailLink` in client or server).
- **Phone auth:** Not used (no `signInWithPhoneNumber` in client or server).

### 1.9 Account Recovery (verified)

- **No callable for password reset.** Client must call `Auth.auth().sendPasswordReset(withEmail:)` directly. Email enumeration is therefore a client-side Firebase concern (Firebase Auth handles enumeration via equal-latency responses, but a misconfigured `sendPasswordReset` could leak).
- **No email enumeration at the application layer** — no `fetchSignInMethodsForEmail` callable in functions/src.
- **Account deletion:** `deleteUserCloudData` (callable) → `eraseUserAccount` (lib) → `auth.deleteUser(uid)`. Client also calls `user.delete()` after — see A-25.
- **No re-authentication gate** — `updateProviderAccount` does not call `user.reauthenticate()`; relies on ID token validity.

### 1.10 FCM / APNs Token Registration (verified)

- iOS: `voip_outbound` and `fcm_outbound` collections (server-side, no client write).
- Token registration path: `triggerVoIPCall` callable writes to `voip_outbound` / `fcm_outbound` with `request.auth.uid` and the caller's `voipDeviceToken` / `androidDeviceId`.
- **No callable for direct FCM token registration** — the client must trigger a VoIP call to register.
- **No token revocation callable** — stale FCM tokens can be removed by the `fcm_outbound` consumer, not the user.

### 1.11 OAuth State / PKCE (verified)

- **No OAuth state or PKCE used in the application** — all OAuth flows go through Firebase Auth (`signInWithPopup`, `signInWithCredential`).
- **PKCE is implemented for Remote MCP** (`remoteMcpOAuth.ts:24` `assertPkce`), but it is **never called** in the callables (verified via grep — `assertPkce` is defined but unused in `cliLink.ts:163` `completeCliLink` flow). The Remote MCP grant is issued with a static HMAC access token (15-min TTL) and a refresh token, but no PKCE challenge is sent to the client. This is a **dead-code finding** (informational).

### 1.12 Workspace / Team RBAC (verified)

- **Single-tenant only.** `users/{uid}/...` namespace is per-user. No `workspaces/{wsId}/...` for user content. The `workspaces/workspace-{uid}/teams/team-default/artifacts/{artifactID}` collection is a *user-named workspace* (not a shared workspace). No `team_members`, `roles`, or `permissions` collections.
- **Conclusion: no RBAC, no team model.** All authorization is `ownsUserNamespace(userId) == auth.uid == userId`.

---

## 2. Verification of Prior Findings (C2, C3, H2)

### C2 (Hermes Gateway approve uses weaker auth than peer high-risk) — **VERIFIED**

`approveHermesGatewayDeviceGrant` (hermesGateway.ts:481-528):
- Line 499: `enforceAuthAndAppCheck(request, uid);`
- Does **not** call `enforceHighRiskComputerUseCallable`.
- Comparison: `completeCliLink` (cliLink.ts:163) calls `enforceHighRiskComputerUseCallable`. `issueRemoteMcpGrant` (remoteMcp.ts:45) calls `enforceHighRiskComputerUseCallable`. `registerEscrowDevice` (computerUseSecurity.ts:73) calls `enforceHighRiskComputerUseCallable`.
- The `obb_app_check` claim (App Check attestation binding) is **bypassed** for the Hermes Gateway approve path.
- **Confirmed in code.** The fix is one line: replace `enforceAuthAndAppCheck(request, uid)` with `enforceHighRiskComputerUseCallable(request, uid)`.

### C3 (CLI Link device-code public + limited brute-force) — **VERIFIED, EXTENDED**

`startCliLink` (cliLink.ts:30) and `pollCliLink` (cliLink.ts:82):
- Public `onRequest` with `cors: true` (any origin).
- No App Check.
- No `request.auth` check on `startCliLink` (correct — it issues a code).
- `pollCliLink` accepts `deviceCode` and `deviceSecret`; checks `sha256(deviceSecret) == data.deviceSecretHash`.
- `completeCliLink` requires the userCode to match a pending session.
- **No rate limit on `startCliLink` or `pollCliLink`** (A-01, A-18, A-38).
- The userCode is 8 chars from 31-char alphabet = 31⁸ ≈ 8.5e11 (4 chars + dash + 4 chars), but the dash is fixed, so the actual entropy is 31⁴ × 31⁴ = 31⁸ ≈ 8.5e11. The **effective** keyspace (without the dash) is 31⁴ × 31⁴ = ~923M ≈ 2³⁰ — still large but **enumerable** in 10 minutes at 1.5M guesses/s.
- `deviceSecretHash` is SHA-256 only; no salt, no per-session nonce. If the attacker can observe one `deviceSecret` (e.g., from the same network), they have the hash and can re-use. SHA-256 of a 32-byte random secret is still 2²⁵⁶ pre-image resistant, but a captured `deviceSecret` is forever.
- The `deviceCode` is the doc ID (24-byte hex = 192 bits — strong), so guessing `deviceCode` is infeasible; the attack is via `userCode` enumeration, **not** `deviceCode`.

### H2 (Sparse / naive rate limiting) — **VERIFIED, EXTENDED**

- `checkHermesRateLimit` and `checkPiAgentRateLimit` (shared.ts:1377, 1395) use a **single last-timestamp** pattern: per-user, per-action, with no burst / distributed / global counter.
- `checkRefreshRateLimit` (shared.ts:1357) is per-user per-provider, no burst.
- Many callables have **no** rate limit at all: `bindAppCheckAttestation`, `registerEscrowDevice`, `approveEscrowDeviceTrust`, `revokeEscrowDeviceTrust`, `connectProviderAccount`, `connectHostedQuotaAccount`, `connectSelfHostedQuotaAccount`, all `appstore/callable` callables, all Stripe / Google Play callables, `searchStreams`, `submitAgentNotificationReply`, `adoptProviderAccountForDevice`, `revokeProviderAccountDeviceLink`, `backfillProviderAccountDeviceLinks`, `rebuildUsageRollups`, `seedAndroidDemoAccount`, all `enqueueHermesGatewayEvent` calls (HTTP multiplex also has no rate limit).
- The Hermes Gateway `cors: true` + no rate limit + 8 paths makes a 10x amplification surface.

---

## 3. New Issues (independent discovery, 30+ findings)

See Section 0 for the full table. Top new critical/high:
- **A-02 (C2 confirm)**: Hermes Gateway approve lacks high-risk bound claim.
- **A-06**: Raw `Error` instead of `HttpsError` in 5 callables (auth + SDK refresh bug).
- **A-07**: `signInAnonymously()` allowed on iOS — anon UIDs can hold paid provider credentials.
- **A-17 / A-27**: Stored XSS via `clientType` and `displayName` in `cli_link_sessions` (no server-side allowlist/length cap).
- **A-18 / A-38**: `completeCliLink` no rate limit; CORS `*` on `startCliLink`/`pollCliLink` enables in-browser enumeration.
- **A-20**: `revokeRemoteMcpClient` is one tier weaker than `issueRemoteMcpGrant` (auth-tier mismatch).
- **A-26**: `connectProviderAccount` does not verify `sourceDeviceID` ownership (device ID squatting).
- **A-29**: iOS client never force-refreshes ID token; revoked devices can drive callables until 30-day claim expiry.
- **A-33**: `appstore/callable` (5 entitlement-mutating callables) lack high-risk bound claim (C2-pattern).
- **A-36**: `enqueueHermesGatewayEvent` callable skips scope check (BOLA vs HTTP).

---

## 4. Negative AuthZ Test Matrix (recommended for PR review)

For every callable above, the following tests must pass (and currently do NOT, for the noted rows):

| Callable | no auth | wrong uid | no app check | no entitlement | no high-risk bound claim | rate limit | replay | revocation |
|----------|---------|-----------|--------------|----------------|--------------------------|------------|--------|-----------|
| `startCliLink` | n/a (public) | n/a | n/a | n/a | n/a | **FAILS (A-01, A-38)** | expires_at check OK | n/a |
| `pollCliLink` | n/a | n/a | n/a | n/a | n/a | **FAILS (A-01, A-38)** | n/a | n/a |
| `completeCliLink` | 401 ✓ | 403 ✓ | 401 ✓ | 403 ✓ | 401 ✓ | n/a (only on start/poll) | n/a | n/a |
| `approveHermesGatewayDeviceGrant` | 401 ✓ | 403 ✓ | 401 ✓ | 403 ✓ | **FAILS (A-02)** | none | n/a | n/a |
| `issueRemoteMcpGrant` | 401 ✓ | 403 ✓ | 401 ✓ | 403 ✓ | 401 ✓ | none | n/a | n/a |
| `revokeRemoteMcpClient` | 401 ✓ | 403 ✓ | 401 ✓ | n/a | **MISSING (A-20)** | none | n/a | n/a (revocation itself) |
| `registerEscrowDevice` | 401 ✓ | 403 ✓ | 401 ✓ | n/a | 401 ✓ | none | n/a | n/a |
| `approveEscrowDeviceTrust` | 401 ✓ | 403 ✓ | 401 ✓ | n/a | 401 ✓ | none | n/a | n/a |
| `revokeEscrowDeviceTrust` | 401 ✓ | 403 ✓ | 401 ✓ | n/a | 401 ✓ | none | n/a | n/a (revocation itself) |
| `bindAppCheckAttestation` | 401 ✓ | n/a | 401 ✓ | n/a | n/a | **none (A-11)** | claim is write-on-call, idempotent | n/a |
| `connectProviderAccount` | 401 ✓ | n/a | 401 ✓ | n/a | n/a | **none (A-26)** | n/a | n/a |
| `connectHostedQuotaAccount` | 401 ✓ | n/a | 401 ✓ | 403 ✓ | n/a | none | n/a | n/a |
| `connectSelfHostedQuotaAccount` | 401 ✓ | n/a | 401 ✓ | n/a | n/a | none | n/a | n/a |
| `uploadProviderQuotaSnapshot` | 401 ✓ | n/a | 401 ✓ | n/a | n/a | none | n/a | n/a |
| `deleteHostedQuotaCredentials` | 401 ✓ | n/a | 401 ✓ | n/a | n/a | none | n/a | n/a |
| `updateProviderAccount` | **500 (A-06)** | n/a | 401 ✓ | n/a | n/a | none | n/a | n/a |
| `deleteProviderAccount` | **500 (A-06)** | n/a | 401 ✓ | n/a | n/a | none | n/a | n/a (revocation itself) |
| `deleteUserCloudData` | 401 ✓ | n/a | 401 ✓ | n/a | n/a | none | n/a | n/a (destructive) |
| `createHermesPairing` | 401 ✓ | n/a | 401 ✓ | 403 ✓ | n/a | 5/1s ✓ | n/a | n/a |
| `completeHermesPairing` | 401 ✓ | n/a | 401 ✓ | 403 ✓ | n/a | 1/1s ✓ + 5-fail revoke ✓ | code expires 10m ✓ | n/a |
| `revokeHermesConnection` | 401 ✓ | n/a | 401 ✓ | 403 ✓ | n/a | 2/1s ✓ | n/a | n/a (revocation itself) |
| `createPiAgentPairing` | 401 ✓ | n/a | 401 ✓ | 403 ✓ | n/a | 5/1s ✓ | n/a | n/a |
| `completePiAgentPairing` | 401 ✓ | n/a | 401 ✓ | 403 ✓ | n/a | 1/1s ✓ + 5-fail revoke ✓ | code expires 10m ✓ | n/a |
| `revokePiAgentConnection` | 401 ✓ | n/a | 401 ✓ | 403 ✓ | n/a | 2/1s ✓ | n/a | n/a (revocation itself) |
| `verifyGooglePlayBurnBarProSubscription` | 401 ✓ | n/a | 401 ✓ | n/a | n/a | none | tokenHash dedupes (A-32) | n/a |
| `verifyGooglePlayCloudProTopUp` | 401 ✓ | n/a | 401 ✓ | 403 ✓ | n/a | none | topUp idempotency OK | n/a |
| `enqueueHermesGatewayEvent` (callable) | 401 ✓ | n/a | 401 ✓ | 403 ✓ | n/a | **none (A-36)** | n/a | n/a |
| `listHermesGatewayClients` | 401 ✓ | n/a | 401 ✓ | 403 ✓ | n/a | none | n/a | n/a |
| `revokeHermesGatewayClient` | 401 ✓ | n/a | 401 ✓ | 403 ✓ | n/a | none | n/a | n/a (revocation itself) |
| `triggerVoIPCall` | 401 ✓ | n/a | 401 ✓ | 403 ✓ | n/a | none | n/a | n/a |
| `grantMediaGrandfather` | 401 ✓ | n/a | 401 ✓ | n/a | n/a | none | n/a | n/a |
| `submitAgentNotificationReply` | 401 ✓ | n/a | 401 ✓ | n/a | n/a | **none (A-12)** | replyId dedupes via `set(merge:false).catch(already-exists)` ✓ | n/a |
| `adoptProviderAccountForDevice` | 401 ✓ | n/a | 401 ✓ | n/a | n/a | **none (A-21)** | n/a | n/a |
| `backfillProviderAccountDeviceLinks` | 401 ✓ | n/a | 401 ✓ | n/a | n/a | **none (A-05)** | n/a | n/a |
| `searchStreams` | 401 ✓ | n/a | 401 ✓ | n/a | n/a | **none** | n/a | n/a |
| `beginEncryptedSessionBlobUpload` | 401 ✓ | n/a | 401 ✓ | 403 ✓ | n/a | none | uploadURL expires 10m ✓ | n/a |
| `getEncryptedSessionBlobDownloadUrl` | 401 ✓ | n/a | 401 ✓ | 403 ✓ | n/a | none | downloadURL expires 10m ✓ | n/a |
| `commitEncryptedSearchIndexBatch` | 401 ✓ | n/a | 401 ✓ | 403 ✓ | n/a | none | n/a | n/a |
| `queryConversations` | 401 ✓ | n/a | 401 ✓ | 403 ✓ | n/a | none | n/a | n/a |
| `appstore/callable` (5) | 401 ✓ | n/a | 401 ✓ | n/a | **MISSING (A-33)** | none | n/a | n/a |
| HTTP `/device/start` (Hermes) | n/a (public) | n/a | n/a | n/a | n/a | **none (A-38)** | n/a | n/a |
| HTTP `/device/poll` (Hermes) | n/a (public) | n/a | n/a | n/a | n/a | **none** | secretHash check, but timing leak (A-10 equivalent) | n/a |
| HTTP `/events` (Hermes SSE) | bearer ✓ | 401 ✓ | n/a | n/a | n/a | **none (A-39)** | n/a | in-flight streams continue (A-13) |
| HTTP `/messages` (Hermes) | bearer + scope ✓ | 401/403 ✓ | n/a | n/a | n/a | none | n/a | in-flight may succeed (A-13) |
| HTTP `/attachments/init` (Hermes) | bearer + scope ✓ | 401/403 ✓ | n/a | n/a | n/a | none | uploadURL expires 10m ✓ (A-40) | n/a |

Legend: ✓ = passes (handler rejects correctly), **FAILS** = no check, **MISSING** = check exists but at wrong tier, **500 (A-NN)** = returns wrong error code.

---

## 5. Detailed Fix Recommendations (top 5)

### Fix for A-02 (Hermes Gateway approve — C2)

`functions/src/callables/hermesGateway.ts:499`:
```diff
-      enforceAuthAndAppCheck(request, uid);
+      enforceHighRiskComputerUseCallable(request, uid);
```
Requires the caller to have called `bindAppCheckAttestation` first and to present a matching live App Check token. Single line change; re-deploy. Add negative test: caller with valid Firebase Auth + App Check but no `obb_app_check` claim → must return `failed-precondition`.

### Fix for A-01/A-18/A-38 (CLI Link)

`functions/src/callables/cliLink.ts`:
1. Add a Firestore-backed rate-limit counter `cli_link_starts/{ipBucket}/{minute}` and `cli_link_polls/{ipBucket}/{minute}` (sliding 5-minute window). Reject over 5 starts/min and 60 polls/min per IP.
2. Add `clientType` allowlist (e.g., `cli`, `mcp`, `web`, `cli_link_v1`).
3. Add `displayName` server-side length cap (256 chars) and Unicode normalization.
4. Consider requiring a Cloudflare Turnstile or App Check (limited-use) for `startCliLink`.
5. Add per-userCode failed-attempt counter on `completeCliLink` (5 failures → userCode is invalid for 1 hour).
6. Restrict CORS to `https://burnbar.ai` (replace `cors: true` with explicit `cors: [/^https:\/\/burnbar\.ai$/, /^https:\/\/[a-z0-9-]+\.burnbar\.ai$/]`).

### Fix for A-06 (Raw Error in 5 callables)

`functions/src/callables/providerAccounts.ts` — replace `throw new Error("unauthenticated")` with `throw new HttpsError("unauthenticated", "Sign in before ...")`. Affected: `updateProviderAccount` (line 339), `deleteProviderAccount` (line 412), `deleteProviderCredential` (line 553), `refreshProviderAccountQuota` (line 597), `refreshProviderQuota` (line 627). Also `rebuildUsageRollups` (callables/misc.ts:33).

### Fix for A-07 (Anonymous sign-in)

Two options:
1. **Block anonymous sign-in** in Firebase Auth console (Identity Platform → Sign-in method → Anonymous → Disable). The iOS code path becomes dead.
2. **Add an `onAuthCreate` trigger** that, for anonymous users, requires them to link Apple/Google/Email before any `connectProvider*` callable succeeds. Implementation: `assertNotAnonymous(request)` helper that throws `permission-denied` if `request.auth.token.firebase.sign_in_provider === "anonymous"`.

### Fix for A-20 / A-33 (auth-tier mismatch)

`functions/src/callables/remoteMcp.ts:111` — change `enforceAuthAndAppCheck` to `enforceHighRiskComputerUseCallable` (revocation is destructive; treat as high-risk).
`functions/src/callables/appstore/callable.ts` (5 callables) — change `enforceAuthAndAppCheck` to `enforceHighRiskComputerUseCallable` (entitlement mutation is high-risk; same tier as `registerEscrowDevice`).

---

## 6. Cross-References

- **Prior findings** (this repo, 2026-06-01): `security-review-2026-06-01/FINDINGS_REGISTER.md` C1–C4, H1–H3. A-01, A-02, A-18, A-27, A-36, A-38 verify and extend C3, C2; A-06, A-11, A-20, A-26, A-29, A-33 are new patterns; A-12, A-15, A-16, A-22–A-25, A-34, A-37, A-41, A-42 are correctness / informational.
- **Master index:** `SecurityReviewM3612026/00-MASTER_INDEX.md`.
- **JSON companion:** `SecurityReviewM3612026/artifacts/auth-authz.json` (all 42 findings, structured).

---

## 7. Methodology & Confidence

- **Code reads:** `functions/src/auth.ts`, `functions/src/appCheckAttestation.ts`, `functions/src/index.ts`, every file in `functions/src/callables/`, `functions/src/accountDeletion.ts`, `functions/src/remoteMcpGrant.ts`, `functions/src/remoteMcpOAuth.ts`, `functions/src/config.ts`, `firestore.rules` (excerpts), `AgentLens/Services/AccountManager.swift` (excerpts), `OpenBurnBarMobile/Services/{LiveAuthGateway,AuthRepository}.swift` (excerpts), `website/src/lib/firebaseClient.ts`.
- **Verification approach:** Direct read of every `onCall` / `onRequest` / `enforce*` call; cross-referenced with the `isOperator()` predicate and the `isOperator()` function in rules; cross-referenced with `enforceAppCheck` config in `config.ts`.
- **Adversarial stance:** Treated every public surface as unauthenticated unless proven; every callable as having BOLA unless proven scoped by `assertOwnership`; every grant as having a high-risk bypass unless proven `enforceHighRiskComputerUseCallable`.
- **Distinction:**
  - **Verified** = code path confirmed by direct read; line numbers cited.
  - **Partial** = behavior inferred from related code; needs a runtime check.
  - **Unverified** = hypothesis; needs a deploy + smoke test.
- **No live testing in this pass** (no emulator available; review is static).
