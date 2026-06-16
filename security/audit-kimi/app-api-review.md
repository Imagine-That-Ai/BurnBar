# Application and API Security Review

## A.7.1 Callable Functions

All callables are exported from `functions/src/index.ts`. Key patterns:

- `enforceAuthAndAppCheck` wraps most callables.
- Input validation uses Zod schemas (`packages/.../validators`) or manual checks.
- `assertOwnership` is called before Firestore reads/writes.

### Notable Callables

| Callable | Risk | Assessment |
|---|---|---|
| `computerUseSecurity.ts` | Device authority | Owner-scoped; publishes trust roots |
| `cloudVaultRotation.ts` | Key rotation | Owner-scoped; rate-limited? |
| `encryptedSearch.ts` | Pro search | Token + entitlement checks |
| `remoteMcp.ts` | External agent access | Audience-bound token |
| `stripe.ts` | Payments | Ownership + Stripe signature |
| `dataDeletion.ts` | Privacy | Owner-only; must cascade |
| `knowledgeMemory.ts` | RAG write | Owner-only |
| `mediaSku.ts` | Entitlement grants | Server-only claim check |

### Validation Gaps

- No centralized input-sanitization library; each callable handles its own.
- Some callables accept arrays or nested objects; verify max size / depth limits.
- No rate-limiting middleware visible; firestore/Stripe resilience helpers exist but not API abuse throttling.

## A.7.2 Local Daemon RPC

- UNIX socket at a known path.
- Single auth token stored in shared defaults/keychain.
- Methods include log ingestion, search, sync, Computer Use tool dispatch.
- **Authorization matrix not documented**: which client can call which method under what trust level?

**Finding**: FINDING-007 — daemon RPC lacks per-method capability isolation.

## A.7.3 File Handling

- Parsers read files from `~/.codex/sessions/`, `~/.claude/projects/`, etc.
- Path traversal risk is low because directories are hard-coded and within the user's home.
- Symbolic links could cause reads outside intended directories; no evidence of symlink filtering.
- Large files / zip bombs: parsers may load entire files into memory; need size limits.

## A.7.4 Business Logic

### Quota / Usage

- `functions/src/callables/quota.ts` manages provider quota snapshots.
- Rollups are computed in Cloud Functions; client merges window docs.
- Risk: client-side merge could be manipulated; server is authoritative for rollups.

### Entitlements

- Apple JWS verification in `functions/src/appstore/verifyAppleJWS.ts` looks robust.
- Google Play verification exists in Android/iOS code; server verification path unclear.
- Stripe webhook signature verified.

### Data Deletion

- `dataDeletion` callable deletes Firestore user subtree and Storage blobs.
- Local deletion is separate; must ensure both are invoked.
- Prior audit M-013/M-014 noted incomplete deletion paths; verify.

## A.7.5 Prior Audit Items (App/API)

| ID | Title | Status | Notes |
|---|---|---|---|
| M-013 | Data deletion incomplete | Partial | Verify local + cloud cascade |
| M-014 | Exported data contains more than expected | Partial | Audit `dataExport` fields |
| M-016 | Callable input validation gaps | Partial | Add adversarial fuzzing |
| M-017 | Rate limiting missing | Open | No global rate limiter |
| M-018 | session_logs validation | Partial | Rule + callable validation |
| M-019 | Log parser memory exhaustion | Open | Add size/depth limits |
