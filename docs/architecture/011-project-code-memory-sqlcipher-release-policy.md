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

## Amendment 2026-09-23 — Wave 2.4 daemon fail-closed (supersedes the no-op clause)

The "key application is intentionally a no-op" clause above is retired. The
daemon package now links SQLCipher.swift 4.16.0 on macOS and the container
builds SQLCipher 4.5.6 on Linux, so a codec-less daemon is a misbuilt binary,
not a supported local-dev mode. New contract, mirroring the app's
`DatabaseEncryptionService`:

- `OpenBurnBarDaemonMain` calls `requireCodecForStartup()` before binding
  anything: a codec-less binary exits with an error instead of serving a
  disclosed-plaintext database. Proven at runtime by
  `scripts/ci/verify-daemon-codec-gate.sh` (daemon-pr-gate), which drives the
  DEBUG-only `OPENBURNBAR_DAEMON_FORCE_NO_CODEC=1` hatch; the release job
  proves the hatch string is compiled out of the release binary.
- Every keyed-open primitive throws instead of no-op-ing: no codec always
  throws `codecUnavailable`; ciphertext with no resolvable key throws
  `missingKeyForEncryptedDatabase`. Plaintext/missing/in-memory databases with
  no key still open (first-run creation; the migration upgrades them once a
  key appears). GRDB opens (switcher store, Linux cloud-sync runtime) execute
  the shared `grdbKeyingDecision`.
- The `productionReady=false` reporting, the release-blocking reason strings,
  and the `DAEMON_SQLCIPHER_PRESENT=1` proof lane are unchanged: they now
  describe a state the daemon exits before reaching, kept as defense in depth
  and as the release checklist.
