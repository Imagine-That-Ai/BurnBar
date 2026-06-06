# Final adversarial audit (native L41 stores + Mac producer + watermark) — wf_a7805973-0fb

14 agents, 11 findings raised, **4 confirmed** (skeptic-verified), all **FIXED + re-verified**.

| Sev | Finding | Fix |
| --- | --- | --- |
| minor | `OBBSignalProtocolStore.keychainWrite` was non-atomic (`SecItemDelete` then `SecItemAdd`) — a partial failure could erase the kyber replay-guard blob (and any record). | Atomic upsert: `SecItemAdd`, and on `errSecDuplicateItem` → `SecItemUpdate` in place. No destructive window. |
| minor | Store was a `final class` with no synchronization — concurrent `markKyberPreKeyUsed` (read-modify-write) / session writes could lose updates or corrupt ratchet state. | Added an `NSRecursiveLock`; every public store method runs under `withLock {}`, making the replay-guard RMW + per-recipient writes atomic. |
| **major** | **iOS** `atRestRecipients` (pre-existing) lacked the self-exclusion my Mac+Android producers have — it did a redundant Firestore round-trip for the LOCAL device and overwrote the authoritative in-memory local recipient with the server-fetched public key (a compromised server could substitute the local recipient key). | Added `if identityKeyId == localIdentity.identityKeyId { continue }` (parity with Mac line 117 / Android line 111). |
| minor | `publishSignalPrekeyBundle` post-publish available-count omitted `expiresAt > now`, over-reporting vs. what `claim`/`watermark` can actually use. | Added the `expiresAt > now` predicate to both count queries (same composite indexes already present). |

7 findings refuted by the verify stage (not real).

Re-verified after fixes:
- `swift test --filter OBBSignalProtocolStoreSessionTests` → **2/2 PASS** (lock + atomic write intact; full PQXDH session + persistence still work).
- `npx tsc --noEmit` → 0 errors; `signalPrekeyDirectory.test.ts` → **18 pass**.
- iOS fix is a parity-identical 1-line `continue` (the same line compiles in the macOS-built Mac producer + JVM-built Android producer); a full iOS-sim build was not run for a 1-line guard.

## Cross-session audit summary (all 3 audits)
- `wf_0fe94bbd-e65` — server L41 runtime: 4 fixed (expiresAt-on-claim, sessionId bound, FORBIDDEN_FIELDS, revoke count).
- `wf_507333cb-f6c` — Android producers: 7 fixed (fail-closed atRestRecipients, eager identity publish, immutable-conflict + TOCTOU, coroutine-crash).
- `wf_a7805973-0fb` — native L41 stores + Mac producer + watermark: 4 fixed (above).
**15 confirmed findings total, all fixed + re-verified.**
