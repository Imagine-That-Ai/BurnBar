# Hermes Gateway Security Scan — `run-02-hermes-gateway-pop`

**Scan date:** 2026-06-14
**Repo path:** `/Users/albertonunez/Documents/Windsurf/BurnBar`
**Scan lens:** Hermes Gateway authentication, bearer token handling, proof-of-possession, replay protection, entitlement checks, sealed relay writes
**Threat model mappings:** TM-003 (Spoofing), TM-006 (Information Disclosure), TM-009 (Replay/Tampering), TM-010 (Elevation of Privilege)
**Primary files inspected:**
- `functions/src/hermesGateway.ts` (1450 lines)
- `functions/src/callables/hermesGateway.ts` (2668 lines)
- `functions/src/callables/publicRateLimit.ts`
- `functions/src/security/endpointAuthorizationMatrix.ts`
- `firestore.rules` (gateway sections)
- `docs/security/BurnBar-threat-model.md` (614 lines)

---

## Phase 1 — Repo Map (Gateway Authentication Surface)

### HTTP Routes (via `dispatchHermesGatewayRequest`)

| Route | Method | Auth Gate | Bearer+PoP? |
|---|---|---|---|
| `/device/start` | POST | Public IP rate-limit + device-hash rate-limit | ❌ No — public pairing initiation |
| `/device/poll` | POST | Device secret hash (timing-safe `safeEqualHex`) | ❌ No — pre-auth polling |
| `/destinations` | GET | `resolveGatewayGrant("hermes.gateway.read")` | ✅ Yes |
| `/events` | GET | `resolveGatewayGrant("hermes.gateway.read")` | ✅ Yes |
| `/messages` | POST | `resolveGatewayGrant("hermes.gateway.write")` | ✅ Yes |
| `/typing` | POST | `resolveGatewayGrant("hermes.gateway.write")` | ✅ Yes |
| `/runtime` | POST | `resolveGatewayGrant("hermes.gateway.write")` | ✅ Yes |
| `/state` | GET | `resolveGatewayGrant("hermes.gateway.read")` | ✅ Yes |
| `/approvals` | GET | `resolveGatewayGrant("hermes.gateway.read")` | ✅ Yes |
| `/approvals` | POST | `resolveGatewayGrant("hermes.gateway.write")` | ✅ Yes |
| `/attachments/init` | POST | `resolveGatewayGrant("hermes.gateway.write")` | ✅ Yes |
| `/attachments/finalize` | POST | `resolveGatewayGrant("hermes.gateway.write")` | ✅ Yes |

### Firebase Callables (via `onCall`)

| Callable | Auth Gate | App Check | Trusted Device Proof? |
|---|---|---|---|
| `approveHermesGatewayDeviceGrant` | Auth + App Check + entitlement | ✅ | ❌ (phone approval) |
| `listHermesGatewayClients` | Auth + App Check + entitlement | ✅ | ❌ |
| `revokeHermesGatewayClient` | Auth + App Check + entitlement | ✅ | ❌ |
| `rotateHermesGatewayClientToken` | Auth + App Check + entitlement + lockout | ✅ | ❌ |
| `enqueueHermesGatewayEvent` | Auth + App Check + entitlement | ✅ | ❌ |
| `setHermesGatewayOversightMode` | Auth + App Check + entitlement + **high-risk nonce + trusted device** (for autonomous) | ✅ | ✅ (for `autonomous` mode) |
| `respondHermesGatewayApproval` | Auth + **high-risk nonce + trusted device action proof** | ✅ | ✅ Always |
| `getHermesGatewayAttachmentDownloadUrl` | Auth + App Check | ✅ | ❌ |
| `reapHermesGatewayApprovals` | Scheduled (no user auth) | N/A | N/A |

### Firestore Rules (all Gateway collections)

All `hermes_gateway_*` collections are **server-owned for writes** (`allow write: if false`). Client reads are limited to `isOwner(userId)`. The `hermes_gateway_token_index` and `hermes_gateway_device_sessions` root collections deny all client access (`allow read, write: if false`).

