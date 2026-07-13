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
