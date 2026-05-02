# OpenBurnBar Incident Runbook

On-call operational reference for diagnosing and resolving OpenBurnBar incidents.

## Quick Reference

| Component | Location | Logs |
|-----------|----------|------|
| macOS App | `/Applications/OpenBurnBar.app` | `~/Library/Logs/OpenBurnBar/` |
| Daemon | `Contents/Helpers/OpenBurnBarDaemon` (in app bundle) | `~/Library/Logs/OpenBurnBar/daemon.log` |
| Socket | `~/Library/Application Support/OpenBurnBar/openburnbar-daemon.sock` | — |
| Database | `~/Library/Application Support/OpenBurnBar/openburnbar.sqlite` | — |
| Extension | VS Code / Cursor extension host | Extension dev console |
| Cloud sync | Firebase Console | Firestore logs |

---

## Incident 1: Daemon Not Starting

### Symptoms
- Menu bar shows "Daemon Unavailable"
- Extension health view shows daemon as offline
- `launchctl list | grep openburnbar` shows no entry or error exit code

### Diagnosis

```bash
# Check if daemon process is running
pgrep -fl OpenBurnBarDaemon

# Check launchd registration
launchctl list | grep openburnbar

# Check socket existence
ls -la ~/Library/Application\ Support/OpenBurnBar/openburnbar-daemon.sock

# Check for stale PID files
ls -la ~/Library/Application\ Support/OpenBurnBar/*.pid 2>/dev/null

# Check recent daemon logs
tail -50 ~/Library/Logs/OpenBurnBar/daemon.log

# Try manual daemon start
~/path/to/OpenBurnBarDaemon --socket-path ~/Library/Application\ Support/OpenBurnBar/openburnbar-daemon.sock --version
```

### Remediation

1. **Stale socket**: Remove the stale socket file and relaunch
   ```bash
   rm ~/Library/Application\ Support/OpenBurnBar/openburnbar-daemon.sock
   # Quit and relaunch OpenBurnBar
   ```

2. **Stale PID**: Remove PID lockout
   ```bash
   rm ~/Library/Application\ Support/OpenBurnBar/*.pid
   # Quit and relaunch OpenBurnBar
   ```

3. **Launchd conflict**: Bootout and re-bootstrap
   ```bash
   launchctl bootout gui/$(id -u) ~/Library/Application\ Support/OpenBurnBar/com.openburnbar.daemon.plist 2>/dev/null
   # Relaunch OpenBurnBar — it will re-register the daemon
   ```

4. **Complete restart**: Kill all OpenBurnBar processes
   ```bash
   pkill -f OpenBurnBarDaemon 2>/dev/null || true
   pkill -f OpenBurnBar 2>/dev/null || true
   sleep 2
   open -a OpenBurnBar
   ```

### Verification
- Menu bar popover shows daemon version and healthy status
- `pgrep -fl OpenBurnBarDaemon` shows running process
- Extension health view shows daemon as connected

---

## Incident 2: Database Corruption

### Symptoms
- App crashes on launch with SQLite error
- Data does not appear (sessions, usage, etc.)
- Console log shows `database disk image is malformed` or `integrity_check` failure

### Diagnosis

```bash
# Check database integrity
sqlite3 ~/Library/Application\ Support/OpenBurnBar/OpenBurnBar.sqlite "PRAGMA integrity_check;"

# Check database size (should be > 0)
du -h ~/Library/Application\ Support/OpenBurnBar/OpenBurnBar.sqlite

# Check migration state
sqlite3 ~/Library/Application\ Support/OpenBurnBar/OpenBurnBar.sqlite \
  "SELECT identifier FROM grdb_migrations ORDER BY identifier;" 2>/dev/null

# List available backups
ls -lt ~/Library/Application\ Support/OpenBurnBar/Openburnbar.sqlite.backup-* 2>/dev/null
ls -lt ~/Library/Application\ Support/OpenBurnBar/OpenBurnBar.sqlite.backup-* 2>/dev/null
```

### Remediation

**Option A: Restore from automatic backup** (preferred)

```bash
# 1. Quit OpenBurnBar completely
pkill -f OpenBurnBar

# 2. Find most recent backup
BACKUP=$(ls -t ~/Library/Application\ Support/OpenBurnBar/OpenBurnBar.sqlite.backup-* 2>/dev/null | head -1)

# 3. Verify backup integrity
sqlite3 "$BACKUP" "PRAGMA integrity_check;"
# Must output: ok

# 4. Save corrupted DB for analysis
mv ~/Library/Application\ Support/OpenBurnBar/OpenBurnBar.sqlite \
   ~/Desktop/openburnbar-corrupt-$(date +%Y%m%d-%H%M%S).sqlite

# 5. Restore backup
cp "$BACKUP" ~/Library/Application\ Support/OpenBurnBar/OpenBurnBar.sqlite

# 6. Relaunch
open -a OpenBurnBar
```

