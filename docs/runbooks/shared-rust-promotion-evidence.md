# Shared Rust Promotion Evidence

Use this gate before changing a shared-Rust consumer from `shadow` to `rust`.
A passing report is necessary, not sufficient: fixture, artifact, security,
stable-release, and deletion gates in the
[roadmap](../SHARED_RUST_DOMAIN_CORE_ROADMAP.md) still apply.

## Run the gate

```bash
node scripts/ci/evaluate-domain-core-promotion.mjs \
  --domain quota \
  --evidence /absolute/path/to/collected-evidence.json \
  --output /absolute/path/to/promotion-readiness.json
```

Exit status `0` means `ready`, `2` means valid evidence that is `not_ready`,
and `1` means invalid input or policy. Automation must require both status `0`
and `ready: true`; a report file's existence is not success.

The committed
[`config/domain-core-promotion-policy.json`](../../config/domain-core-promotion-policy.json)
is the only policy accepted by the CLI. It intentionally has no policy override.

## Collect shadow samples

Consumers emit schema-v2 samples only for a signed `internal` or `beta`
profile. Enroll the account with matching `domainCoreShadowChannel` and
`domainCoreShadowConsumers` claims. The callable rejects an absent or
mismatched enrollment; a request cannot self-authorize its channel or consumer.

Apple, Android, and Windows consumers durably spool bounded JSONL batches under
their application-private support/files directories. Console CloudVault keeps
at most 800 exact samples in origin-scoped browser storage and uploads in
100-sample batches. Each client removes a batch only after the callable accepts
every sample as new or idempotently duplicate; sign-out and transport failures
leave it queued for a later authenticated retry. Their Firebase callable
clients attach Auth and App Check tokens, and the callable also enforces the
signed profile's channel and consumer claims.

Functions pricing comparisons do not cross a client boundary. In the deployed
Cloud Functions runtime they are written idempotently through the same V2
parser and Firestore persistence helper; local and test processes do not emit
production evidence. Firestore rules deny direct client writes, stored
documents contain no uid, and the `expireAt` TTL is 60 days.

Before collecting beta evidence, enable and verify the declared TTL:

```bash
gcloud firestore fields ttls update expireAt \
  --collection-group=domain_core_shadow_samples \
  --enable-ttl \
  --project=burnbar
node scripts/ci/verify-firestore-ttl-state.mjs --project burnbar
```

The exact promotion DTO is
[`domain-core-shadow-sample-v2.schema.json`](../contracts/domain-core-shadow-sample-v2.schema.json).
`domain`, `slice`, and `consumer` are validated together, so a client cannot
invent a promotion cell. Samples contain only rollout identity, outcome,
version, operation, timestamp, and whole-call latency. Never add uid, device
identity, paths, payloads, parsed results, plaintext, credentials, keys, or
stable hashes.

Ingress still accepts exact
[`domain-core-shadow-sample-v1.schema.json`](../contracts/domain-core-shadow-sample-v1.schema.json)
quota samples so already-spooled batches can retry idempotently. V1 has no slice
identity, is excluded by the V2 exporter, and always receives the
`evidence_schema_v2_required` blocker. Never translate V1 into V2.

## Export collected evidence

```bash
node scripts/ops/export-domain-core-promotion-evidence.mjs \
  --project burnbar \
  --domain quota \
  --start 2026-06-29T00:00:00Z \
  --end 2026-07-13T00:00:00Z \
  --channel beta \
  --core-version 0.3.0 \
  --source-uri https://console.cloud.google.com/firestore/databases/-default-/data/panel/domain_core_shadow_samples \
  --output /absolute/path/to/collected-evidence.json
```

Run export and evaluation separately for each domain, using the same `--domain`
value. Coverage dates come from actual earliest and latest matching samples,
never operator query bounds. The exporter reads stored V1 and V2 documents but
selects only exact V2 records for the requested domain. It rejects unknown
fields, invalid identities/timings, duplicate IDs, credential-bearing source
URLs, missing required coverage, and coverage with only one timestamp.

The command uses Application Default Credentials and writes owner-only output.
The `source-uri` is provenance, not a credential; queries, fragments, usernames,
and passwords are rejected.

## Coverage policy

The policy covers only the real owners in the inventory:

- quota: Claude, Codex, Cursor, and Anthropic on Apple and Windows;
- CloudVault: foundation/AES/escrow on Apple, Android, Windows, and Console;
  recovery on Apple, Android, and Windows; document rewrap/search on Apple and Android;
- Hermes: AAD, payload/key-wrap, HPKE info, and ratchet on Apple and Android;
- pricing: token cost on Apple and Functions, plus legacy Kimi in Functions.

Each required `(slice, consumer)` pair has one evidence window. Missing,
duplicate, invented, or unexpected pairs fail closed. The evaluator also blocks
ineligible channels, short coverage, insufficient aggregate samples,
unexplained mismatches, partial latency sampling, future timestamps, unsafe
integers, and excessive p95 regression.

An implementation having a Rust export is not evidence. A domain remains
blocked until every real consumer submits actual V2 comparisons. The exporter
never fabricates an empty or passing window.

## Mismatch review

Unexplained mismatches always block promotion. A category may be `explained`
only with a GitHub issue or PR, named reviewer, and approval timestamp. Analysis
belongs in that linked review record; the readiness report retains counts
without copying review metadata.

## Promotion and deletion

1. Retain source evidence and the generated report with the rollout review.
2. Confirm every non-quantitative roadmap gate independently.
3. Change only the reviewed consumer mode to `rust`; keep explicit rollback.
4. Observe one stable Rust-authoritative release.
5. Delete legacy code only in a separate change with source and compile gates.

Never commit runtime telemetry or synthetic passing evidence. Tests construct
synthetic bundles in memory solely to prove fail-closed evaluator behavior.
