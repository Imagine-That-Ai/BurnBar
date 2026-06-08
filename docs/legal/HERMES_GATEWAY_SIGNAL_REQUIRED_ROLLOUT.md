# Hermes Gateway Signal-required Rollout

This runbook is the release-owner path for switching Hermes Gateway writes to
Signal-required mode. It requires explicit release-owner approval and counsel
approval before a public release.

## Preconditions

- `OPENBURNBAR_GATEWAY_SIGNAL_REQUIRED=true` has been approved for the target
  services, and the deployed commit has been verified to contain the production
  Signal-envelope write path (`HERMES_GATEWAY_PRODUCTION_SIGNAL_ENVELOPE_VERSIONS`
  includes v4).
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
  enable-hermes-gateway-signal-required \
  --deployed-commit "$GIT_SHA" \
  --source-location "$SOURCE_LOCATION" \
  --dry-run
```

Then update Cloud Run services only after approval. The helper writes the
Signal-required flag and the source-provenance environment variables
(`OPENBURNBAR_SOURCE_COMMIT` and `OPENBURNBAR_CORRESPONDING_SOURCE_URL`)
together; do not use a flag-only `gcloud run services update` because the drain
validator must bind the live revision to the exact source commit it is proving.

```bash
node scripts/ci/rollout_hermes_gateway_signal_required.js \
  enable-hermes-gateway-signal-required \
  --project-id burnbar \
  --region us-central1 \
  --deployed-commit "$GIT_SHA" \
  --source-location "$SOURCE_LOCATION"
```

Cloud Functions gen2 source redeploy must use the same source commit.

## Evidence

Collect runtime evidence:

```bash
python3 scripts/ci/write_native_signal_runtime_evidence.py \
  --gate swift_round_trips \
  --output launch-evidence/native-signal-swift-runtime.json \
  --check
python3 scripts/ci/write_native_signal_runtime_evidence.py \
  --gate kotlin_round_trips \
  --output launch-evidence/native-signal-kotlin-runtime.json \
  --check
python3 scripts/ci/write_native_signal_runtime_evidence.py \
  --gate rust_core_bridge \
  --output launch-evidence/native-signal-rust-runtime.json \
  --check
node scripts/ci/write_hermes_gateway_migration_drain_evidence.js \
  --deployed-commit "$GIT_SHA" \
  --source-location "$SOURCE_LOCATION" \
  --runtime-mode-from-gcloud \
  --output launch-evidence/hermes-gateway-drain.json
python scripts/ci/check_hermes_gateway_migration_drain.py \
  --repo-root . \
  launch-evidence/hermes-gateway-drain.json
python3 scripts/ci/write_cloudvault_at_rest_runtime_evidence.py \
  --output launch-evidence/cloudvault-at-rest-runtime.json \
  --check
python3 scripts/ci/write_signal_envelope_contract_runtime_evidence.py \
  --output launch-evidence/signal-envelope-contract-runtime.json \
  --check
```

Attach generated evidence to the runtime-readiness manifest only through the
manifest attachment tool:

```bash
python3 scripts/ci/attach_libsignal_runtime_evidence.py \
  --gate swift_round_trips \
  --artifact launch-evidence/native-signal-swift-runtime.json \
  --replay-native-commands
python3 scripts/ci/attach_libsignal_runtime_evidence.py \
  --gate kotlin_round_trips \
  --artifact launch-evidence/native-signal-kotlin-runtime.json \
  --replay-native-commands
python3 scripts/ci/attach_libsignal_runtime_evidence.py \
  --gate rust_core_bridge \
  --artifact launch-evidence/native-signal-rust-runtime.json \
  --replay-native-commands
python3 scripts/ci/attach_libsignal_runtime_evidence.py \
  --gate node_contracts \
  --artifact launch-evidence/signal-envelope-contract-runtime.json
python3 scripts/ci/attach_libsignal_runtime_evidence.py \
  --gate hermes_gateway_writes \
  --artifact launch-evidence/hermes-gateway-drain.json
python3 scripts/ci/attach_libsignal_runtime_evidence.py \
  --gate hermes_attachment_writes \
  --artifact launch-evidence/hermes-gateway-drain.json
python3 scripts/ci/attach_libsignal_runtime_evidence.py \
  --gate migration_telemetry \
  --artifact launch-evidence/hermes-gateway-drain.json
