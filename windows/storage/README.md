# Windows storage seam — read + WRITE peer of the Mac SQLCipher stack

The Windows port (R2 — the crown-jewel kill-risk) reuses the **same** encrypted
SQLite file the Mac writes today rather than re-encrypting or re-syncing. Wave-1
(#1198, `VAL-P0-DB-010`) proved the **read** side: Windows opens the committed
Mac-produced fixture with the pinned SQLCipher-4 params + non-secret key and
reproduces the byte-compat vector. This project (`VAL-P0-DB-011`) proves the
**write + migration round-trip** so Windows is a real read-**WRITE** peer.

## What this lane proves (`OpenBurnBar.Storage.Tests`)

`dotnet test windows/storage/OpenBurnBar.Storage.sln`, against the committed
fixture `AgentLensTests/Fixtures/DBByteCompat/openburnbar-db-compat-v53.sqlcipher`:

1. **Open** the Mac-produced encrypted file with the pinned params + non-secret
   fixture key (`SqlCipherConnection.Open` + `AssertPinnedParams`).
2. **Write** a `token_usage` row inside a transaction
   (`TokenUsageWriteSeam.WriteTokenUsage`).
3. **Reopen** a fresh connection and **read it back** field-for-field.
4. **Schema hash UNCHANGED** — SHA-256 over normalized `sqlite_master`, computed
   byte-for-byte the way the Mac validator does
   (`DatabaseByteCompatVector.computeSchemaHash`) — so a Windows write causes **no
   accidental migration or corruption** (`8f8f0eba…` before == after).
5. **Migration marker + `user_version` PRESERVED** — the last applied migration in
   GRDB's `grdb_migrations` table stays `v53_memory_forget_outbox` (count 54) and
   `PRAGMA user_version` stays 0, so a Windows write remains **reopenable and
   migratable on Mac**.
6. Negative guards: a **wrong key cannot open** the file (genuine encryption +
   real keying, not a plaintext no-op), and the production natural-key
   `ON CONFLICT` **upsert is idempotent**.

The suite always copies the fixture to a temp working file before mutating, so the
committed fixture is never modified. `SQLitePCLRaw.bundle_e_sqlcipher` ships a
cross-platform SQLCipher, so the suite runs on the macOS authoring host today
(SQLCipher 4.5.2 opening a 4.16.0-produced file — cross-version compat within the
`cipher_compatibility = 4` profile) and on `windows-latest` / `windows-11-arm` in
CI against the identical bytes.

## How it maps to the two Mac cipher stacks (both must stay byte-compatible)

The shared file (`~/Library/Application Support/OpenBurnBar/openburnbar.sqlite`) is
opened by **two** independent SQLCipher stacks on the Mac. Windows must be
byte-compatible with **both**:

| Concern | Mac app stack | Mac daemon stack | Windows seam (this lane) |
| --- | --- | --- | --- |
| Keying | `DatabaseEncryptionService.makeConfiguration` → GRDB `db.usePassphrase(key)` | `BurnBarDaemonDatabaseCipher` → raw `sqlite3_key` (UTF-8 passphrase, PBKDF2) | `SqlCipherConnection.Open` → `PRAGMA key = '<key>'` |
| Key mode | **passphrase** (PBKDF2), NOT raw `x'…'` | **passphrase** (PBKDF2), NOT raw | **passphrase** (PBKDF2) |
| Key charset guard | `validateEncryptionKey` (base64 + `-`) | same charset guard before interpolation | `SqlCipherPinnedParams.ValidatePassphrase` (base64 + `-`) |
| Codec-active self-check | non-empty `PRAGMA cipher_version` after key | non-empty `cipher_version` after key | non-empty `cipher_version` + a `sqlite_master` probe in `Open` |
| Cipher params | implicit SQLCipher-4 defaults (page 4096 / kdf_iter 256000 / HMAC-SHA512 / PBKDF2-HMAC-SHA512) | same linked SQLCipher defaults | `AssertPinnedParams` asserts those exact values |
| Write path | `UsageStore.upsertUsage` — 27-column `INSERT … ON CONFLICT(provider, sessionId, model, COALESCE(sourceDeviceId,''), COALESCE(providerAccountID,'')) DO UPDATE` in a GRDB `write {}` transaction | reads/writes via raw sqlite3 once the codec lands | `TokenUsageWriteSeam.WriteTokenUsage` — same column set + same conflict target, in a `BeginTransaction()` |

Why both matter: the app keys with SQLCipher and the daemon opens the *same* file
with the raw `sqlite3` C API for indexed search / resume / the switcher store. A
byte-format drift on the Windows write path would break the daemon's reads (and
vice versa). Pinning the params here — and asserting the schema hash + migration
marker survive a write — is the contract that keeps all three peers (Mac app, Mac
daemon, Windows) interchangeable against one encrypted file.

See `decisions/sqlcipher-params.md` for the pinned-parameter trace, the fixture
`README.md` for the non-secret key rationale, and
`AgentLensTests/Support/DatabaseByteCompatVector.swift` for the Mac-side generator
whose schema-hash algorithm this lane reproduces.

## Integration note (factory reconcile)

Wave-1 read seam #1198 lands `windows/storage/OpenBurnBar.Storage/` with the OPEN +
read half. This PR was authored on a base that predates #1198, so it ships a
self-contained `OpenBurnBar.Storage.sln` and its own opener (`SqlCipherConnection`)
built on the identical pinned params + passphrase keying. On merge, the two halves
converge on one canonical opener; the params and key are identical by
construction, so the convergence is mechanical.