> **Key structural conclusion:** No authenticated HTTP route bypasses the `resolveGatewayGrant` gate. A stolen bearer token alone is **never sufficient** for any Gateway operation — the PoP signing key is always required.

---

## Phase 2 — Threat-to-Scan Matrix

| Threat Model Area | What I Scanned | Verdict |
|---|---|---|
| **Bearer token accepted without PoP** | Every route through `dispatchHermesGatewayRequest` | ✅ **No bypass found.** Every authenticated route calls `resolveGatewayGrant` → `verifyGatewayRequestPoP`. Legacy clients without `popRequired=true` or missing signing key are **rejected** (`legacy_pop_required`), not downgraded. |
| **PoP not bound to method/path/query/body/timestamp/nonce** | `gatewayPopSignablePayload` (v1) and `gatewayPopSignablePayloadV2` (v2) | ⚠️ **PoP v1 does not bind query string.** See Finding F-01. |
| **Replay cache bypass** | `pop_nonces` subcollection with transactional create-if-absent | ✅ **Structurally sound.** Firestore transaction prevents concurrent replay. See Finding F-02 for TTL deployment dependency. |
| **Timestamp skew mistakes** | 5-minute `GATEWAY_POP_CLOCK_SKEW_MS` symmetric window | ✅ Correct. Absolute-value check rejects past AND future timestamps beyond 5 min. |
| **Token hash comparison mistakes** | `client.tokenHash !== tokenHash` at L831 | ℹ️ **Non-timing-safe but not exploitable.** See Finding F-03. |
| **Scope confusion** | `hasHermesGatewayScope` checked after PoP in `resolveGatewayGrant` | ✅ Correct scope enforcement. Read/write/manage scopes enforced per-route. |
| **Entitlement oracle behavior** | PoP failure priority via `Promise.allSettled` | ✅ **Correct ordering.** PoP failure throws 401 before entitlement failure would throw 403. A bearer-only attacker never learns subscription state. See `callables/hermesGateway.ts:841-857`. |
| **Accepting plaintext where sealed envelopes required** | `gatewayPlaintextWriteAllowed()` always returns `false`; `resolveGatewayWriteBody` rejects plaintext | ✅ **Sealed-only for all new writes.** Messages, events, attachments, model switches all require `relayEnvelope`, `ratchetEnvelope`, or `signalEnvelope`. |
| **Downgrade paths for legacy clients** | v1 relay envelope accepted on READ only; v1-only pairings rejected at device/start and approve | ✅ **No write-path downgrade.** `requireProductionGatewayRelayEnvelope` only accepts v2/v3. Signal v4 is read-tolerant only (production set empty). |
| **Relay key substitution via bearer token** | `/runtime` handler relay key immutability logic | ✅ **Pinned keys are immutable.** `/runtime` can pin on first use only; change attempts are logged and rejected. See `callables/hermesGateway.ts:1222-1263`. |
| **Approval self-resolution by agent** | `respondHermesGatewayApproval` vs `handleArmApproval` | ✅ **Agent can arm but never resolve.** Resolution requires Auth+AppCheck+high-risk-nonce+trusted-native-device+action-proof. |

---

## Phase 3 — Findings

### F-01: PoP v1 does not integrity-protect the query string [MEDIUM]

**Category:** Tampering / Integrity bypass
**Threat model:** TM-003 (Spoofing), TM-009 (Tampering)
**Attacker needs:** Bearer token + PoP signing key (both required) or MITM position

**Evidence:**

The PoP v1 signable payload at `callables/hermesGateway.ts:608-627`:
```typescript
function gatewayPopSignablePayload(options) {
  return Buffer.from([
    "OpenBurnBar.HermesGatewayPoP.v1",
    options.tokenHash,
    options.method.toUpperCase(),
    options.path,        // ← path only, no query
    options.bodyHash,
    options.nonce,
    options.timestamp,
  ].join("\n"), "utf8");
}
```

PoP v2 at `callables/hermesGateway.ts:669-691` adds `options.query`.