**Option B: Repair with SQLite dump**

```bash
# 1. Export data
sqlite3 ~/Library/Application\ Support/OpenBurnBar/OpenBurnBar.sqlite ".dump" > /tmp/openburnbar-recovery.sql

# 2. Create new database
rm ~/Library/Application\ Support/OpenBurnBar/OpenBurnBar.sqlite
sqlite3 ~/Library/Application\ Support/OpenBurnBar/OpenBurnBar.sqlite < /tmp/openburnbar-recovery.sql

# 3. Relaunch — GRDB will run any missing migrations
open -a OpenBurnBar
```

**Option C: Nuclear reset** (last resort — all local data lost)

```bash
mv ~/Library/Application\ Support/OpenBurnBar/OpenBurnBar.sqlite \
   ~/Desktop/openburnbar-db-recovery-$(date +%Y%m%d).sqlite
# OpenBurnBar will create a fresh database on next launch
open -a OpenBurnBar
```

### Verification
- `sqlite3 ... "PRAGMA integrity_check;"` returns `ok`
- App launches without errors
- Previous data is visible (Option A/B) or fresh state (Option C)

**SQLCipher / encrypted database:** If **database encryption** is enabled in Settings, the file is not a vanilla SQLite file; `sqlite3` and `PRAGMA integrity_check` from the system CLI will not open it without the SQLCipher key. Use the in-app path or a SQLCipher-enabled tool. If the app logs `cipher_version` empty or `DatabaseEncryptionError`, verify you are running a build that links `GRDB-SQLCipher` (see `project.yml`); custom local builds that substitute plain GRDB cannot satisfy encryption. Recovery options are the same in principle (restore a backup) but the backup file must be the encrypted file plus the same Keychain key.

---

## Incident 3: Cloud Sync Failure

### Symptoms
- "Sync Error" badge in settings
- Data appears on one device but not another
- Firestore console shows permission denied or write errors

### Diagnosis

```bash
# Check cloud sync settings
defaults read com.openburnbar.app 2>/dev/null | grep -i sync

# Check Firebase Auth state (app logs)
grep -i "firebase\|firestore\|sync" ~/Library/Logs/OpenBurnBar/*.log | tail -30

# Verify network connectivity to Firebase
curl -s -o /dev/null -w "%{http_code}" https://firestore.googleapis.com/
```

### Remediation

1. **Auth token expiry**: Sign out and sign back in
   - Open Settings → Account → Sign Out → Sign In

2. **Firestore rules mismatch**: Verify rules match expected schema
   - Check Firebase Console → Firestore → Rules
   - Use the same logic as the checked-in [firestore.rules](../firestore.rules) (owner-scoped `users/{uid}/...` and shared-artifact paths)

3. **App Check / `PERMISSION_DENIED` after policy changes**
   - If **App Check** was recently **enforced** for Firestore, confirm the macOS app is a build that initializes App Check before Firebase, and (for CI or plist-injected debug) that the [debug token is registered](FIREBASE_APP_CHECK_ENFORCEMENT.md) in Firebase **App Check**.
   - Symptom: sync works in older builds or before enforcement, fails with permission denied after enforcement.
   - See [FIREBASE_APP_CHECK_ENFORCEMENT.md](FIREBASE_APP_CHECK_ENFORCEMENT.md).

4. **Conflict resolution**: OpenBurnBar resolves sync conflicts against local state
   - If stale data persists, try: Settings → Cloud Sync → Reset Sync State

5. **Network issues**: Check firewall/proxy settings
   - Firebase requires HTTPS to `*.googleapis.com`

### Verification
- Settings → Cloud Sync shows "Connected"
- Data syncs between devices within 30 seconds
- No sync errors in logs

---

## Incident 4: Extension Disconnect

### Symptoms
- Extension status bar shows "Disconnected" or "Daemon Offline"
- Extension commands fail with connection errors
- Health view shows version mismatch

### Diagnosis

