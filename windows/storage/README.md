# `windows/storage` — Windows SQLCipher storage layer (R2)

The real Windows database seam. Off-Apple builds prune GRDB/storage
(`OPENBURNBAR_DAEMON_LINUX_BOUNDARY_BUILD`), so Windows opens no database from the
Swift Engine. This tree **un-prunes storage**: it opens the *same* Mac-produced
SQLCipher file byte-for-byte and exposes the read-only, DataStore-shaped seam the
Engine calls through the PAL.

- **Contract:** `VAL-P0-DB-010` (the open side of R2, the crown-jewel DB kill-risk).
- **Decision:** [`docs/windows-port/decisions/0004-windows-storage-datastore-seam.md`](../../docs/windows-port/decisions/0004-windows-storage-datastore-seam.md).
- **Pinned cipher contract:** [`decisions/sqlcipher-params.md`](../../decisions/sqlcipher-params.md).

## Projects

| Project | What it is |
|---------|-----------|
| [`OpenBurnBar.Storage`](OpenBurnBar.Storage/) | `net10.0` library. Opens the encrypted DB (`OpenBurnBarStorage.OpenReadOnly`) with the pinned compatibility-4 profile + passphrase key, and implements the read seam `IConversationReadStore` (schema inventory, conversation fetch/list, FTS5 `bm25()`/`snippet()` search). `DbCompatVector` recomputes the schema hash + FTS vector for byte-compat verification. |
| [`OpenBurnBar.Storage.Tests`](OpenBurnBar.Storage.Tests/) | xUnit proof. Opens the committed Mac fixture and reproduces the committed schema hash + FTS vector, cross-checks the byte-compat params across SQLCipher builds, and exercises the read API. |

## How it opens the Mac database

`Microsoft.Data.Sqlite.Core` (ADO.NET wrapper) + `SQLitePCLRaw.bundle_e_sqlcipher`
(the open-source SQLCipher C amalgamation, per-RID) — the master plan's sanctioned
"raw-SQLCipher-C + a thin data layer reproducing the exact pinned config" fallback,
in managed form. Keying order (SQLCipher-required):

```
PRAGMA key = '<passphrase>';            -- passphrase mode (matches GRDB sqlite3_key)
PRAGMA cipher_compatibility = 4;
PRAGMA cipher_page_size = 4096;
PRAGMA kdf_iter = 256000;
PRAGMA cipher_version;                   -- hard self-check: SQLCipher must be active
```

`.Core` (not the full `Microsoft.Data.Sqlite`) is required so the SQLCipher bundle
is the sole native provider; the full package pulls the non-cipher
`bundle_e_sqlite3`, under which `PRAGMA key` is a silent no-op.

## Build + verify

```bash
dotnet test windows/storage/OpenBurnBar.Storage.Tests
```

Runs today on the macOS authoring host: the **same** managed assembly ships on
Windows; the native SQLCipher comes from the bundle per-RID (osx-arm64 here,
win-x64/win-arm64 on Windows CI). The headline test opens the committed
`openburnbar-db-compat-v53.sqlcipher` and asserts:

- 220 `sqlite_master` objects decrypt,
- the schema hash SHA-256 matches `openburnbar-db-compat-vector.json`,
- the FTS5 `bm25()`/`snippet()` row set matches the vector, and
- the four byte-compat parameters match the committed Mac readback **even though
  the SQLCipher point version and crypto provider differ** — the definitive proof
  that byte-compat is anchored to the pinned parameters, not the build.
