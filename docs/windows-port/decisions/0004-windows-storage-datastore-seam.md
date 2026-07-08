# WPD-0004: Windows storage layer — C# Microsoft.Data.Sqlite + bundle_e_sqlcipher behind the DataStore seam

- **Status:** Accepted (Phase 2, R2 un-prune)
- **Date:** 2026-07-03
- **Contract:** `VAL-P0-DB-010` (open the committed Mac fixture on the Windows
  storage stack; reproduce the schema hash + FTS5 vector). Anchors R2, the
  crown-jewel DB kill-risk.
- **Scope:** How the Windows build **opens and reads the same encrypted SQLCipher
  database the macOS app writes**, now that off-Apple builds prune GRDB/storage
  (`OPENBURNBAR_DAEMON_LINUX_BOUNDARY_BUILD`) and Windows therefore opens no
  database. Writes/migrations stay macOS/daemon-owned for this step; this WPD
  covers the read seam that un-prunes storage.

## Context

The macOS app persists everything in a **SQLCipher-encrypted** SQLite file via
**GRDB** (`Vendor/GRDB-SQLCipher`, SQLCipher.swift `4.16.0`), keyed in
**passphrase mode** (`Database.usePassphrase` → `sqlite3_key`, PBKDF2 — not
raw-key). The Windows-port master plan (R2) chose to **reuse that same file**
rather than re-encrypt or re-sync, so Windows must open it byte-for-byte.

Two problems make this the crown-jewel kill-risk:

1. **GRDB has no Windows support.** The Swift Engine subset that compiles on
   Windows today does so only because storage was **pruned** off-Apple. Something
   has to own the database on Windows.
2. **SQLCipher byte-compat holds only within a major version + a fixed
   cipher/KDF/page parameter set**, and the Mac sets those parameters
   *implicitly* (compile-time defaults of the linked build). WPD sibling
   `decisions/sqlcipher-params.md` pinned them explicitly:
   `cipher_compatibility=4`, `cipher_page_size=4096`, `kdf_iter=256000`,
   `PBKDF2_HMAC_SHA512` KDF, `HMAC_SHA512` per-page HMAC, `porter unicode61` FTS5.

The master plan pre-authorized the escape hatch (`docs/WINDOWS_PORT_MASTER_PLAN.md`):

> "GRDB **or** raw-SQLCipher fallback" (Option A, line 254);
> "If GRDB won't build on Windows, prove the **raw-SQLCipher-C** fallback" (line 277);
> "**fallback is raw SQLCipher-C + a thin data layer** reproducing the exact
> pinned config" (line 517); R2 mitigation: "**raw-SQLCipher-C fallback proven
> there**" (line 725).

## Decision

**Own the Windows database in a managed C# storage project
(`windows/storage/OpenBurnBar.Storage`) built on `Microsoft.Data.Sqlite.Core` +
`SQLitePCLRaw.bundle_e_sqlcipher`, exposing a read-only, DataStore-shaped seam
(`IConversationReadStore`) that the Windows Engine calls through the PAL.**