python3 scripts/ci/attach_libsignal_runtime_evidence.py \
  --gate cloudvault_private_domains \
  --artifact launch-evidence/cloudvault-at-rest-runtime.json
python3 scripts/ci/attach_agpl_legal_release_approval.py \
  --reviewer-name "External Counsel Name or Firm" \
  --approved-at "2026-06-08T15:00:00Z" \
  --signature launch-evidence/agpl-release-review.sig \
  --public-key launch-evidence/counsel-public.pem \
  --use-required-channels \
  --check
python3 scripts/ci/attach_agpl_legal_release_approval.py \
  --reviewer-name "External Counsel Name or Firm" \
  --approved-at "2026-06-08T15:00:00Z" \
  --signature launch-evidence/agpl-release-review.sig \
  --public-key launch-evidence/counsel-public.pem \
  --use-required-channels
python3 scripts/ci/attach_libsignal_runtime_evidence.py \
  --gate store_and_counsel_approval \
  --artifact launch-evidence/latest-agpl-store-legal-packet.json
```

Use `--check` first when reviewing a packet; the legal attach tool verifies the
detached counsel signature without writing, and the manifest attach tool runs
the validator and manifest post-check without writing. The manifest attach tool
writes only typed evidence with an `artifactPath`, `artifactType`, `sha256`,
`validatorCommand`, and structured `validatorResult`; it replaces stale
same-gate evidence, refuses legal `--allow-pending`, requires a dedicated
artifact validator for `node_contracts`,
and keeps `status` as `not_ready`. Final `ready` promotion is a separate
release-manager action after `check_burnbar_release_preflight.py` passes and
counsel approval is real.

The CloudVault writer runs the real compiled Functions/contract checks and stores
only privacy-preserving command-output hashes. `--check` must remain a HOLD until
the data-domain registry actually enables a Signal at-rest sealing scheme; do not
hand-edit `signalAtRestWritesEnabled` to clear the gate.

The Node Signal-envelope contract writer bootstraps the shared package,
Functions, hosted MCP, and Hermes realtime relay from their lockfiles before
running the contract tests, so the packet proves a clean dependency install plus
the consumer tests instead of relying on pre-existing `node_modules`.

The native Signal writer uses the same privacy-preserving command-evidence
shape. It records command status, exit code, duration, stdout/stderr hashes, and
named assertions only on the command entry that produced them. A runtime gate in
`third_party/libsignal/runtime-readiness.json` may be marked `complete` only
after its generated artifact is referenced by `artifactPath`, `sha256`,
`validatorCommand`, and passing `validatorResult`; do not hand-edit platform
status fields or assertion strings.

## Drain

Dry-run first:

```bash
node scripts/ci/drain_hermes_gateway_legacy_records.js \
  --runtime-mode-evidence launch-evidence/hermes-gateway-drain.json \
  --output launch-evidence/hermes-gateway-drain-dry-run.json
```

Execute only known legacy records, never unknown/private data:

```bash
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
node scripts/ci/drain_hermes_gateway_legacy_records.js \
  --execute \
  --confirm delete-legacy-hermes-gateway-records \
  --project-id burnbar \
  --live-production-acknowledgement mutate-production-hermes-gateway-records-in-burnbar \
  --runtime-mode-evidence launch-evidence/hermes-gateway-drain.json \
  --predelete-export "launch-evidence/private/hermes-gateway-predelete-${RUN_ID}-private.json" \
  --quarantine-output "launch-evidence/private/hermes-gateway-quarantine-${RUN_ID}-private.json" \
  --output launch-evidence/hermes-gateway-drain-execute.json
```

The `private/` outputs contain document paths and values. Keep them out of git,
logs, public evidence bundles, and support tickets. The script writes these
files with exclusive-create semantics; if a path already exists, stop and choose
a new timestamped path rather than overwriting a recovery artifact. If the
quarantine file is created, the execute run failed before deleting records and
release remains blocked until those records are classified or explicitly
retained by a signed release-owner review.

## Rollback

```bash
node scripts/ci/rollout_hermes_gateway_signal_required.js \
  rollback-hermes-gateway-signal-required
gcloud run services update burnbarhermesgateway \
  --remove-env-vars OPENBURNBAR_GATEWAY_SIGNAL_REQUIRED
gcloud run services update enqueuehermesgatewayevent \
  --remove-env-vars OPENBURNBAR_GATEWAY_SIGNAL_REQUIRED
```
