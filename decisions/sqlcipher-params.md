# Decision: pin the (currently-implicit) SQLCipher parameters explicitly

**Status:** accepted · **Area:** Windows port R2 (DB byte-compat) · **Contract:** `VAL-P0-DB-009`
**Applies to:** the shared encrypted app database written by
`AgentLens/Services/DataStore/` and read by `OpenBurnBarDaemon/`.

## Context

The Windows port (R2 — the crown-jewel kill-risk) plans to **reuse the same
encrypted SQLite file the Mac writes today** rather than re-encrypt or re-sync.
SQLCipher byte-compatibility holds only **within a single SQLCipher major
version and a single set of cipher/KDF/page parameters**. If the Windows build
links a SQLCipher whose *defaults* differ from the Mac's, the Mac-written file is
unreadable (or silently mis-derives the key) on Windows.

Today those parameters are **never written in OpenBurnBar source**. The app opens
the database in **passphrase mode**:

- `AgentLens/Services/DataStore/DatabaseEncryptionService.swift:458` →
  `try db.usePassphrase(key)` (PBKDF2 passphrase KDF — *not* raw-key mode).
- `…:462-469` → a hard self-check that `PRAGMA cipher_version` is non-empty,
  refusing to run against a non-SQLCipher SQLite (the historical "plaintext
  no-op `PRAGMA key`" regression).

`cipher_compatibility`, `kdf_iter`, and `cipher_page_size` are **never set** — the
database therefore inherits the **compile-time defaults of the linked SQLCipher
build**. On Mac that build is pinned:

- `project.yml` → package `GRDB` = `Vendor/GRDB-SQLCipher`, built with
  `SQLITE_HAS_CODEC` + `GRDBCIPHER` + `SQLITE_ENABLE_FTS5`.
- `Vendor/GRDB-SQLCipher/Package.swift` → `.package(url: SQLCipher.swift, exact: "4.16.0")`.
- `Vendor/GRDB-SQLCipher/Package.resolved` → `sqlcipher.swift` **4.16.0**,
  revision `07bf6bc2191a063d6f1e7c3b5f276a3fadfe36b7`
  (the upstream binary `SQLCipher.xcframework.zip`, checksum
  `510fd00fa51fb017909a159bb1cc233b012e8ce18dc9c2f09014fe47f557c1a6`).

Because the parameters are implicit, "the Mac defaults" is not a value anyone can
diff against on Windows. This decision makes them **explicit and machine-pinned**.

## Decision

Pin the following parameters as the **byte-compat contract** the Windows build
must reproduce. They are the SQLCipher **4** (`cipher_compatibility = 4`)
compatibility profile as shipped by SQLCipher.swift **4.16.0**:

| Parameter                | Pinned value          | PRAGMA readback         |
| ------------------------ | --------------------- | ----------------------- |
| `cipher_compatibility`   | `4`                   | *(write-only PRAGMA)*   |
| `cipher_page_size`       | `4096`                | `PRAGMA cipher_page_size` |
| `kdf_iter`               | `256000`              | `PRAGMA kdf_iter`       |
| KDF algorithm            | `PBKDF2_HMAC_SHA512`  | `PRAGMA cipher_kdf_algorithm`  |
| Per-page HMAC algorithm  | `HMAC_SHA512`         | `PRAGMA cipher_hmac_algorithm` |
| Key mode                 | passphrase (PBKDF2)   | `db.usePassphrase(_:)`  |
| FTS5 tokenizer           | `porter unicode61`    | (schema; see the vector) |

`cipher_compatibility` is a **write-only** PRAGMA — SQLCipher does not return a
value when you read it — so it is asserted **indirectly** through the four
readable parameters above, which together *are* the compatibility-4 profile.

### Trace / provenance

These are **not guessed** — they are the documented SQLCipher 4 defaults and they
are **read back from the live 4.16.0 binary** by the kit and frozen as evidence:

- **Empirical (authoritative):** `test_pinnedSQLCipherParams_areExplicitAndMatch_4_16_0`
  in `AgentLensTests/Active/DatabaseByteCompatVectorTests.swift` opens a real
  keyed connection against the vendored `4.16.0` build and asserts each value.
  The full readout (`cipher_version`, `cipher_provider`,
  `cipher_provider_version`, `cipher_page_size`, `kdf_iter`,
  `cipher_default_kdf_iter`, `cipher_hmac_algorithm`, `cipher_kdf_algorithm`) is
  committed at
  `AgentLensTests/Fixtures/DBByteCompat/openburnbar-db-compat-params-observed.json`.
- **Upstream defaults (SQLCipher 4 design):** page size `4096`, `kdf_iter`
  `256000`, `PBKDF2-HMAC-SHA512` key derivation, and per-page `HMAC-SHA512`
  are the SQLCipher-4 defaults (Zetetic SQLCipher design / "SQLCipher 4.0.0
  Release" — the `cipher_compatibility = 4` profile).

## Consequences

- **Windows (`VAL-P0-DB-010`, out of scope here):** the Windows build MUST link a
  SQLCipher that produces these exact parameters (same major version, same
  compatibility profile). If the crypto *provider* differs (Mac CommonCrypto/
  OpenSSL vs. a Windows OpenSSL), that is fine **as long as** the KDF/HMAC/page
  parameters above match — the ciphertext format is defined by those, not by the
  provider. If a future Windows SQLCipher defaults differently, the port must set
  these values **explicitly** (`PRAGMA cipher_compatibility = 4; PRAGMA kdf_iter
  = 256000; PRAGMA cipher_page_size = 4096;`) before keying, and the Mac side
  should be made explicit in lock-step.
- **Mac drift guard:** if a SQLCipher upgrade changes any default, the pinned
  test fails loudly rather than silently shipping a file Windows can no longer
  read.
- **Do NOT rely on defaults staying implicit.** The safest end state (a
  follow-up, not required by this contract) is to set these PRAGMAs explicitly in
  `DatabaseEncryptionService` on **both** platforms so the contract is enforced
  at open time, not just in a test. This note + the pinned test are the bridge
  until then.

## The DB-compat vector

The committed fixture + vector that this decision anchors:

- `AgentLensTests/Fixtures/DBByteCompat/openburnbar-db-compat-v53.sqlcipher` —
  a **real Mac-produced** SQLCipher database, migrated through the **live**
  `OpenBurnBarDatabase` migrator to `v53_memory_forget_outbox`, seeded with the
  canonical FTS corpus. Encrypted with the **non-secret** fixture passphrase
  `OBB-WinPort-DBByteCompat-Fixture-Key-v53-000=` (a test key, documented in the
  fixture `README.md`).
- `AgentLensTests/Fixtures/DBByteCompat/openburnbar-db-compat-vector.json` — the
  expected **schema hash** (SHA-256 over the normalized `sqlite_master` DDL) and
  the expected **FTS5 `bm25()`/`snippet()` row set** for a fixed set of `MATCH`
  probes (porter stemming, case-folding, multi-column indexing, rank order).

`VAL-P0-DB-010` opens the committed fixture on Windows and must reproduce the
same schema hash and FTS row set.
