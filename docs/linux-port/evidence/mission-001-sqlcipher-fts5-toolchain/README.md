# SQLCipher FTS5 Linux Toolchain Evidence

Image tag: `openburnbar-linux-toolchain:mission-001-fts5`

SQLCipher source:

- Version: `4.5.6`
- URL: `https://github.com/sqlcipher/sqlcipher/archive/refs/tags/v4.5.6.tar.gz`
- SHA-256: `e4a527e38e67090c1d2dc41df28270d16c15f7ca5210a3e7ec4c4b8fda36e28f`
- Install prefix: `/opt/openburnbar/sqlcipher`
- Exposed paths: `PATH=/opt/openburnbar/sqlcipher/bin`, `PKG_CONFIG_PATH=/opt/openburnbar/sqlcipher/lib/pkgconfig`, `LD_LIBRARY_PATH=/opt/openburnbar/sqlcipher/lib`

Commands and results:

- `docker build --progress=plain -t openburnbar-linux-toolchain:mission-001-fts5 tools/linux-toolchain` exited `0`.
  - `docker-build-final.log` records the SQLCipher source build and checksum verification.
  - `docker-build-final-smoke.log` records the final cached rebuild after the smoke-script assertion fix.
- `docker run --rm openburnbar-linux-toolchain:mission-001-fts5` exited `0`; see `smoke-output.txt`.
  - `PRAGMA cipher_version` returned `4.5.6 community`.
  - `PRAGMA compile_options` included `HAS_CODEC` and `ENABLE_FTS5`.
  - `CREATE VIRTUAL TABLE docs_fts USING fts5(...)` succeeded under SQLCipher.
  - FTS5 query returned `Toolchain|SQLCipher encrypted searchable schema proof`.
  - Encrypted DB header was `b6ceb79440813fc16c1ac95973f33f7f`, not the plaintext SQLite header.
  - Plain `sqlite3` and SQLCipher with the wrong key both failed with `file is not a database (26)`.
- `docker run --rm openburnbar-linux-toolchain:mission-001-fts5 sqlcipher -batch :memory: 'PRAGMA cipher_version; PRAGMA compile_options;'` exited `0`; see `sqlcipher-compile-options.txt`.
- `swift build --target GRDB` in `Vendor/GRDB-SQLCipher` exited `0`; see `grdb-sqlcipher-build.txt`.
- `swift build --product GRDB-dynamic` in `Vendor/GRDB-SQLCipher` exited `0`; see `grdb-sqlcipher-dynamic-build.txt`.
- `ldd .build/aarch64-unknown-linux-gnu/debug/libGRDB-dynamic.so` resolved `libsqlcipher.so.0 => /opt/openburnbar/sqlcipher/lib/libsqlcipher.so.0`; see `grdb-dynamic-ldd.txt`.
- Final `docker ps` showed no running containers; see `docker-ps-final.txt`.
- Final `docker ps -a --filter ancestor=openburnbar-linux-toolchain:mission-001-fts5` showed no stopped or running containers for this image; see `docker-ps-a-fts5-final.txt`.

Additional artifacts:

- `docker-image-inspect.json`
- `docker-image-history.txt`
- `docker-build.log`, `docker-build-rerun.log`, and `docker-build-after-smoke-fix.log` preserve earlier interrupted or intermediate Docker output for auditability; the final passing build/smoke artifacts above are authoritative.