```bash
# Check if daemon is running and socket exists
pgrep -fl OpenBurnBarDaemon
ls -la ~/Library/Application\ Support/OpenBurnBar/openburnbar-daemon.sock

# Test socket connectivity
python3 -c "
import socket, json
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect('$HOME/Library/Application Support/OpenBurnBar/openburnbar-daemon.sock')
s.sendall(json.dumps({'id': 'test', 'method': 'daemon.health'}).encode() + b'\n')
print(s.recv(65536).decode())
s.close()
"

# Check daemon version
~/Library/Application\ Support/OpenBurnBar/OpenBurnBarDaemon --version 2>/dev/null || \
  ls -la /Applications/OpenBurnBar.app/Contents/Helpers/OpenBurnBarDaemon
```

### Remediation

1. **Socket missing**: Remove stale socket and restart daemon
   ```bash
   rm -f ~/Library/Application\ Support/OpenBurnBar/openburnbar-daemon.sock
   # Restart OpenBurnBar app
   ```

2. **Version mismatch**: Update both extension and app to latest version
   - Extension version must match daemon protocol version
   - Check: Extension health view shows both versions

3. **Workspace trust**: Ensure workspace is trusted for full functionality
   - In VS Code/Cursor: Command Palette → "Workspace: Trust"
   - Restricted mode limits extension capabilities

4. **Restart extension**: Reload the VS Code/Cursor window
   - Command Palette → "Developer: Reload Window"

### Verification
- Extension sidebar shows daemon as connected
- Health view shows matching version numbers
- `daemon.health` returns successful response

---

## Incident 5: Bad Release Detected

See the full release rollback procedure in [RELEASE_ROLLBACK.md](RELEASE_ROLLBACK.md).

### Quick Reference

