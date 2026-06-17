# ADR 011: Project Code Memory SQLCipher Release Policy

## Context

Project Code Memory stores local source snippets, symbols, references, search
chunks, FTS rows, and optional vector blobs in the daemon SQLite database. That
data is more sensitive than ordinary usage rollups because it can contain
private implementation details even after secret scanning rejects obvious
credentials.

The daemon already has SQLCipher keying and plaintext-to-encrypted migration
logic, but stock SQLite builds do not expose `PRAGMA cipher_version`; in those
builds key application is intentionally a no-op so local development does not
brick an existing plaintext database.

## Decision

Project Code Memory release readiness requires a SQLCipher-capable daemon build.
The runtime proof is non-empty `PRAGMA cipher_version` on the daemon SQLite
handle, covered by `BurnBarDaemonDatabaseCipher.isCipherAvailable()` and the
codec-present daemon tests gated by `DAEMON_SQLCIPHER_PRESENT=1`.

Until that proof is present:

- Project Code Memory must report `productionReady=false`.
- Status/doctor output must include a SQLCipher release-blocking reason.
- Release CI must fail if `PROJECT_CODE_MEMORY_RELEASE_READY=true` is set
  without `DAEMON_SQLCIPHER_PRESENT=1`.
- Product and security docs must describe local Project Code Memory as plaintext
  at rest in stock builds, not encrypted.

## Consequences

Local development and compatibility tests may keep using stock SQLite, but that
mode is explicitly not a release-ready Project Code Memory posture. A release
that wants to remove the SQLCipher block must link a SQLCipher codec, set
`DAEMON_SQLCIPHER_PRESENT=1` in the codec proof lane, and pass the daemon
keyed-open/migration tests before flipping Project Code Memory readiness.

If the product intentionally ships without SQLCipher, code indexing must remain
non-production and disclosed as plaintext at rest.
