# Hermes Gateway Signal-Required Rollout

This is the production rollout path for cutting the hosted Hermes Gateway write
path over to Signal-required mode and draining legacy gateway queue records. It
mutates Cloud Run configuration and can delete production Firestore records, so
do not execute it without explicit release-owner approval for the exact release
commit.

This is an operational compliance runbook, not a substitute for legal advice.
Every evidence artifact it produces preserves one privacy contract:
`aggregate_counts_only_no_document_values_or_identifiers` — aggregate counts
only, never document values or identifiers.

## Scope

- Project: `burnbar`
- Region: `us-central1`
- Write-path services (Cloud Functions gen2 / Cloud Run):
  - `burnbarhermesgateway` (the `burnBarHermesGateway` HTTP function)
  - `enqueuehermesgatewayevent` (the `enqueueHermesGatewayEvent` callable)
- Required runtime flag: `OPENBURNBAR_GATEWAY_SIGNAL_REQUIRED=true`

### What the flag does

The Hermes Gateway Functions runtime reads `OPENBURNBAR_GATEWAY_SIGNAL_REQUIRED`
at request time and treats `1`, `true`, `yes`, or `on` as enabled. When the
flag is enabled on a serving revision:

- The production write validators stop accepting every legacy relay-envelope
  key version and reject new legacy `relayEnvelope` and `ratchetEnvelope`
  writes with a `failed-precondition` error instructing the client to provide
  `signalEnvelope` instead. Only official-libsignal `signalEnvelope` writes are
  accepted.
- Gateway clients must declare `supportsSignalEnvelope=true` during
  registration; non-Signal-capable clients are refused.
- Reads of already-stored legacy records stay tolerant so old queued documents
  still render until the drain below removes them.

If a Firebase deploy, Cloud Functions deploy, or another release system is used
instead of direct Cloud Run updates, the release is still not ready until the
Cloud Run readback evidence proves both write-path services expose
`OPENBURNBAR_GATEWAY_SIGNAL_REQUIRED=true` on their latest ready revisions.

## Preconditions

1. Confirm explicit release-owner approval for this production mutation and
   record the release commit. Do not proceed on inferred or implied approval.
2. Run the license-posture gates locally (the same gates
   `.github/workflows/license-posture.yml` enforces):

   ```bash
   python scripts/ci/check_burnbar_license_posture.py
   python scripts/ci/check_libsignal_runtime_readiness.py
   python scripts/ci/check_burnbar_crypto_architecture_policy.py
   node --test packages/e2ee-backend-policy/lib/index.test.js packages/e2ee-backend-policy/lib/index.crossdrift.test.js
   python scripts/ci/write_burnbar_source_provenance.py --check
   ```

3. Install Functions dependencies and authenticate. The evidence collector and
   drain tool load `firebase-admin` from `functions/node_modules` and shell out
   to `gcloud`, so `npm ci --prefix functions` must have run and Application
   Default Credentials plus an authenticated `gcloud` session must be in place.
4. Capture a before snapshot. This is expected to fail validation while legacy
   records or non-Signal-required services remain — that is the point of the
   baseline:

   ```bash
   node scripts/ci/write_hermes_gateway_migration_drain_evidence.js \
     --project-id burnbar \
     --deployed-commit <release-commit-sha> \
     --source-location https://github.com/Imagine-That-Ai/BurnBar/tree/<release-commit-sha> \
     --runtime-mode-from-gcloud \
     --output launch-evidence/hermes-gateway-migration-drain-before-<timestamp>.json
   ```

   `--deployed-commit` and `--source-location` are required for live evidence;
   `--runtime-mode-from-gcloud` makes the collector read the deployed mode back
   from Cloud Run instead of trusting a locally asserted flag.

## Enable Signal-Required Mode

Generate the dry-run rollout plan first. Without `--execute` the driver only
writes a plan (`mode: "dry_run"`, `safety.mutatesCloudRun: false`) and touches
nothing:

```bash
node scripts/ci/rollout_hermes_gateway_signal_required.js \
  --output launch-evidence/hermes-gateway-signal-required-rollout-plan-<timestamp>.json
```

Update both write-path services only after the preconditions above. The guarded
driver refuses `--execute` unless the exact confirmation phrase is supplied:

