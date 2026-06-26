# Firestore Disaster Recovery

Production Firestore must be recoverable before any commercial launch or paid-data rollout. The database holds entitlements, vault-key wrappers, audit logs, usage, and hosted control-plane state, so DR proof is a launch blocker rather than a best-effort ops note.

## Required State

- Point-in-time recovery: `POINT_IN_TIME_RECOVERY_ENABLED`
- PITR retention window: at least 7 days (`versionRetentionPeriod >= 604800s`)
- Delete protection: `DELETE_PROTECTION_ENABLED`
- Backup schedules: at least one daily or weekly schedule with retention
- Verification: `bash scripts/ops/verify-firestore-disaster-recovery.sh`

The production ops plane runs this verifier as part of:

```bash
bash scripts/ops/verify-production-ops-plane.sh
```

Do not accept docs-only evidence for this control. The verifier reads the Firestore Admin API for the live project selected by `GCLOUD_PROJECT` / `GOOGLE_CLOUD_PROJECT` and `FIRESTORE_DATABASE_ID`.

## Restore Procedure

Firestore restores create a new database. Never restore over `(default)`. For BurnBar, run drills in the same `burnbar` project because there is no separate staging project with production-equivalent data. Always use a throwaway database ID and delete it after evidence capture.

Set the defaults:

```bash
export PROJECT="${GCLOUD_PROJECT:-burnbar}"
export DATABASE_ID="${FIRESTORE_DATABASE_ID:-(default)}"
export DRILL_TS="$(date -u +%Y%m%d%H%M%S)"
export RESTORE_DATABASE_ID="dr-drill-${DRILL_TS}"
```

PITR clone mode:

```bash
# Choose a timestamp inside the PITR window. Five minutes ago avoids the most
# recent-version edge while staying inside the 7-day retention window.
export SNAPSHOT_TIME="$(date -u -v-5M +%Y-%m-%dT%H:%M:00Z 2>/dev/null || date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:00Z)"

gcloud firestore databases clone \
  --project="$PROJECT" \
  --source-database="projects/${PROJECT}/databases/${DATABASE_ID}" \
  --destination-database="$RESTORE_DATABASE_ID" \
  --snapshot-time="$SNAPSHOT_TIME" \
  --format=json \
  >"launch-evidence/firestore-restore-drill-${DRILL_TS}.operation.json"
```

Backup restore mode:

```bash
export BACKUP_NAME="projects/${PROJECT}/locations/<location>/backups/<backup-id>"

gcloud firestore databases restore \
  --project="$PROJECT" \
  --source-backup="$BACKUP_NAME" \
  --destination-database="$RESTORE_DATABASE_ID" \
  --format=json \
  >"launch-evidence/firestore-restore-drill-${DRILL_TS}.operation.json"
```

Wait for the restore operation, replacing the operation name with the `name` field from the JSON above:

```bash
export RESTORE_OPERATION="$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).name)' "launch-evidence/firestore-restore-drill-${DRILL_TS}.operation.json")"
gcloud alpha firestore operations wait "$RESTORE_OPERATION" --project="$PROJECT"
```

## Drill Procedure

Run quarterly and before commercial launch from a non-primary machine:

1. Run `bash scripts/ops/verify-firestore-disaster-recovery.sh` against `(default)` and keep the JSON output.
2. Clone into `dr-drill-<timestamp>` using PITR unless the incident specifically tests backup restore.
3. Spot-check schema, index, and sentinel collections in the throwaway database.
4. Capture the summary evidence file and update the stable latest pointer.
5. Delete the throwaway database.
6. Re-run `bash scripts/ops/verify-firestore-disaster-recovery.sh` against `(default)`.

The repeatable drill runner performs these steps and writes the same evidence files:

```bash
bash scripts/ops/run-firestore-restore-drill.sh
```

Set `FIRESTORE_DRILL_MODE=backup` to exercise the newest READY scheduled backup for the configured source database instead of the PITR clone path. The runner refuses backups whose `database` field does not match `projects/${PROJECT}/databases/${DATABASE_ID}`. Set `FIRESTORE_DRILL_CLEANUP=0` only during incident response when the restored database must remain available for manual inspection.

Spot-check commands:

```bash
gcloud firestore databases describe "$RESTORE_DATABASE_ID" \
  --project="$PROJECT" \
  --format=json \
  >"launch-evidence/firestore-restore-drill-${DRILL_TS}.database.json"

gcloud firestore indexes composite list \
  --project="$PROJECT" \
  --database="$RESTORE_DATABASE_ID" \
  --format=json \
  >"launch-evidence/firestore-restore-drill-${DRILL_TS}.indexes.json"
```

Evidence summary:

```bash
node - <<'NODE' >"launch-evidence/firestore-restore-drill-${DRILL_TS}.json"
const fs = require("fs");
const env = process.env;
const operation = JSON.parse(fs.readFileSync(`launch-evidence/firestore-restore-drill-${env.DRILL_TS}.operation.json`, "utf8"));
const database = JSON.parse(fs.readFileSync(`launch-evidence/firestore-restore-drill-${env.DRILL_TS}.database.json`, "utf8"));
const indexes = JSON.parse(fs.readFileSync(`launch-evidence/firestore-restore-drill-${env.DRILL_TS}.indexes.json`, "utf8"));
console.log(JSON.stringify({
  generatedAt: new Date().toISOString(),
  project: env.PROJECT,
  sourceDatabase: env.DATABASE_ID,
  restoreDatabase: env.RESTORE_DATABASE_ID,
  snapshotTime: env.SNAPSHOT_TIME || null,
  operationName: operation.name,
  operationDone: operation.done === true,
  restoredDatabaseLocation: database.locationId,
  restoredDatabaseType: database.type,
  compositeIndexCount: Array.isArray(indexes) ? indexes.length : 0,
  rtoTargetHours: 4,
  rpoTargetHours: 1,
  pitrRetentionWindowHours: 168
}, null, 2));
NODE

cp "launch-evidence/firestore-restore-drill-${DRILL_TS}.json" \
  launch-evidence/latest-firestore-restore-drill.json
```

Cleanup:

```bash
gcloud firestore databases delete "$RESTORE_DATABASE_ID" \
  --project="$PROJECT" \
  --quiet
```

## RTO / RPO

- RTO target: less than 4 hours for a full production restore into a replacement database.
- RPO target: no more than 1 hour for operator-initiated recovery, backed by PITR and scheduled backups.
- Hard PITR ceiling: 7 days. The verifier fails if Firestore reports a shorter `versionRetentionPeriod`.
- Backup recovery: daily or weekly backup schedule with retention must exist; backups are the long-window recovery path when PITR is not old enough.

## Launch Gate

`scripts/commercial-launch-gate.mjs` shells this verifier and fails launch on any DR posture drift. The release run also requires fresh alert-delivery evidence because DR and human paging are paired launch blockers.

Related policy:

- `docs/SOLO_OPERATOR_POLICY.md` for the quarterly restore drill cadence.
- `docs/RELEASE_ROLLBACK.md` for app, functions, hosting, and Cloud Run rollback.

## Remediation

Use Google Cloud Console or `gcloud firestore databases update` to enable PITR and delete protection for the production database. Configure Firestore backup schedules from the Firestore Backup and Restore page, then rerun the verifier and attach the JSON output to the incident or release evidence.