| Stage | Action |
|-------|--------|
| Prerelease (users can't download yet) | Mark release as draft on GitHub, fix and re-tag |
| Published prerelease | Yank from Homebrew, publish hotfix tag |
| Published stable | Publish hotfix tag, update Homebrew, notify users |

---

## Incident 6: Database Startup Recovery

### Symptoms
- Menu bar shows OpenBurnBar in recovery mode
- Recovery window says the database needs attention
- Console log shows `startup_datastore_open_failed`, `GRDB.DatabaseError`, or a migration/integrity failure
- `grdb_migrations` table may be inconsistent with actual schema

### Diagnosis

```bash
# Check database integrity
sqlite3 ~/Library/Application\ Support/OpenBurnBar/openburnbar.sqlite "PRAGMA integrity_check;"

# Check which migrations have been applied
sqlite3 ~/Library/Application\ Support/OpenBurnBar/openburnbar.sqlite \
  "SELECT identifier FROM grdb_migrations ORDER BY identifier;"

# Compare with expected migrations in source
grep "registerMigration" AgentLens/Services/DataStore/OpenBurnBarDatabase.swift | sed 's/.*"\(.*\)".*/\1/'

# Check for recovery archives created by the in-app reset path
ls -lt ~/Library/Application\ Support/OpenBurnBar/StartupRecovery/ 2>/dev/null | head
```

### Remediation

1. **Retry after fixing the underlying issue**: Free disk space, repair permissions, or restore access to `~/Library/Application Support/OpenBurnBar/`, then click **Retry** in the recovery window.

2. **Archive and reset in-app**: Click **Archive and Reset**. OpenBurnBar copies `openburnbar.sqlite`, `openburnbar.sqlite-wal`, and `openburnbar.sqlite-shm` into `StartupRecovery/<timestamp>/`, removes the live sidecars, and retries startup with a clean database.

3. **Check backup existence**:
   ```bash
   ls -lt ~/Library/Application\ Support/OpenBurnBar/openburnbar.sqlite.backup.* | head -3
   ```

4. **Restore from backup** (see Database Corruption incident above)

5. **Review specific migration**: Use the rollback helper
   ```bash
   scripts/rollback-migration.sh --list
   scripts/rollback-migration.sh v34  # Check a specific migration
   ```

6. **Force re-migration** (safe-rerun migrations only):
   ```bash
   # Remove the failed migration record to let GRDB re-run it
   sqlite3 ~/Library/Application\ Support/OpenBurnBar/openburnbar.sqlite \
     "DELETE FROM grdb_migrations WHERE identifier = 'vXX_name';"
   # Relaunch app; GRDB will re-attempt the migration
   ```

7. **Manual reset**: Quit OpenBurnBar and move the three `openburnbar.sqlite*` sidecar files into a timestamped folder. Prefer the in-app archive action when available because it preserves the exact sidecar set.

### Verification
- App launches successfully
- All expected migrations are in `grdb_migrations`
- Recovery mode is gone
- Data is intact, restored from backup, or archived reset is acknowledged

---

## Incident 9: Mobile Shows "No Mac data has been published yet."

### Symptoms
- iOS app signs in successfully but the Dashboard, Quota, Activity, and Account → Provider summaries surfaces are empty.
- Account → Cloud Sync pill shows `Cloud sync healthy` (or no error) but `Last published` is `—`.

### Diagnosis

1. On the **Mac**, open OpenBurnBar → Settings → **Account**: confirm signed in.
2. On the **Mac**, open Settings → **Devices & Sync**: confirm `Cloud sync healthy` and a recent `Last published` timestamp.
3. On the **iPhone**, open Account → **Sync diagnostics** and confirm:
   - Status: `Cloud sync healthy`
   - Listeners: provider summaries / devices counts greater than zero.
   - Errors section is hidden.
4. If listeners report zero records, run a Mac usage refresh (popover → refresh) which triggers a fresh publish.

### Remediation
- Same Firebase project, same account: cross-check the email shown in mobile Account profile vs. Mac Account settings. Different accounts can never share data.
- If the Mac publishes successfully but mobile still reads nothing, sign out on mobile and sign in again. The auth listener resubscribes and rebuilds Firestore listeners.
- If `Sync diagnostics` shows `Permission denied`: the user is signed in to a different Firebase project or rules were changed. Reinstall the app (which fetches a fresh `GoogleService-Info.plist` tied to the correct project) and confirm the same `bundleId` from `project.yml`.

---

## Incident 10: Mobile Shows "App Check blocked"

### Symptoms
- Sync diagnostics on iOS shows `App Check blocked` red status.
- Imports fail with `App Check rejected this device. See Diagnostics.`

### Diagnosis
1. Confirm App Check enforcement is enabled in Firebase Console (see `docs/FIREBASE_APP_CHECK_ENFORCEMENT.md`).
2. Confirm the build is signed with the team registered for App Check.
3. On a development build, set the App Check debug provider and register the debug token in the Firebase Console.

### Remediation
- Reinstall the app from the official channel (TestFlight/App Store) — sideloaded builds may not present a valid attestation token.
- Re-issue a debug token if developing locally.

---

## Incident 11: Pending Trust Stuck on Mobile

### Symptoms
- iOS Account screen shows trust pill `Pending`.
- Dashboard shows the "Approve this device" actionable card.

### Diagnosis
1. On the Mac, open **Devices & Sync**. The mobile device should appear in the **Pending approvals** section.
2. If it does not appear, sign out and back in on the mobile device so it re-registers with cloud sync.
3. Check that the user is signed into the same Firebase account on both devices.

### Remediation
- Click `Approve device` on the Mac for the mobile device. Mobile should refresh to `Trusted` within a few seconds (or after a manual pull-to-refresh).
- If no Mac device is yet trusted (first-device bootstrap), open Mac → Devices & Sync → **Bootstrap** → `Approve this Mac as primary device`.
- If the Mac shows the pending device but cannot approve it, check Sync diagnostics for any permission/App Check errors before retrying.

---

## Incident 12: Encrypted Credential Import Fails on Mobile

### Symptoms
- Mobile import progress reaches `Decrypted locally` or earlier and reports a classified failure.

### Diagnosis & Remediation by reason

| Reason on mobile | Likely cause | Remediation |
|---|---|---|
| `This transfer has been revoked.` | Mac revoked the grant. | Mac → Devices & Sync → Active escrow grants → start a new transfer. |
| `This envelope is encrypted for a different device.` | Mac encrypted for the wrong destination key. | Mac → Devices & Sync, confirm destination, restart transfer. |
| `This device's private key is missing or has been reset.` | iOS keychain was reset / reinstall. | Sign out + back in to regenerate keys; have Mac approve and re-export. |
| `Decryption failed.` | Envelope corrupted in transit. | Retry. If repeated, restart export from Mac. |
| `<Provider> rejected the credential.` | Credential expired or was rotated. | Reconnect provider on Mac, then re-export. |
| `Sign in again with the same account used on Mac.` | Permission denied. | Sign out and back in on the device that fails. |
| `App Check rejected this device.` | App Check enforcement. | See Incident 10. |

UI never claims `Validated` until provider readback, so any `Validated` step in history is authoritative.

---

## Escalation Contacts

| Role | Contact |
|------|---------|
| Maintainer | @Ajnunezg via GitHub |
| Security | See [SECURITY.md](../SECURITY.md) for private reporting |

## Post-Incident

After resolving any incident:

1. Document what happened in the commit message or incident notes
2. If a bug was found, file a GitHub Issue with reproduction steps
3. If the runbook was insufficient, update this document
4. If a migration issue occurred, update `DATABASE_OPERATIONS.md` and the rollback script catalog
