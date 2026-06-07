# Hermes Gateway Signal-required Rollout

This runbook is the release-owner path for switching Hermes Gateway writes to
Signal-required mode. It requires explicit release-owner approval and counsel
approval before a public release.

## Preconditions

- `OPENBURNBAR_GATEWAY_SIGNAL_REQUIRED=true` has been approved for the target
  services.
- `scripts/ci/rollout_hermes_gateway_signal_required.js` has been reviewed.
- `scripts/ci/write_hermes_gateway_migration_drain_evidence.js` has produced
  aggregate_counts_only_no_document_values_or_identifiers evidence.
- `scripts/ci/check_hermes_gateway_migration_drain.py` has passed.
- Unknown, unreadable, malformed, and parser-miss records are zero. If any
  exist, stop release, export them to a private quarantine artifact, and
  investigate manually. Do not drain unidentified records.

## Enable

Use the dry-run first:

```bash
node scripts/ci/rollout_hermes_gateway_signal_required.js \
  enable-hermes-gateway-signal-required --dry-run
```

Then update Cloud Run services only after approval:

```bash
gcloud run services update burnbarhermesgateway \
  --update-env-vars OPENBURNBAR_GATEWAY_SIGNAL_REQUIRED=true
gcloud run services update enqueuehermesgatewayevent \
  --update-env-vars OPENBURNBAR_GATEWAY_SIGNAL_REQUIRED=true
```

Cloud Functions gen2 source redeploy must use the same source commit.

## Evidence

Collect runtime evidence:

```bash
node scripts/ci/write_hermes_gateway_migration_drain_evidence.js \
  --deployed-commit "$GIT_SHA" \
  --source-location "$SOURCE_LOCATION" \
  --runtime-mode-from-gcloud \
  --output launch-evidence/hermes-gateway-drain.json
python scripts/ci/check_hermes_gateway_migration_drain.py \
  launch-evidence/hermes-gateway-drain.json
python3 scripts/ci/write_cloudvault_at_rest_runtime_evidence.py \
  --output launch-evidence/cloudvault-at-rest-runtime.json \
  --check
```

The CloudVault writer runs the real compiled Functions/contract checks and stores
only privacy-preserving command-output hashes. `--check` must remain a HOLD until
the data-domain registry actually enables a Signal at-rest sealing scheme; do not
hand-edit `signalAtRestWritesEnabled` to clear the gate.

## Drain

Dry-run first:

```bash
node scripts/ci/drain_hermes_gateway_legacy_records.js \
  --runtime-mode-evidence launch-evidence/hermes-gateway-drain.json \
  --output launch-evidence/hermes-gateway-drain-dry-run.json
```

Execute only known legacy records, never unknown/private data:

```bash
node scripts/ci/drain_hermes_gateway_legacy_records.js \
  --execute \
  --confirm delete-legacy-hermes-gateway-records \
  --project-id burnbar \
  --live-production-acknowledgement mutate-production-hermes-gateway-records-in-burnbar \
  --runtime-mode-evidence launch-evidence/hermes-gateway-drain.json \
  --predelete-export launch-evidence/private/hermes-gateway-predelete-private.json \
  --quarantine-output launch-evidence/private/hermes-gateway-quarantine-private.json \
  --output launch-evidence/hermes-gateway-drain-execute.json
```

The `private/` outputs contain document paths and values. Keep them out of git,
logs, public evidence bundles, and support tickets. If the quarantine file is
created, the execute run failed before deleting records and release remains
blocked until those records are classified or explicitly retained by a signed
release-owner review.

## Rollback

```bash
node scripts/ci/rollout_hermes_gateway_signal_required.js \
  rollback-hermes-gateway-signal-required
gcloud run services update burnbarhermesgateway \
  --remove-env-vars OPENBURNBAR_GATEWAY_SIGNAL_REQUIRED
gcloud run services update enqueuehermesgatewayevent \
  --remove-env-vars OPENBURNBAR_GATEWAY_SIGNAL_REQUIRED
```