**Impact:** An attacker with a valid PoP v1 signature for `GET /events` could tamper with query parameters (`cursor`, `destinationId`, `limit`) without invalidating the signature. This allows:
- Reading events from a different `destinationId` than the signer intended
- Adjusting cursor/limit parameters

**Mitigations already present:**
- PoP v2 fixes this by binding the canonical query string into the signature
- **Anti-downgrade protection exists:** once a client registers `popVersion >= 2`, the server refuses v1 signatures (`callables/hermesGateway.ts:705-706`)
- The attacker still needs both the bearer token AND the PoP signing key (the query tampering is only useful if the attacker is an intermediary between the legitimate client and the server)
- All events/messages are sealed, so reading them from a different destination still yields ciphertext

**Residual risk:** During the v1→v2 transition window, clients that have not yet registered v2 capability are vulnerable to query parameter tampering by a party who holds both the bearer token and the signing key. This is **low practical risk** because:
1. Newly paired clients always register their `popVersion` at device/start
2. The query parameters are routing metadata, not content
3. The attacker already needs the PoP signing key, which is the same key required for full impersonation

**Exploitability verdict:** A stolen token alone is **not enough.** The attacker also needs the client signing key. And even with both, the content is sealed.

---

### F-02: PoP nonce TTL depends on unverifiable Firestore TTL policy deployment [LOW]

**Category:** Replay resistance / Operational dependency
**Threat model:** TM-009 (Replay)

**Evidence:**

The nonce document is created with an `expireAt` field at `callables/hermesGateway.ts:764-771`:
```typescript
transaction.create(nonceRef, {
  nonce,
  tokenHash: options.tokenHash,
  observedAt: nowISO(),
  expireAt: Timestamp.fromMillis(Date.now() + GATEWAY_POP_CLOCK_SKEW_MS),
  schemaVersion: HERMES_GATEWAY_SCHEMA_VERSION,
});
```

**Finding:** The TTL policy **IS declared** in the repo at `firestore.indexes.json:1813-1817`:
```json
{
  "collectionGroup": "pop_nonces",
  "fieldPath": "expireAt",
  "ttl": true,
  "indexes": []
}
```

However, the codebase's own threat model and tech debt tracker flag this as **deployment-state UNKNOWN**. `TECH_DEBT_AUDIT_2026-06-11.md` item #74 explicitly calls out: *"Zero Firestore TTL policies while six-plus collections write `expireAt` fields expecting one; pop_nonces grow one doc per authenticated gateway request."* Whether `firebase deploy --only firestore:indexes` has actually been run against the production project cannot be determined from code review.

Additionally, Firestore TTL deletion is documented as "best effort, may take up to 72 hours after expiration" — this is **conservative** (deletes late, not early), meaning nonces persist well beyond their validity window, which favors security.

**Impact scenarios:**

| Scenario | Consequence |
|---|---|
| TTL NOT deployed | Nonce documents accumulate indefinitely (~1 doc per authenticated request). Replay protection is **still correct** (the document exists → replay blocked), but storage cost grows without bound. This is a **DoS/cost vector**, not a security bypass. |
| TTL deployed correctly | Nonces are cleaned up lazily after their validity window. ✅ |
| TTL deletion fires late (up to 72h) | Security improves — nonces persist longer than needed, blocking replays for extended period. |

**Related finding:** The `_rate_limits` subcollection also has a TTL declared in `firestore.indexes.json:1819-1823`, but the rate limiter functions in `publicRateLimit.ts` do **NOT write an `expireAt` field** — they only write `windowStartMillis`/`updatedAt`. So even if the TTL policy is deployed, it would never fire on rate limit docs (no `expireAt` to evaluate). This is a tech debt item, not a security issue.

**Exploitability verdict:** Even without TTL, replay is blocked because the nonce document EXISTS. A stolen token alone is not enough. The attacker also needs the client signing key. **No exploitable replay path was found.**

**Recommendation:** Verify `pop_nonces` TTL policy is deployed in production via `gcloud firestore fields ttls list`. Add a deployment readiness check to `verify-ops-readiness.sh`.

