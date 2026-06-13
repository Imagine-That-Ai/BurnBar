# Firestore Disaster Recovery

Production Firestore must be recoverable before any commercial launch or paid-data rollout.

## Required State

- Point-in-time recovery: `POINT_IN_TIME_RECOVERY_ENABLED`
- Delete protection: `DELETE_PROTECTION_ENABLED`
- Backup schedules: at least one daily or weekly schedule with retention
- Verification: `bash scripts/ops/verify-firestore-disaster-recovery.sh`

The production ops plane runs this verifier as part of:

```bash
bash scripts/ops/verify-production-ops-plane.sh
```

## Remediation

Use Google Cloud Console or `gcloud firestore databases update` to enable PITR and delete protection for the production database. Configure Firestore backup schedules from the Firestore Backup and Restore page, then rerun the verifier and attach the JSON output to the incident or release evidence.

Do not accept docs-only evidence for this control. The verifier reads the Firestore Admin API for the live project selected by `GCLOUD_PROJECT` / `GOOGLE_CLOUD_PROJECT` and `FIRESTORE_DATABASE_ID`.
