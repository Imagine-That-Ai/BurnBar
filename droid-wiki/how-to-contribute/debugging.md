# Debugging

## Structured logs

The app uses `AppLogger` backed by `os.Logger` with subsystem `com.imaginethat.OpenBurnBar`.

Stream logs in real time:

```bash
log stream --predicate 'subsystem == "com.imaginethat.OpenBurnBar"'
```

Or open **Console.app**, filter by `com.imaginethat.OpenBurnBar`.

## Daemon logs

The daemon runs as a subprocess. Its output goes to the system log with a separate process identity. Use:

```bash
sudo log stream --predicate 'process == "OpenBurnBarDaemon"'
```

Or check Console.app under the `OpenBurnBarDaemon` process.

## Parser debugging

1. Place sample log files at the expected path for the provider (see `SettingsManager` → log directory).
2. Trigger a manual refresh from the menu bar (hold Option, click the status item).
3. Watch `AppLogger.parser` in the log stream for parse events and errors.
4. If the parser returns an empty array, verify the log directory path in Settings and that the file matches the expected glob pattern.

## Stale build issues

Before a full cache clear, run a dry-run to preview what will be removed:

```bash
./scripts/clear-xcode-caches.sh --dry-run
```

If the preview looks safe:

```bash
./scripts/clear-xcode-caches.sh
```

## Direct database inspection

```bash
sqlite3 ~/Library/Application\ Support/OpenBurnBar/OpenBurnBar.sqlite
```

Useful SQLite commands:

```sql
.tables
.schema token_usage
SELECT * FROM token_usage ORDER BY created_at DESC LIMIT 20;
```

## Daemon socket

Send a JSON-RPC health check to the daemon's Unix socket:

```bash
echo '{"jsonrpc":"2.0","method":"health","id":1}' | nc -U ~/.burnbar.sock
```

## Common errors

| Error | Cause | Fix |
|---|---|---|
| `value of type X has no member Y` | Stale DerivedData | `./scripts/clear-xcode-caches.sh` |
| `Protocol mismatch` in Cursor extension | App and daemon versions differ | Update both app and daemon to the same build |
| Parser returning empty array | Wrong log directory or file pattern | Check `SettingsManager` log path; verify file pattern in the parser |
| `SQLITE_BUSY` during tests | Shared database between test cases | Create a fresh `DatabaseQueue()` per test |