```bash
node scripts/ci/rollout_hermes_gateway_signal_required.js \
  --execute \
  --confirm enable-hermes-gateway-signal-required \
  --output launch-evidence/hermes-gateway-signal-required-rollout-execute-<timestamp>.json
```

The command above performs the equivalent Cloud Run updates for both write-path
services:

```bash
gcloud run services update burnbarhermesgateway \
  --project burnbar \
  --region us-central1 \
  --update-env-vars OPENBURNBAR_GATEWAY_SIGNAL_REQUIRED=true

gcloud run services update enqueuehermesgatewayevent \
  --project burnbar \
  --region us-central1 \
  --update-env-vars OPENBURNBAR_GATEWAY_SIGNAL_REQUIRED=true
```

The driver defaults to project `burnbar`, region `us-central1`, and exactly
these two services; `--project-id`, `--region`, and repeated `--service` flags
override them, and `--self-test` exercises the argument and plan logic without
touching `gcloud`.

### Recovery: Cloud Functions gen2 source redeploy

If a direct Cloud Run update fails because a previous mutable function image
tag has been removed from Artifact Registry, do not run the legacy drain.
Recover with a Cloud Functions gen2 source redeploy of the affected function
from its existing Cloud Storage source artifact, applying only the
Signal-required env-var update while preserving the current service settings.
Use the source path from
`gcloud functions describe <function> --gen2 --region us-central1` rather than
the local checkout:

```bash
gcloud functions deploy burnBarHermesGateway \
  --gen2 \
  --project burnbar \
  --region us-central1 \
  --runtime nodejs22 \
  --entry-point burnBarHermesGateway \
  --trigger-http \
  --source gs://gcf-v2-sources-246956661961-us-central1/burnBarHermesGateway/function-source.zip \
  --update-env-vars OPENBURNBAR_GATEWAY_SIGNAL_REQUIRED=true \
  --serve-all-traffic-latest-revision \
  --concurrency 40 \
  --min-instances 1 \
  --max-instances 100 \
  --memory 256Mi \
  --timeout 60s \
  --service-account 246956661961-compute@developer.gserviceaccount.com

gcloud functions deploy enqueueHermesGatewayEvent \
  --gen2 \
  --project burnbar \
  --region us-central1 \
  --runtime nodejs22 \
  --entry-point enqueueHermesGatewayEvent \
  --trigger-http \
  --source gs://gcf-v2-sources-246956661961-us-central1/enqueueHermesGatewayEvent/function-source.zip \
  --update-env-vars OPENBURNBAR_GATEWAY_SIGNAL_REQUIRED=true \
  --serve-all-traffic-latest-revision \
  --concurrency 80 \
  --max-instances 100 \
  --memory 256Mi \
  --timeout 60s \
  --service-account 246956661961-compute@developer.gserviceaccount.com
```

After any recovery deploy, re-run the Cloud Run evidence collector. The
collector must prove the latest ready revisions — not merely a desired service
template — are serving `OPENBURNBAR_GATEWAY_SIGNAL_REQUIRED=true`: it runs
`gcloud run services describe` for each service, then
`gcloud run revisions describe` on the latest ready revision, and a service
only counts as Signal-required when its `Ready` condition is `True` and that
revision's container env carries the enabled flag.

## Verify Runtime Mode

Immediately capture runtime-mode evidence from Cloud Run. Do not paste raw
Cloud Run JSON into release artifacts; the collector stores only service names,
latest ready revisions, service URLs, and Signal-required booleans, plus
aggregate per-collection record counts:

```bash
node scripts/ci/write_hermes_gateway_migration_drain_evidence.js \
  --project-id burnbar \
  --deployed-commit <release-commit-sha> \
  --source-location https://github.com/Imagine-That-Ai/BurnBar/tree/<release-commit-sha> \
  --runtime-mode-from-gcloud \
  --output launch-evidence/hermes-gateway-migration-drain-signal-required-<timestamp>.json
```

The evidence must show:

- `writePath.signalRequired: true`, with both `burnbarhermesgateway` and
  `enqueuehermesgatewayevent` listed and each reporting `signalRequired: true`
- `legacyRelayWritesEnabled`, `legacyRatchetWritesEnabled`, and
  `legacyPlaintextWritesEnabled` all `false`
- no legacy relay, ratchet, plaintext, unreadable, or truncated record counts
  before it can complete the readiness gate

## Drain Legacy Gateway Records

