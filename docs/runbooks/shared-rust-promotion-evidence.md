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

Production promotion evidence must be exported by the protected
`Shared Rust promotion observation` workflow. Dispatch it only from `main` and
provide an exact candidate commit already reachable from that trusted branch.
The workflow reads
Firestore with GitHub OIDC, runs the candidate's exporter and pinned policy,
attests only a ready report, and retains the aggregate evidence, report,
Sigstore bundle, and hash manifest as one Actions artifact. A local export is
useful for diagnosis but cannot authorize promotion.

The GitHub `domain-core-promotion` environment is a required-review boundary,
not a naming convention. Keep at least one release owner configured as an
environment reviewer, restrict its deployment branch policy to `main`, and do not move the OIDC
credentials into an unprotected job. The workflow also requires its dispatch
SHA, checked-out SHA, attestation source SHA, and requested candidate SHA to be
identical. The candidate must already be reachable from the trusted `main`
builder. The signed report records the candidate as `provenance.queryRevision`;
the gate separately pins the builder with `--source-ref refs/heads/main`,
`--source-digest`, and `--signer-digest`.

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

1. Retain the protected workflow's aggregate evidence artifact and generated
   report with the rollout review.
2. Confirm every non-quantitative roadmap gate independently.
3. Use `scripts/ops/create-domain-core-promotion-receipt.py` to commit the
   aggregate readiness report, its generation-scoped attestation, and receipts.
   The gate revalidates the complete report and binds its review URI and SHA-256,
   pinned domain policy, candidate-commit Rust fingerprint, core version, and
   real candidate commit. The gate verifies the committed report's GitHub OIDC
   provenance against the protected workflow and exact candidate commit.
   Runtime samples remain outside Git; only the aggregate evaluator output and
   its Sigstore bundle are committed. Record both the rollout candidate SHA and
   the trusted `main` builder SHA when generating the receipt. Advance the complete mapped row set to
   `promotion_approved`, and change only the reviewed public build-profile mode
   to `rust`; keep explicit rollback.
4. Observe one stable release for every applicable consumer, then commit
   stable-release receipts containing each consumer's tag, release commit,
   artifact digest, and signed-provenance digest, and advance
   the rows to `rust_authoritative_with_rollback`.
   Functions now has a tag-bound producer for its canonical healthy-deployment
   receipt and exact custom predicate; it stays dormant while the public pricing
   profile remains legacy-authoritative. This remains
   blocked for domains that require Apple, Android, Windows, or Console until
   those producer workflows land the equivalent evidence.
5. Run source/compile gates proving the inventory's named deletion targets are
   absent before marking that row complete.

If Rust is rolled back after promotion or deletion approval, add an explicit `rollback` receipt and
move the whole mapped domain to `rollback_active`. Restoring Rust starts a new
authority generation whose promotion receipt must bind the previous rollback.
Old stable-release receipts can never authorize deletion after a rollback. A
new generation must start every coverage window after the prior rollback's
actual activation time, so copying an older signed report cannot re-authorize
Rust.
Any existing deletion review remains immutable and attached to the rolled-back
generation, but it cannot authorize deletion after the new generation begins.

The source gate and receipt procedure are defined in the
[Shared Rust Legacy Deletion Runbook](shared-rust-legacy-deletion.md). Promotion
reports do not update deletion state automatically, and a passing quantitative
report cannot substitute for the stable-release or deletion-review receipts.

Never commit runtime telemetry or synthetic passing evidence to the repository.
The test suite constructs synthetic bundles in memory solely to prove evaluator
behavior.
