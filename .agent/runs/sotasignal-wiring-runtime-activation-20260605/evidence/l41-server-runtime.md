# Item 4 — L41 server-side runtime (publish / claim / session / rotation / revocation)

Worktree: `/private/tmp/burnbar-signal-wiring-20260605` on `signal/phase2-wiring-runtime` (off `signal/phase2`@e543dac2).
Generated: 2026-06-05.

## What landed

The L41 Firestore **rules + shape** already existed (firestore.rules:3479-3883, 50/50 emulator
test green). The **runtime callables were entirely missing** (map: "ZERO server callables"). This
change adds them. The Admin SDK **bypasses Firestore rules**, so every callable RE-VALIDATES every
invariant the rules enforce, admin-side (defense-in-depth, mirroring `signalAtRestWrite.ts`).

### New module: `functions/src/callables/signalPrekeyDirectory.ts`

| Callable | Purpose | Why server-owned |
| --- | --- | --- |
| `publishSignalPrekeyBundle` | Admin-validated, **idempotent** batch publish of the device's PUBLIC signed prekey + one-time prekeys + Kyber prekeys under an already-published identity. Skips existing doc ids (never resurrects a claimed key back to available). Returns available-prekey watermark counts. | Cross-checks identity exists + backing escrow device is pending/trusted with matching keyVersion; re-validates shape/base64/numeric-id/algorithm/lifecycle that rules can't iterate over a batch. |
| `claimSignalPrekeyBundle` | **ATOMIC** `runTransaction` fetch-and-mark of one available one-time prekey (optional; X3DH degrades without it) + one Kyber prekey (mandatory for PQXDH), returning the public PQXDH bundle. | Client-direct claim via rules is **racy** — two initiators read the same available key and both mark it claimed → key reuse. The single-claim guarantee only exists inside a transaction. |
| `recordSignalSession` | Persist session-DIRECTORY metadata only (`stateStorage="device-local-only"`); idempotent on sessionId. | Serialized Signal session/ratchet state never leaves the device; this records existence + peer binding. |
| `recordSignalRotation` | Append a rotation event before an identity key-version transition; mints a `rewrapJobId` when `rewrapRequired`. Append-only (rejects duplicate rotationId). | Covers the rewrap-PLANNING half of revocation/rotation (reason `revocation_rewrap` + `revokedIdentityKeyId` supported). |

All four registered in `functions/src/index.ts`.

### Revocation cleanup: `functions/src/signalDirectoryRuntime.ts`

When an escrow device is revoked, its Signal session-directory entries must stop showing "active".
Two helpers (`revokeSignalSessionsForDevice`, `revokeAllSignalSessions`) flip every active session
the device OWNS or is the PEER of to `status: revoked` (metadata-only). Wired into:

- `revokeEscrowDeviceTrust` (computerUseSecurity.ts) — targeted device revoke. Best-effort: a
  cleanup failure does NOT block the trust revocation. New return field `revokedSignalSessions`.
- `revokeAllAccess` (panic.ts) — added a `safe("signal_sessions", …)` surface; new `revoked.signalSessions`.

## Boundary (what this does NOT do)

- **Re-wrap EXECUTION** (re-sealing existing CloudVault content keys to the surviving device set)
  is device-driven crypto and remains a producer/native task (item 3 / blocked on item 2's native
  libsignal). The server side of it is the `rewrapJobId` + `revocation_rewrap` rotation event minted
  here; execution is recorded against that job by the device.
- **Exclude-from-future-wraps** is enforced by the PRODUCERS (they only wrap to pending/trusted
  escrow devices). Revoking a device → producers stop including it. That filter lives in item-3
  producer code (`atRestRecipients`), not here.
- Cross-user "gateway-transport" claiming is out of scope (rules are owner-only read); v1 is
  same-user multi-device.

## Verification (all green, this worktree)

```bash
cd functions
npx tsc --noEmit                                  # 0 errors (whole project)
npx vitest run \
  src/__tests__/signalPrekeyDirectory.test.ts \   # 16 — validators fail-closed + rules-shape parity + claim selection
  src/__tests__/signalDirectoryRuntime.test.ts \  # 3  — session-involves-device predicate
  src/__tests__/panic.test.ts \                   # regression: revoke edits
  src/__tests__/escrowDeviceTrustFingerprint.test.ts \
  src/__tests__/knowledgeMemory.test.ts           # → 49 passed (5 files)
npm run test:firestore-rules                       # 50/50, 0 fail (L41 rules unchanged, still green)
```

Key guard test: `signalPrekeyDirectory.test.ts` asserts each builder's emitted key set is a subset
of the EXACT `keys().hasOnly([...])` list in firestore.rules — so a server-write doc shape can never
silently drift from what the rules (and client readers) expect.

## Adversarial review (12-agent workflow wf_0fe94bbd-e65) — 8 raised, 4 confirmed, all FIXED

| Sev | Finding | Fix |
| --- | --- | --- |
| **major** | `claimSignalPrekeyBundle` did not re-enforce `expiresAt > now` (rules block claiming expired prekeys at firestore.rules:3680/3744; Admin SDK bypasses → an expired-but-`available` prekey could be claimed) | Added `.where("expiresAt", ">", now)` to both the kyber + one-time claim queries; added composite indexes `(status, expiresAt)` for `one_time_prekeys` + `kyber_prekeys` to `firestore.indexes.json`. |
| minor | claim `sessionId` allowed up to 512 chars but `claimedBySessionId` is bounded to 200 in rules | Bound claim `sessionId` to ≤200 chars (mirrors firestore.rules:3685/3749). |
| nit | `FORBIDDEN_FIELDS` missed 4 names from rules `hasNoPlaintextSecretFields()` (secretVersionName/authorization/bearer/credential); comment overclaimed parity | Added the 4 names (guard now a true superset) + corrected the comment + added a regression test. |
| nit | revoke session-cleanup catch returns count 0 on failure (ambiguous with "no sessions") | Clarified in a comment that 0 + a warn log = failed/unknown; per-user counts fit one batch so partial commit isn't expected. |

4 findings were refuted by the verify stage (not real). Re-verified after fixes: tsc 0 err; `signalPrekeyDirectory.test.ts` 17 pass; revoke-affected suites green.

## Recommended follow-ups

- An **emulator concurrency test** proving `claimSignalPrekeyBundle` rejects/serializes a
  double-claim (two parallel claims → distinct keys). The pure selection logic is unit-tested; the
  `runTransaction` retry-on-conflict is standard Firestore but unproven end-to-end here (the repo
  has no admin-SDK emulator harness; only the rules harness exists).
- A scheduled **low-watermark** job (count available OTP/Kyber prekeys per identity → push the
  device to publish more). Counts are already returned from publish/claim so the device can
  self-manage in the interim.
