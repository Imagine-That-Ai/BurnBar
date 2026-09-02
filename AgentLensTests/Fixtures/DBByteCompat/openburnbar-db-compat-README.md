# DB byte-compat de-risk kit (`VAL-P0-DB-009`)

Fixtures anchoring the Windows-port DB byte-compat contract (R2). See
[`decisions/sqlcipher-params.md`](../../../decisions/sqlcipher-params.md) for the
pinned SQLCipher parameters and rationale, and
`AgentLensTests/Active/DatabaseByteCompatVectorTests.swift` for the validator.

## Files

| File | What it is |
| ---- | ---------- |
| `openburnbar-db-compat-v64.sqlcipher` | A **real Mac-produced** SQLCipher database, migrated through the **live** `OpenBurnBarDatabase` migrator to `v65_memory_quarantine_bodies` and seeded with the canonical FTS corpus. The legacy filename stays stable for downstream fixture consumers; the vector records the actual endpoint. Genuinely encrypted (no plaintext SQLite header). |
| `openburnbar-db-compat-vector.json` | The **DB-compat vector**: expected schema hash (SHA-256 over normalized `sqlite_master` DDL) + the expected FTS5 `bm25()`/`snippet()` row set for a fixed set of `MATCH` probes. |
| `openburnbar-db-compat-params-observed.json` | The SQLCipher parameters **read back from the live 4.16.0 binary** (evidence for the pinned values). |

## The fixture passphrase is NOT a secret

The fixture is encrypted with the fixed, **non-secret** test key:

```
OBB-WinPort-DBByteCompat-Fixture-Key-v53-000=
```

It exists so the Mac validator *and* the future Windows open-side check
(`VAL-P0-DB-010`) can open the **same committed encrypted file**. It keys only
this throwaway fixture — never any real user data. (Only base64 alphabet + `-`
so it passes `DatabaseEncryptionService.validateEncryptionKey`.)

## Regenerating (macOS)

App-hosted XCTest can lack the Documents-folder TCC grant, so the test never
writes into the repo. It writes freshly generated artifacts to a writable output
dir; you copy them in.

```bash
# 1. Generate into a writable dir (the test reads OPENBURNBAR_DB_COMPAT_OUT,
#    passed through xcodebuild as TEST_RUNNER_*).
rm -rf /tmp/obb-db-compat-out
TEST_RUNNER_OPENBURNBAR_DB_COMPAT_OUT=/tmp/obb-db-compat-out \
  scripts/test-openburnbar-app.sh \
  -only-testing:AgentLensTests/DatabaseByteCompatVectorTests

# 2. Copy the generated artifacts into this directory. The generated .sqlcipher
#    carries whatever `fixtureBaseName` currently is, so copy it under that name.
cp /tmp/obb-db-compat-out/openburnbar-db-compat-v64.sqlcipher \
   /tmp/obb-db-compat-out/openburnbar-db-compat-vector.json \
   /tmp/obb-db-compat-out/openburnbar-db-compat-params-observed.json \
   AgentLensTests/Fixtures/DBByteCompat/

# 3. Regenerate the Xcode project so the resources bundle, then re-run to validate.
xcodegen generate --spec project.yml
scripts/test-openburnbar-app.sh \
  -only-testing:AgentLensTests/DatabaseByteCompatVectorTests
```

The schema hash is stable across regeneration; the encrypted **bytes** are not
(SQLCipher uses a random per-database salt), so a regenerated `.sqlcipher` file
differs byte-for-byte while opening to the identical schema + FTS vector.

## When you add a migration

Adding a migration moves the endpoint, so **all four** of these change together.
Missing any one of them leaves the suite red in a way that looks like a fixture
bug rather than a stale artifact:

1. `expectedSchemaEndpoint` in `AgentLensTests/Support/DatabaseByteCompatVector.swift`
   — the new `latestMigrationIdentifier`.
2. `fixtureBaseName` in `DatabaseByteCompatVectorTests.swift` and the committed
   `.sqlcipher` filename — both bump to the new version (`git rm` the old one).
3. `openburnbar-db-compat-vector.json` — **regenerated, never hand-edited.** It
   carries `migrationCount` and the schema hash, which no human can compute.
4. The `.sqlcipher` binary itself — a v(N-1) database can never satisfy a vN
   vector, no matter what the JSON says.

### …and the Windows mirrors, which read this same fixture

The Windows port consumes this kit directly, with **literal** pins that must be
moved by hand. Bumping only the endpoint string here is the recurring miss (it
broke CI on both v59 and v60): the count is a separate literal and does not
follow the endpoint. Grep for the previous count before you assume it is done.

5. `WindowsSqlCipherProvisioner` — `CurrentMigrationEndpoint`,
   `CurrentMigrationCount`, the new identifier appended to
   `AppliedMigrationIdentifiers` (`.Metadata.cs`, endpoint stays last), and the
   endpoint schema itself (`.Schema.cs`).
6. The Windows test pins, **endpoint _and_ count together**:
   `windows/storage/OpenBurnBar.Storage.Tests/TokenUsageWriteRoundTripTests.cs`,
   `.../SwitcherProfileWriteSeamRoundTripTests.cs` (schema hash + count), and
   `windows/tests/storage/WindowsStorageDevHostRuntimeTests.cs`.
7. Every `openburnbar-db-compat-vN.sqlcipher` filename reference under
   `windows/` — csproj `<Content>` links, `RepoFixtures`, and the per-suite
   `FixtureName` constants.

The count is always the length of `AppliedMigrationIdentifiers`, which equals
the Swift migrator's `registerMigration` count — verify it, don't copy whatever
number the failing assertion prints.

Editing only the JSON is the trap: `schemaEndpoint` is the one field that looks
hand-editable, and changing it alone produces a vector that disagrees with both
its own `migrationCount` and the encrypted file it is supposed to describe.
