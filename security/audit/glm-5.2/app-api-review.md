# Application, API, and Data Validation Review

## H.1 Input Validation Framework

### Server-Side (Cloud Functions)
- **Pattern:** Every callable uses `assertAuth` + `assertOwnership` + typed parse guards from `guards.ts`
- **Parse guards:** Every `parse*Doc` function in `guards.ts` uses `isRecord` + per-field `typeof` checks and returns `undefined` on mismatch. Callers throw `HttpsError("internal")` on `undefined`.
- **Bounded strings:** `boundedTrimmedString`, `requireBoundedStringArray`, `requireHexDigest`, `safeCloudDocumentID` (regex `^[A-Za-z0-9_.:-]+$`)
- **No eval/Function:** Zero instances in `functions/src`
- **No shell interpolation:** `execFile` (not `exec`) used for `ots` binary with fixed arg vector

### Firestore Rules
- **Allowlist pattern:** `validSessionLogManifestKeys()` uses `hasOnly([...])` as FIRST conjunct
- **Denylist (belt-and-suspenders):** `sessionLogPostWriteHasNoPlaintextFields`, `forbidsSealedPlaintextContentFields`
- **Path validation:** `assertUserStoragePath` validates 6-segment shape + uid match
- **Field validation:** Every collection enforces `request.resource.data.keys().hasOnly([...])`

## H.2 Injection Analysis

### SQL/NoSQL Injection
- **NoSQL:** Every `where()` clause uses fixed field names with type-checked values. No string interpolation builds field names or operators from user input.
- **SQL:** SQLCipher parameterized queries via GRDB. No raw string interpolation.
- **Verdict:** Not vulnerable

### Command Injection
- **Daemon shell:** `OpenBurnBarSwitcherShell` spawns CLI processes with fixed argument vectors, no shell interpolation
- **OTS binary:** `execFile` with `["verify", proofPath]` where proofPath is server-generated temp path
- **Verdict:** Not vulnerable

### Template Injection
- No email/SMS/push template engine exists in functions
- `res.json`/`res.send` calls serialize fixed structures
- **Verdict:** Not vulnerable

## H.3 SSRF Analysis

### SSRF Guard (`ssrfGuard.ts`)
- **Blocked:** `metadata.google.internal`, link-local (169.254.0.0/16), RFC1918, unique local IPv6
- **Allowed:** Loopback (localhost, 127.0.0.1, ::1) for dev/emulator
- **Gap (FINDING-009):** Guard does NOT resolve DNS before checking. TOCTOU / DNS rebinding window between guard check and `fetch()` DNS resolution. Also does not re-check on redirect (fetch follows 30x by default).
- **Current risk:** LOW — every `resilientFetch`/`providerFetch` target today is a hardcoded provider host or config/env URL. No user-supplied URL reaches server-side fetch.
- **Future risk:** When a feature accepts user URLs (remote-MCP discovery, webhooks, link unfurling), the guard would NOT protect against DNS rebinding.

### Provider HTTP (`providers/httpClient.ts`)
- `providerFetch` wraps all outbound provider API calls with resilience (circuit breaker, retry, timeout)
- All provider endpoints are hardcoded base URLs from config
- **Verdict:** Not currently exploitable

## H.4 Path Traversal

### Encrypted Session Blob Paths
- **Evidence:** `callables/shared/storage.ts:assertUserStoragePath`
- Upload path server-constructed: `users/${uid}/session_logs/${documentID}/bodies/${bodyHash}.json.aesgcm`
- `documentID` and `bodyHash` pass `safeCloudDocumentID` (rejects `..` and `/`) and `requireHexDigest`
- Download path validated against same 6-segment shape + uid match
- **Verdict:** Not vulnerable

### Hermes Gateway Attachment Paths
- `attachmentId` server-minted (`att_${randomBytes}`) or adopted only if passes `adoptedGatewayDocId` regex
- `storagePath` built server-side, no fileName segment
- Finalize/download assert `manifest.storagePath` starts with expected base
- **Verdict:** Not vulnerable

## H.5 Stripe Webhook Security

- **Signature verification:** `stripe.webhooks.constructEvent(rawBody, signature, webhookSecret)` BEFORE any processing
- **Raw body:** Reconstructed from `req.rawBody` (Buffer) to avoid Express re-serialization breaking signature
- **Replay/idempotency:** `reserveStripeWebhookEvent` uses Firestore transaction with 10-min lease on `stripe_webhook_events/${eventID}`. Re-deliveries return `{duplicate:true}` without re-applying.
- **UID extraction:** From `session.metadata.firebaseUID` or `session.client_reference_id`, both set by server from authenticated caller's `request.auth.uid`
- **Verdict:** Correct and robust

## H.6 Deserialization

- **JSON.parse:** All `JSON.parse` of network responses wrapped in try/catch with typed defaults or bounded `HttpsError`
- **Prototype pollution:** `guards.ts` uses `Object.entries` on already-typed objects. `rollupCounters.ts:215` checks `prototype !== Object.prototype` before recursing. `signalPrekeyDirectoryValidators.ts:97` rejects `__proto__`/`constructor`/`prototype`.
- **Firestore doc parsing:** Every `parse*Doc` is fail-closed typed guard returning `undefined` on mismatch
- **Verdict:** Not vulnerable

## H.7 Rate Limiting

- **Callable rate limits:** `_rate_limits` collection with TTL-bounded entries
- **Gateway rate limit:** 5 req/s on loopback even with debug flag
- **Hosted quota limits:** `HOSTED_QUOTA_DAILY_REFRESH_LIMIT=30`, `HOSTED_QUOTA_MONTHLY_REFRESH_LIMIT=300`
- **Computer Use budget:** Normal: 50 actions/run, 200/day, $5/day; Hard cap: $2500/mo
- **Gap:** Rate limits are per-user, not per-IP (acceptable for authenticated API)

## H.8 File Upload/Download

- **Upload:** `beginEncryptedSessionBlobUpload` returns a signed URL scoped to `users/${uid}/...`; content must be AES-GCM encrypted
- **Download:** `getEncryptedSessionBlobDownloadUrl` validates ownership + path shape before issuing signed URL
- **Size limits:** Blob fetch ceiling enforced (M-010 fix): Swift bridge fails closed >512 MiB
- **Verdict:** Properly scoped