---

### F-03: Token hash comparison uses `!==` instead of `timingSafeEqual` [INFORMATIONAL]

**Category:** Timing side-channel
**Threat model:** TM-003 (Spoofing)

**Evidence:**

At `callables/hermesGateway.ts:831`:
```typescript
if (client.tokenHash !== tokenHash) {
```

This uses JavaScript `!==` (non-timing-safe) to compare two SHA-256 hex hashes. However:

- `tokenHash` is derived from the attacker's own supplied bearer token
- `client.tokenHash` is the stored hash
- The comparison determines "does my token's hash match the stored hash?"
- The attacker already knows `tokenHash` (they computed it from their input)
- Timing variance on `!==` could theoretically reveal how many leading characters match, but the attacker can't iterate toward `client.tokenHash` because they'd need to find a pre-image for each candidate hash

**Additionally:** Even if the attacker could somehow discover the stored token hash, that's still just a SHA-256 hash — they'd need to reverse it to get the actual bearer token. And even then, they'd still need the PoP signing key.

**Contrast:** The codebase correctly uses `safeEqualHex` (timing-safe `timingSafeEqual`) for device secret comparison at `callables/hermesGateway.ts:999` and body hash comparison at `callables/hermesGateway.ts:720`. The inconsistency suggests this was an oversight rather than a deliberate design choice.

**Exploitability verdict:** Not exploitable. The attacker needs the bearer token plaintext (to compute the hash), and by the time they're comparing hashes they already supplied the token. A stolen token alone gets them to this point, but **the PoP check follows immediately and blocks any action.**

**Recommendation:** Switch to `safeEqualHex(client.tokenHash, tokenHash)` for defense-in-depth consistency. Cost: one line change, zero risk.

---

### F-04: Read-only endpoints lack per-route bearer-scoped rate limits [LOW]

**Category:** Denial of service / Cost exhaustion
**Threat model:** TM-DoS (Denial of Service)

**Evidence:**

Bearer-scoped rate limiting (`checkHermesGatewayBearerRateLimit`) is applied to:
- `/messages` (POST) — `hermes_gateway_message_send`
- `/attachments/init` (POST) — `hermes_gateway_attachment_init`
- `enqueueHermesGatewayEvent` callable — `hermes_gateway_event_enqueue`

But **NOT** applied to:
- `/events` (GET) — the primary polling endpoint (1-second interval)
- `/state` (GET) — gateway state snapshot
- `/destinations` (GET)
- `/typing` (POST)
- `/runtime` (POST)
- `/approvals` (GET/POST)
- `/attachments/finalize` (POST)

**Mitigating factor:** Every request through `resolveGatewayGrant` consumes a nonce (one Firestore write per request), which provides an **implicit cost-per-request floor** that limits abuse velocity. However, the cost is borne by the victim's Firestore quota, not the attacker's.

**Exploitability verdict:** Requires bearer token + PoP signing key. A compromised client can flood read endpoints and burn Firestore read quota. **Not a confidentiality or integrity issue.** The per-request nonce write cost makes this roughly 2x Firestore cost amplification (one nonce write + one read per request).

---

### F-05: `/device/poll` has no explicit rate limit [LOW]

**Category:** Brute-force / Denial of service
**Threat model:** TM-003 (Spoofing), TM-DoS

**Evidence:**

At `callables/hermesGateway.ts:984-1060`, `handleDevicePoll` validates only the device secret hash. No `checkPublicHttpRateLimit` call is present (unlike `/device/start` which has both IP and device-hash rate limits).

**Mitigating factors:**
- The device secret is 32 random bytes (base64url-encoded, 256 bits of entropy) — brute force is infeasible
- The device code is 24 random bytes (hex-encoded, 192 bits) — also infeasible to guess
- Session TTL is 10 minutes — limits the attack window
- The device secret hash comparison uses timing-safe `safeEqualHex`

