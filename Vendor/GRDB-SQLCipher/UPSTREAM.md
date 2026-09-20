# GRDB-SQLCipher upstream record

This directory is the OpenBurnBar vendored copy of **GRDB.swift v6.29.3**.
The upstream release is identified by the version marker in `README.md`:

- Repository: <https://github.com/groue/GRDB.swift>
- Tag: `v6.29.3`
- Source tarball: <https://github.com/groue/GRDB.swift/archive/refs/tags/v6.29.3.tar.gz>
- Source tarball SHA-256: `256b4f2eb33a712c95eb3e4c7f7c7acdebc8df778c80d1e05d161830c6dd2d08`

The tarball digest is recorded from the Wave-0 remediation plan. It was not
downloaded in this offline worktree, so the digest is **UNVERIFIED locally**.
An owner release check must download the URL above and compare the bytes with
the recorded digest before treating it as independently verified.

## OpenBurnBar integration contract

- `SQLCipher.swift` is pinned exactly to `4.16.0`; the checked-in
  `Package.resolved` records revision
  `07bf6bc2191a063d6f1e7c3b5f276a3fadfe36b7`.
- Apple builds use the SQLCipher.swift package and its binary framework by
  default. System-SQLCipher mode is explicit: set
  `OPENBURNBAR_USE_SYSTEM_SQLCIPHER=1`, or provide
  `OPENBURNBAR_SQLCIPHER_PREFIX` / `OPENBURNBAR_SQLCIPHER_LIB_DIR`. The latter
  can link an explicit `libsqlcipher.so.0` and adds its runtime path.
- The local `CSQLite` system-library target is the shim boundary. Its
  `shim.h` includes `<SQLCipher/SQLCipher.h>` when that header is available and
  otherwise includes `<sqlite3.h>`. It keeps Swift-callable wrappers for
  `sqlite3_key`, `sqlite3_rekey`, the variadic configuration calls, and the
  optional pre-update-hook declarations.

## Vendored layout and local delta

The vendored tree keeps the upstream GRDB layout: the Swift sources are under
`GRDB/`, the package manifest is at the root, and the C shim is under
`Sources/CSQLite/`. No upstream paths were invented or moved for this record.

The generated patch
[`patches/0001-openburnbar-sqlcipher.patch`](patches/0001-openburnbar-sqlcipher.patch)
contains the local delta found against the original imported snapshot:

| Path | OpenBurnBar change |
|------|--------------------|
| `GRDB/Core/DatabaseQueue.swift` | Finish async read-only transactions with rollback-safe cleanup and invariant assertions. |
| `GRDB/Export.swift` | Export the local `CSQLite` shim and conditionally export SQLCipher when it can be imported. |
| `Package.swift` | Add explicit system-SQLCipher selection, pkg-config providers, and an optional library/rpath linker override. |
| `Sources/CSQLite/shim.h` | Fall back to the system SQLite header when the SQLCipher header is unavailable. |

Because the upstream archive was not available offline, the patch was
generated against the exact pristine vendor snapshot introduced in commit
`df16dc8696aa008e4ca11ef6ee642e38cd933720` and the current vendored tree. The
generation used `diff -ruN -w` (with the output `patches/` directory excluded
to prevent the patch from containing itself):

```bash
diff -ruN -w --exclude=patches --exclude=UPSTREAM.md \
  upstream/Vendor/GRDB-SQLCipher vendored \
  > Vendor/GRDB-SQLCipher/patches/0001-openburnbar-sqlcipher.patch
```

If an owner later verifies the upstream tarball and finds a structural
difference from that imported snapshot, regenerate the patch against the
verified archive and preserve the actual vendored paths above.
