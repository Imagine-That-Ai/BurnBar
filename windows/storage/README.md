# `windows/storage` — Windows SQLCipher storage layer (R2): read + WRITE peer

The real Windows database seam. Off-Apple builds prune GRDB/storage
(`OPENBURNBAR_DAEMON_LINUX_BOUNDARY_BUILD`), so Windows opens no database from the
Swift Engine. This tree **un-prunes storage**: it opens the *same* Mac-produced
SQLCipher file byte-for-byte, exposes the read-only, DataStore-shaped seam the
Engine calls through the PAL, **and** proves a transactional write round-trips
without disturbing the schema hash or migration marker — so Windows is a real
read-**WRITE** peer of the two Mac cipher stacks, not a read-only mirror.

This directory is the integration of two parallel waves:

- **Read seam (#1198, `VAL-P0-DB-010`):** open + read + the byte-compat vector.
- **Write/migration seam (#1201, `VAL-P0-DB-011`):** the transactional write path
  + the schema-hash / migration-marker stability contract.

They were reconciled onto **one** storage project with **one** canonical
pinned-parameter class (`SqlCipherParameters`); #1201's duplicate
`SqlCipherPinnedParams` was folded into it and its standalone
`OpenBurnBar.Storage.sln` was dropped in favour of the aggregating
[`windows/OpenBurnBar.sln`](../OpenBurnBar.sln).

- **Decision:** [`docs/windows-port/decisions/0004-windows-storage-datastore-seam.md`](../../docs/windows-port/decisions/0004-windows-storage-datastore-seam.md).
- **Pinned cipher contract:** [`decisions/sqlcipher-params.md`](../../decisions/sqlcipher-params.md).

## Projects

| Project | What it is |
|---------|-----------|
| [`OpenBurnBar.Storage`](OpenBurnBar.Storage/) | `net10.0` library. `SqlCipherParameters` pins the compatibility-4 profile (page 4096 / kdf_iter 256000 / HMAC-SHA512 / PBKDF2-HMAC-SHA512), the non-secret fixture key, passphrase keying (`KeyAndPin`), passphrase-charset validation (`ValidatePassphrase`), and provider init. `OpenBurnBarStorage.OpenReadOnly` is the read seam (`IConversationReadStore`: schema inventory, conversation fetch/list, FTS5 `bm25()`/`snippet()` search) and `DbCompatVector` recomputes the schema hash + FTS vector. `SqlCipherConnection.Open` is the read-**write** opener + the migration oracles (`ComputeSchemaHash`, `ReadMigrationEndpoint`/`ReadMigrationCount`, `ReadUserVersion`, `FileIsEncrypted`, `AssertPinnedParams`), and `TokenUsageWriteSeam`/`TokenUsageRecord` write a `token_usage` row through the production upsert. |
| [`OpenBurnBar.Storage.Tests`](OpenBurnBar.Storage.Tests/) | xUnit proof for **both** seams. Opens the committed Mac fixture and reproduces the committed schema hash + FTS vector + read API (`VAL-P0-DB-010`), then writes a `token_usage` row and asserts the row round-trips while the schema hash + migration marker + `user_version` are unchanged (`VAL-P0-DB-011`). |

## How it opens the Mac database

`Microsoft.Data.Sqlite.Core` (ADO.NET wrapper) + `SQLitePCLRaw.bundle_e_sqlcipher`
(the open-source SQLCipher C amalgamation, per-RID) — the master plan's sanctioned
"raw-SQLCipher-C + a thin data layer reproducing the exact pinned config" fallback,
in managed form. The read path pins the cipher profile explicitly at open:

```
PRAGMA key = '<passphrase>';            -- passphrase mode (matches GRDB sqlite3_key)
PRAGMA cipher_compatibility = 4;
PRAGMA cipher_page_size = 4096;
PRAGMA kdf_iter = 256000;
PRAGMA cipher_version;                   -- hard self-check: SQLCipher must be active
```

The write path (`SqlCipherConnection.Open`, `ReadWrite`) keys, verifies the codec
is active via a non-empty `PRAGMA cipher_version` + a `sqlite_master` probe, then
`AssertPinnedParams` asserts the file resolved to those exact SQLCipher-4 values —
so a drifted Windows SQLCipher build fails loudly instead of silently writing a
file the Mac can no longer read.

`.Core` (not the full `Microsoft.Data.Sqlite`) is required so the SQLCipher bundle
is the sole native provider; the full package pulls the non-cipher
`bundle_e_sqlite3`, under which `PRAGMA key` is a silent no-op.

## Build + verify

```bash
dotnet test windows/storage/OpenBurnBar.Storage.Tests
```

Runs today on the macOS authoring host: the **same** managed assembly ships on
Windows; the native SQLCipher comes from the bundle per-RID (osx-arm64 here,
win-x64/win-arm64 on Windows CI). The read test opens the committed
`openburnbar-db-compat-v64.sqlcipher` and asserts:

- every `sqlite_master` object decrypts,
- the schema hash SHA-256 matches `openburnbar-db-compat-vector.json`,
- the FTS5 `bm25()`/`snippet()` row set matches the vector, and
- the four byte-compat parameters match the committed Mac readback **even though
  the SQLCipher point version and crypto provider differ** — the definitive proof
  that byte-compat is anchored to the pinned parameters, not the build.

The write test then writes a `token_usage` row in a transaction, reopens, reads it
back field-for-field, and asserts the schema hash matches the committed vector (no accidental
migration), the migration marker stays `v61_usage_memory` (count 62), and
`PRAGMA user_version` stays 0 — proving a Windows write stays reopenable and
migratable on Mac. Negative guards cover a wrong key (must fail to open) and the
production natural-key `ON CONFLICT` upsert (must be idempotent).

## How it maps to the two Mac cipher stacks (both must stay byte-compatible)

The shared file (`~/Library/Application Support/OpenBurnBar/openburnbar.sqlite`) is
opened by **two** independent SQLCipher stacks on the Mac. Windows must be
byte-compatible with **both**:

| Concern | Mac app stack | Mac daemon stack | Windows seam (this tree) |
| --- | --- | --- | --- |
| Keying | `DatabaseEncryptionService.makeConfiguration` → GRDB `db.usePassphrase(key)` | `BurnBarDaemonDatabaseCipher` → raw `sqlite3_key` (UTF-8 passphrase, PBKDF2) | `SqlCipherConnection.Open` / `OpenBurnBarStorage.OpenReadOnly` → `PRAGMA key = '<key>'` |
| Key mode | **passphrase** (PBKDF2), NOT raw `x'…'` | **passphrase** (PBKDF2), NOT raw | **passphrase** (PBKDF2) |
| Key charset guard | `validateEncryptionKey` (base64 + `-`) | same charset guard before interpolation | `SqlCipherParameters.ValidatePassphrase` (base64 + `-`) |
| Codec-active self-check | non-empty `PRAGMA cipher_version` after key | non-empty `cipher_version` after key | non-empty `cipher_version` + a `sqlite_master` probe in `Open` |
| Cipher params | implicit SQLCipher-4 defaults (page 4096 / kdf_iter 256000 / HMAC-SHA512 / PBKDF2-HMAC-SHA512) | same linked SQLCipher defaults | `SqlCipherParameters` + `AssertPinnedParams` assert those exact values |
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