**Exploitability verdict:** Not practically exploitable due to high entropy of both identifiers. An attacker would need both the device code AND the device secret, which are only returned to the `/device/start` caller. **A stolen token is irrelevant here (this is the pre-auth flow).**

---

### F-06: Token rotation is not fully atomic [INFORMATIONAL]

**Category:** Race condition / Availability
**Threat model:** TM-009 (Tampering)

**Evidence:**

At `callables/hermesGateway.ts:2231-2258`, token rotation uses a Firestore `batch` (not a transaction):

```typescript
const batch = db.batch();
batch.set(db.doc(`hermes_gateway_token_index/${tokenHash}`), { ... });
batch.set(ref, { tokenHash, ... }, { merge: true });
if (previousTokenHash && previousTokenHash !== tokenHash) {
  batch.delete(db.doc(`hermes_gateway_token_index/${previousTokenHash}`));
}
await batch.commit();
```

A batch commit is atomic within a single Firestore commit, so all three operations (create new index, update client doc, delete old index) succeed or fail together. **This is actually correct.**

The comment at L2231-2235 discusses a crash-mid-rotation scenario, but since batch.commit() is atomic, a partial write cannot occur. The only risk is:
- If the batch fails after partial server-side processing (extremely rare Firestore edge case)
- The old token would continue working (since the client doc hash wasn't updated)
- The new token index entry might or might not exist

**Exploitability verdict:** Not exploitable. The batch commit provides atomicity.

---

## Phase 4 — Skeptic/Debate Summary

### Claims Validated

| Claim | Evidence | Confidence |
|---|---|---|
| Bearer token alone is insufficient for active Gateway access | `resolveGatewayGrant` always calls `verifyGatewayRequestPoP`; legacy clients without `popRequired=true` are rejected with `legacy_pop_required` | **High** |
| PoP binds method, path, body hash, nonce, and timestamp | `gatewayPopSignablePayload` (v1) and `gatewayPopSignablePayloadV2` (v2) construct canonical payloads | **High** (v2 also binds query) |
| New writes require sealed envelopes | `gatewayPlaintextWriteAllowed()` unconditionally returns `false`; `resolveGatewayWriteBody` rejects plaintext; `handleAttachmentInit` requires envelope | **High** |
| Relay key pinning is immutable | `/runtime` handler checks `pinnedAgentKey` and only writes on first use; changes are logged and dropped | **High** |
| Oversight gate cannot be self-approved by agent | `respondHermesGatewayApproval` requires high-risk nonce + trusted native device + action proof; agent uses bearer+PoP (HTTP), which cannot satisfy callable requirements | **High** |
| Token hash uses SHA-256 | `hashHermesGatewayBearerToken` calls `sha256Hex` | **High** |
| Device secret comparison is timing-safe | `safeEqualHex(hashHermesGatewayDeviceSecret(deviceSecret), data.deviceSecretHash)` at L999 | **High** |
| Signal v4 is not a production write path | `HERMES_GATEWAY_PRODUCTION_SIGNAL_ENVELOPE_VERSIONS` is empty Set; `requireProductionGatewaySignalEnvelope` rejects | **High** |
| Create-if-absent guards on messages and events | Firestore transactions with existence checks at L1184-1190 (messages) and L2410-2416 (events) | **High** |

### Claims with Caveats

| Claim | Caveat |
|---|---|
| Replay protection for PoP nonces | Depends on Firestore TTL policy deployment for cleanup (correctness is not affected, only storage growth) |
| All clients enforce PoP v2 | During transition, v1 clients exist that lack query-string binding. Anti-downgrade protection exists but is per-client, not global. |

---

## Phase 5 — Exploitability Review: "Stolen Token Alone vs Token+Signing Key"

> **For every finding in this scan, the answer is: a stolen bearer token alone is NOT enough.** The attacker also needs the client's Ed25519 signing private key.

| Scenario | Stolen bearer token only | Stolen bearer token + PoP signing key |
|---|---|---|
| Read events/messages | ❌ 401 `legacy_pop_required` or `bad_pop_signature` | ✅ Can read sealed ciphertext (not plaintext) |
| Send messages | ❌ 401 | ✅ Can send sealed messages (needs relay private key to create valid envelopes) |
| Upload attachments | ❌ 401 | ✅ Can init/finalize (needs relay private key for sealed manifest) |
| Approve oversight gates | ❌ 401 on HTTP; callable requires Auth+AppCheck+device proof | ❌ Still cannot — agent's bearer+PoP is HTTP-only, resolution is callable-only |
| Rotate token | ❌ 401 | ❌ Rotation is a callable (Auth+AppCheck), not HTTP+PoP |
| Change oversight mode | ❌ 401 | ❌ Callable requires Auth+AppCheck+high-risk nonce+trusted device (for autonomous) |
| Replace relay keys | ❌ 401 | ❌ Keys are pinned; `/runtime` rejects changes to pinned keys |
| Read metadata (destinations, state, client list) | ❌ 401 | ✅ Can read routing/capability metadata (but no plaintext content) |

---

## Phase 6 — Final Verdict

```
┌─────────────────────────────────────────────────────────────────┐
│  HERMES GATEWAY PoP AUTHENTICATION: STRUCTURALLY SOUND          │
│                                                                 │
│  0 Critical findings                                            │
│  0 High findings                                                │
│  1 Medium finding (F-01: PoP v1 query-string gap — mitigated)   │
│  2 Low findings (F-02: nonce TTL ops dependency, F-04: rate)    │
│  2 Informational (F-03: timing-safe consistency, F-06: batch)   │
│  1 Low (F-05: /device/poll no rate limit — high entropy guards) │
└─────────────────────────────────────────────────────────────────┘
```

### What works well

1. **Bearer+PoP is enforced on every authenticated HTTP route without exception.** The `resolveGatewayGrant` function is the single chokepoint, and it always calls `verifyGatewayRequestPoP`.

2. **Entitlement information is never leaked to a bearer-only attacker.** The `Promise.allSettled` pattern ensures PoP failure (401) always fires before entitlement failure (403). This is a subtle but important anti-oracle defense at `callables/hermesGateway.ts:841-857`.

3. **Sealed-only writes are enforced globally.** `gatewayPlaintextWriteAllowed()` is hardcoded to `false`. The `isWithinGatewayGraceWindow()` function also returns `false`. There is no configuration, environment variable, or code path that can re-enable plaintext writes.

4. **Relay key immutability prevents MITM via bearer token.** Even with bearer+PoP, an attacker cannot substitute the relay public key on an existing pairing.

5. **Oversight self-approval is structurally impossible.** The agent (bearer+PoP over HTTP) and the approver (Auth+AppCheck+nonce+device-proof via callable) operate on completely different authentication planes.

6. **Signal v4 production gating is fail-closed.** The production version set is an empty `Set<number>()`. No code path can produce a v4 write until the set is explicitly populated.

### What to harden

| Priority | Action | Finding |
|---|---|---|
| ⬛ Quick win | Replace `client.tokenHash !== tokenHash` with `safeEqualHex(client.tokenHash, tokenHash)` at L831 for consistency | F-03 |
| ⬛ Quick win | Add `pop_nonces` TTL to deployment IaC and verify in `verify-ops-readiness.sh` | F-02 |
| 🟨 Medium | Consider adding `checkPublicHttpRateLimit` to `/device/poll` for defense-in-depth | F-05 |
| 🟨 Medium | Add bearer-scoped rate limits to `/approvals` POST (arms a gate per request) | F-04 |
| 🟩 Track | Monitor PoP v1 → v2 migration completion; consider deprecation timeline for v1 acceptance | F-01 |

### Non-claims (per threat model position)

- This scan does **not** verify deployed Firestore TTL policies, App Check enforcement, or production environment variables.
- This scan does **not** verify the correctness of the relay/ratchet/Signal client-side crypto (that is a separate scan lens).
- This scan does **not** prove that no legacy plaintext documents exist in production Firestore.
- The code is structurally sound. **Production deployment configuration must be independently verified.**
