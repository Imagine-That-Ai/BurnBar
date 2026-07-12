# Windows Storage Provisioning And Recovery

OpenBurnBar for Windows owns its local SQLCipher database on first launch. A
clean profile no longer needs a copied macOS database, passphrase prompt, or
developer environment variables.

## Owner

`App.OnLaunched` calls `WindowsStorageDevHost.InitializeRuntime()`. The owner:

- resolves `%LOCALAPPDATA%\OpenBurnBar\openburnbar.sqlite` by default;
- generates a 32-byte SQLCipher passphrase when none exists;
- stores the passphrase through `IAppSecretStore` under
  `openburnbar.windows.sqlcipher.passphrase`;
- persists only `sqlCipherDbPath` and `sqlCipherPassphraseRef` in
  `app_config.json`;
- creates the encrypted SQLCipher database through `WindowsSqlCipherProvisioner`;
- writes a sidecar migration journal, key-provenance document, and redacted
  recovery log beside the database.

The storage library keeps the SQLite schema compatible with the current Windows
surfaces and records GRDB migration metadata through
`v54_provider_quota_snapshots` with `user_version = 0`. Windows-only migration
provenance is sidecar JSON so it does not change the SQLite schema hash.

## Recovery States

Storage failures are typed as:

- `WrongKey`
- `CorruptDatabase`
- `LockedFile`
- `InterruptedMigration`
- `UnsupportedSchema`
- `FullDisk`
- `AccessDenied`

The Data Source settings page renders the current state and exposes only the
safe actions for that state: retry, archive/reset after destructive
confirmation, and reveal redacted log. Storage failures are not converted to
legitimate empty data.

## Evidence

Run this on each required Windows host:

```powershell
pwsh scripts/windows-port/storage-evidence.ps1 -RepoRoot C:\src\BurnBar
```

The script writes `docs/windows-port/evidence/storage/<timestamp>/` with host
metadata, test logs, per-case evidence JSON, migration journals, key provenance,
and recovery logs. It runs:

- `windows/tests/storage/OpenBurnBar.App.Storage.Tests.csproj`
- `windows/storage/OpenBurnBar.Storage.Tests/OpenBurnBar.Storage.Tests.csproj`

The app storage suite covers clean-profile provisioning, restart idempotency,
generated-database write seams, wrong-key, corrupt, locked, interrupted,
unsupported-schema, full-disk, access-denied, archive/reset, and reveal-log
evidence cases. The SQLCipher suite covers fixture/golden compatibility with the
macOS v1.0.29 database oracle.
