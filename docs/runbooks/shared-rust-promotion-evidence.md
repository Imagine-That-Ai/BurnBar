# Shared Rust Promotion Evidence

Use this gate before changing a shared-Rust consumer from `shadow` to `rust`.
It evaluates rollout evidence against the committed policy and emits a JSON
readiness report. A passing report is necessary, not sufficient: fixture,
artifact, security-review, release, and deletion gates in the
[roadmap](../SHARED_RUST_DOMAIN_CORE_ROADMAP.md) still apply.

## Run the gate

```bash
node scripts/ci/evaluate-domain-core-promotion.mjs \
  --evidence /absolute/path/to/collected-evidence.json \
  --output /absolute/path/to/promotion-readiness.json
```

Exit status `0` means `ready`, `2` means valid evidence that is `not_ready`,
and `1` means invalid input or policy. Automation must require status `0` and
`ready: true`; it must not interpret a report file's existence as success.

The default policy is
[`config/domain-core-promotion-policy.json`](../../config/domain-core-promotion-policy.json).
Policy changes require normal code review and must not be supplied by a rollout
job. The CLI intentionally has no policy override; proposed policy changes are
exercised by the evaluator's unit tests before merge.

## Collect quota shadow samples

Quota consumers emit schema-v1 samples only when the rollout channel is
`internal` or `beta`. Set `OPENBURNBAR_DOMAIN_CORE_ROLLOUT_CHANNEL` to one of
those values in the signed build environment and enroll the signed-in account
with the matching Firebase Auth custom claim
`domainCoreShadowChannel: "internal" | "beta"`. The callable rejects absent or
mismatched claims; the request body cannot self-assert enrollment. An absent,
unknown, or `production` build value disables collection. Parser payloads and
parsed quota values never cross the evidence boundary.

Apple spools bounded JSONL batches under
`Application Support/OpenBurnBar/DomainCoreShadow`; Windows uses
`LocalApplicationData/OpenBurnBar/DomainCoreShadow`. Each platform retains at
most eight ready files with at most 100 samples per file and acknowledges a
batch only after the callable accepts every sample as new or idempotently
duplicate. The callable requires Firebase Auth and App Check and is the only
write path to `domain_core_shadow_samples`; Firestore rules deny direct client
access. Documents do not persist the authenticated uid and expire after 60
days via `expireAt`.

Before collecting beta evidence, enable and verify the live Firestore TTL
policy declared in [`ops/firestore-ttl-policies.json`](../../ops/firestore-ttl-policies.json):

```bash
gcloud firestore fields ttls update expireAt \
  --collection-group=domain_core_shadow_samples \
  --enable-ttl \
  --project=burnbar
node scripts/ci/verify-firestore-ttl-state.mjs --project burnbar
```

The exact ingress DTO is
[`docs/contracts/domain-core-shadow-sample-v1.schema.json`](../contracts/domain-core-shadow-sample-v1.schema.json).
It contains only platform, rollout, outcome, version, operation, timestamp, and
whole-call latency metadata. Do not add uid, device identity, file paths,
payloads, parsed results, credentials, or stable hashes.

## Export collected evidence

Use the reviewed exporter to produce evaluator input directly from the retained
collection. Each consumer's coverage is derived from its actual earliest and
latest matching sample, never from the operator's query bounds. The export
fails if either required consumer has no matching samples or only one observed
timestamp. The exporter rejects unexpected stored fields, mixed schema data,
invalid timings, duplicate sample IDs, and credential-bearing source URLs.

```bash
node scripts/ops/export-domain-core-promotion-evidence.mjs \
  --project burnbar \
  --start 2026-06-29T00:00:00Z \
  --end 2026-07-13T00:00:00Z \
  --channel beta \
  --core-version 0.3.0 \
  --source-uri https://console.cloud.google.com/firestore/databases/-default-/data/panel/domain_core_shadow_samples \
  --output /absolute/path/to/collected-evidence.json
```

The command uses Application Default Credentials and writes the output with
owner-only permissions. Treat its `source-uri` as provenance, not a credential;
queries, fragments, usernames, and passwords are rejected.

## Evidence contract

Evidence is aggregated metadata. It must not contain payloads, parsed values,
credentials, user identifiers, or stable payload hashes.

```json
{
  "schemaVersion": 1,
  "domain": "quota",
  "coreVersion": "0.1.0",
  "generatedAt": "<RFC3339 UTC timestamp>",
  "provenance": {
    "collector": "domain-core-shadow-v1",
    "queryRevision": "<full lowercase Git revision of the collector/query>",
    "sourceUri": "<credential-free HTTPS evidence-run URL>"
  },
  "windows": [
    {
      "consumer": "apple",
      "channel": "beta",
      "startedAt": "<RFC3339 UTC timestamp>",
      "endedAt": "<RFC3339 UTC timestamp>",
      "sampleCount": 0,
      "mismatches": [],
      "latency": {
        "sampleCount": 0,
        "legacyP95Micros": 0,
        "rustP95Micros": 0
      }
    }
  ]
}
```

The example is a shape template, not runtime evidence, and intentionally fails
validation. Generate the real bundle from the reviewed collector/query named in
`provenance`. Do not hand-edit counts or timestamps. The source URI must point
to retained collector output; signed URLs and query strings are rejected to
avoid placing credentials in reports or logs.

Each required consumer has one window. The gate rejects duplicate or unexpected
consumers, production-channel samples, coverage shorter than policy, partial
latency sampling, future timestamps, unknown fields, unsafe integers, and p95
regressions over policy. Latency is expressed as integer microseconds; the gate
uses integer basis-point arithmetic at the threshold.

## Mismatch review

Unexplained mismatches always block promotion. A reviewed mismatch category may
be marked `explained` only with all of these fields:

```json
{
  "category": "legacy_precision",
  "count": 1,
  "resolution": "explained",
  "issue": "https://github.com/openburnbar/openburnbar/issues/123",
  "reviewedBy": "@reviewer",
  "approvedAt": "<RFC3339 UTC timestamp>"
}
```

Categories are identifiers, not free-form messages. Put analysis in the linked
review record. The readiness report emits category counts and blockers without
copying reviewer or issue metadata.

## Promotion and deletion

1. Retain the source evidence and generated report with the rollout review.
2. Confirm every non-quantitative roadmap gate independently.
3. Change only the reviewed consumer mode to `rust`; keep the rollback mode.
4. Observe one stable release before proposing legacy deletion.
5. Run source/compile gates proving the inventory's named deletion targets are
   absent before marking that row complete.

Never commit runtime telemetry or synthetic passing evidence to the repository.
The test suite constructs synthetic bundles in memory solely to prove evaluator
behavior.