The drain tool pages through the `hermes_gateway_events`,
`hermes_gateway_messages`, and `hermes_gateway_attachments` collection groups,
classifies every document, always retains Signal-envelope records, and deletes
only legacy relay, ratchet, plaintext, and unreadable records. Always run a
dry-run first — without `--execute` it deletes nothing and reports counts only:

```bash
node scripts/ci/drain_hermes_gateway_legacy_records.js \
  --project-id burnbar \
  --output launch-evidence/hermes-gateway-legacy-drain-dry-run-<timestamp>.json
```

Execute deletion only after Signal-required runtime-mode evidence exists and
the dry-run counts have been reviewed:

```bash
node scripts/ci/drain_hermes_gateway_legacy_records.js \
  --project-id burnbar \
  --execute \
  --confirm delete-legacy-hermes-gateway-records \
  --runtime-mode-evidence launch-evidence/hermes-gateway-migration-drain-signal-required-<timestamp>.json \
  --output launch-evidence/hermes-gateway-legacy-drain-execute-<timestamp>.json
```

The drain tool is guarded twice: `--execute` fails unless
`--confirm delete-legacy-hermes-gateway-records` is supplied exactly, and
unless `--runtime-mode-evidence` names evidence proving the write path is
already Signal-required on both services. This ordering matters — deleting
legacy records while legacy writes are still enabled would let new legacy
records reappear behind the drain.

## Final Gate Evidence

After the drain, collect and validate the final migration-drain snapshot:

```bash
node scripts/ci/write_hermes_gateway_migration_drain_evidence.js \
  --project-id burnbar \
  --deployed-commit <release-commit-sha> \
  --source-location https://github.com/Imagine-That-Ai/BurnBar/tree/<release-commit-sha> \
  --runtime-mode-from-gcloud \
  --output launch-evidence/hermes-gateway-migration-drain-final-<timestamp>.json

python scripts/ci/check_hermes_gateway_migration_drain.py \
  launch-evidence/hermes-gateway-migration-drain-final-<timestamp>.json \
  --repo-root .
```

The validator fails closed unless the evidence shows a Signal-required write
path on both services, zero legacy and unreadable records, `signalRead` equal
to the total in every collection, no truncated samples, a 40-character release
commit SHA, an `https://` source location, `docs/legal/SOURCE_AVAILABILITY.md`
as the source-availability pointer, and the `functions/package-lock.json` and
`packages/signal-envelope-contracts/package-lock.json` dependency locks
(the repo root is the Nous/Hermes MIT upstream graft point and owns no root manifests).

Only after that validation passes may `third_party/libsignal/runtime-readiness.json`
mark the gateway write-path gates — `hermes_gateway_writes` and
`hermes_attachment_writes` — complete, with a matching `completedEvidence`
record naming the validated JSON evidence path. In other words, operators
may mark the gate complete only after the final validator passes.

## Rollback

If Signal-required mode causes production write failures before legacy records
are drained, disable the runtime flag on both services and capture a rollback
evidence snapshot. Rollback uses the same guarded driver with its own
confirmation phrase:

```bash
node scripts/ci/rollout_hermes_gateway_signal_required.js \
  --rollback \
  --execute \
  --confirm rollback-hermes-gateway-signal-required \
  --output launch-evidence/hermes-gateway-signal-required-rollback-<timestamp>.json
```

The rollback action emits the equivalent `gcloud run services update ...`
commands with `--remove-env-vars OPENBURNBAR_GATEWAY_SIGNAL_REQUIRED` for both
write-path services.

If the guarded legacy drain has executed, rollback cannot restore deleted
legacy queue records. This means rollback cannot restore deleted legacy queue
records after execute mode runs. Treat the execute step as a one-way production
data mutation and run it only after the Signal-capable client surface has been
verified.

## Privacy Stance

Every artifact this runbook produces — rollout plans, runtime-mode readbacks,
dry-run and execute drain reports, and the final gate evidence — carries the
`aggregate_counts_only_no_document_values_or_identifiers` marker and contains
only aggregate counts, classification tallies, service names, revision names,
service URLs, and boolean mode flags. No document IDs, user IDs, ciphertext,
wrapped keys, file names, or payload fields ever enter a release artifact, and
`scripts/ci/check_hermes_gateway_migration_drain.py` rejects evidence with
unexpected keys so nothing else can be smuggled in.