- **Open path:** `PRAGMA key = '<passphrase>'` (single-quoted literal → passphrase
  mode, matching GRDB's `sqlite3_key`), then the pins set **explicitly**
  (`cipher_compatibility=4`, `cipher_page_size=4096`, `kdf_iter=256000`), then a
  hard `PRAGMA cipher_version` self-check that mirrors the macOS
  `DatabaseEncryptionService` guard against a silent plaintext no-op.
- **Byte-compat oracle:** `DbCompatVector` recomputes, byte-for-byte, the macOS
  `DatabaseByteCompatVector` algorithm — SHA-256 over the normalized ordered
  `sqlite_master` DDL, and the FTS5 `bm25()`/`snippet()` row set for the four
  frozen `MATCH` probes — and diffs them against the committed vector.
- **Same assembly on both platforms:** the project targets plain `net10.0` (no
  Windows TFM, zero P/Invoke). The native SQLCipher is supplied per-RID by the
  bundle (win-x64 / win-arm64 on Windows CI, osx-arm64 on the macOS authoring
  host), so the **identical managed assembly** that ships on Windows is unit-tested
  here today — the already-proven `OpenBurnBar.Pal.Ipc` portable-core pattern.

## Why this IS the sanctioned raw-SQLCipher-C fallback, not a workaround

`SQLitePCLRaw.bundle_e_sqlcipher` **is** raw SQLCipher-C: it packages the
open-source **SQLCipher amalgamation** (the same Zetetic C code, compiled per
platform) and exposes it through the stable `sqlite3_*` C ABI. `Microsoft.Data.Sqlite`
is a thin ADO.NET wrapper over that C ABI. So this is precisely the master plan's
"**raw SQLCipher-C + a thin data layer reproducing the exact pinned config**" —
the only difference from a hand-written P/Invoke shim is that the thin layer is a
mature, security-maintained library instead of bespoke marshaling. That makes it
**more** SOTA than a hand-rolled C shim, not a shortcut:

- **The DataStore seam lives on the C# side on purpose.** The plan's Option A puts
  the extracted DataStore behind a protocol the Engine calls via the PAL; the
  Windows storage owner is the C# side of that seam. Keeping it managed means the
  seam is memory-safe, debuggable, and reuses the same .NET IPC/PAL stack already
  proven for ConPTY/named-pipe peer-auth — no second native toolchain, no bespoke
  FFI lifetime bugs at the crypto boundary.
- **Byte-compat is enforced by the ciphertext parameters, not the provider.**
  Proven empirically below: the bundle opened the Mac file with a **different**
  SQLCipher point version **and a different crypto provider**, yet reproduced the
  schema hash and FTS vector exactly. That is the decision doc's central claim,
  now demonstrated rather than asserted.

### Why not compile GRDB-SQLCipher for Windows (the "no-workaround" alternative)

GRDB is Swift + depends on Apple/Foundation SQLite integration patterns and a
Swift-Windows build of the SQLCipher xcframework path; there is no supported
Windows GRDB and forcing one would be a bespoke, unmaintained fork — strictly
worse than the pre-authorized fallback. The Engine does not need GRDB's Swift API
on Windows; it needs the **file** to open and the **rows** to read, which the C#
seam delivers with a byte-identical result.

## Consequences

- **New NuGet deps** (pinned): `Microsoft.Data.Sqlite.Core 9.0.0`,
  `SQLitePCLRaw.bundle_e_sqlcipher 2.1.11`. `.Core` (not the full
  `Microsoft.Data.Sqlite`) is mandatory so the SQLCipher bundle is the **sole**
  native provider — the full package pulls the non-cipher `bundle_e_sqlite3`, under
  which `PRAGMA key` is a silent no-op and the Mac file is unreadable.
- **New Windows sub-tree** `windows/storage/`, registered as a fifth per-area
  budget partition (`scripts/debt/check-windows-tree-budget.sh`,
  `budgets/windows-tree-baseline.json`) and in the aggregating solution.
- **Read-only for this step.** The seam proves the file opens and its content is
  faithfully reachable through the typed API. The write/migration seam (making the
  pins explicit on the Mac writer too, per `sqlcipher-params.md`) is the follow-up.
- **Provider drift is guarded, not assumed.** The cross-provider param test asserts
  the four byte-compat parameters match the committed Mac readback while allowing
  `cipher_version`/`cipher_provider` to differ; if a future bundle changes a KDF/
  HMAC/page default it fails loudly.

## Evidence (proven via `dotnet test` on the macOS authoring host — `VAL-P0-DB-010`)

`dotnet test windows/storage/OpenBurnBar.Storage.Tests` opens the **committed
Mac-produced** fixture
(`AgentLensTests/Fixtures/DBByteCompat/openburnbar-db-compat-v53.sqlcipher`) with
the pinned profile + the non-secret fixture key and reproduces the committed
vector:

```
Passed!  - Failed: 0, Passed: 10, Skipped: 0, Total: 10 - OpenBurnBar.Storage.Tests.dll (net10.0)

cipher_version         = 4.5.2 community        (Mac wrote it with 4.16.0 community)
cipher_provider        = libtomcrypt            (Mac provider = commoncrypto)
cipher_page_size       = 4096
kdf_iter               = 256000
cipher_hmac_algorithm  = HMAC_SHA512
cipher_kdf_algorithm   = PBKDF2_HMAC_SHA512
sqlite_master objects  = 220
expected schemaHash    = 8f8f0eba995205724dfacd6f137e83bf7416488ca34b2919df82a9470943992c
actual   schemaHash    = 8f8f0eba995205724dfacd6f137e83bf7416488ca34b2919df82a9470943992c   ✓ match
FTS row set matches    = True
  [porter-stem-run]  MATCH 'run'      => conv-beta-run (4× "running") then conv-alpha-fox ("runs")
  [case-fold-title]  MATCH 'GAMMA'    => conv-gamma-db (title column, case-folded)
  [fulltext-database]MATCH 'database' => conv-gamma-db  snippet "<b>database</b> encryption keeps your data safe at rest"
  [porter-stem-shoe] MATCH 'shoe'     => conv-beta-run  (shoes → shoe)
```

The headline is the version/provider mismatch line: the Windows stack linked
**SQLCipher 4.5.2 / libtomcrypt** against a file the Mac produced with
**4.16.0 / commoncrypto**, and still reproduced the 220-object schema hash and the
FTS5 `bm25()`/`snippet()` row set byte-for-byte. That is the definitive proof that
byte-compat is anchored to the pinned compatibility-4 parameters, not to a
matching build — exactly what `decisions/sqlcipher-params.md` predicted. R2's
open side is retired.
