# Shared Rust Promotion Evidence

Use this gate before changing a shared-Rust consumer from `shadow` to `rust`.
A passing report is necessary, not sufficient: fixture, artifact, security,
stable-release, and deletion gates in the
[roadmap](../SHARED_RUST_DOMAIN_CORE_ROADMAP.md) still apply.

No V1 or V2 bundle can authorize promotion or legacy deletion. Candidate-bound
V3 is the only promotable evidence schema.

## Identify one release candidate

Collect evidence for one exact app commit and one exact loaded Rust core. Record:

- the lowercase 40-character candidate Git commit;
- the canonical domain-core semantic version;
- the positive uint32 domain-core ABI version; and
- the lowercase 64-character SHA-256 source fingerprint from
  [`union-abi-manifest.json`](../../crates/openburnbar-domain-core/union-abi-manifest.json).

The candidate's signed build metadata supplies the expected tuple. The loaded
native or Wasm module supplies its observed version, ABI, and source fingerprint.
A sidecar file or matching version string alone is not loaded-module proof.

## Enroll the candidate

An enrolled Firebase account has exactly six domain-core custom claims:

| Claim                              | Meaning                             |
| ---------------------------------- | ----------------------------------- |
| `domainCoreShadowChannel`          | Signed `internal` or `beta` channel |
| `domainCoreShadowConsumers`        | Canonical consumer allowlist        |
| `domainCoreShadowCandidateCommit`  | Exact app candidate commit          |
| `domainCoreShadowCoreVersion`      | Expected canonical Rust SemVer      |
| `domainCoreShadowCoreAbiVersion`   | Expected positive uint32 ABI        |
| `domainCoreShadowCoreSourceSha256` | Expected Rust source fingerprint    |

Preview, apply, and independently verify the complete enrollment:

```bash
node scripts/ops/manage-domain-core-shadow-enrollment.mjs \
  --uid FIREBASE_UID \
  --project burnbar \
  --channel beta \
  --consumers apple,windows \
  --candidate-commit 0123456789abcdef0123456789abcdef01234567 \
  --core-version 0.3.0 \
  --core-abi-version 3 \
  --core-source-sha256 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

node scripts/ops/manage-domain-core-shadow-enrollment.mjs \
  --uid FIREBASE_UID \
  --project burnbar \
  --channel beta \
  --consumers apple,windows \
  --candidate-commit 0123456789abcdef0123456789abcdef01234567 \
  --core-version 0.3.0 \
  --core-abi-version 3 \
  --core-source-sha256 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --apply

node scripts/ops/manage-domain-core-shadow-enrollment.mjs \
  --uid FIREBASE_UID \
  --project burnbar \
  --channel beta \
  --consumers apple,windows \
  --candidate-commit 0123456789abcdef0123456789abcdef01234567 \
  --core-version 0.3.0 \
  --core-abi-version 3 \
  --core-source-sha256 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --verify
```

The command is a dry run without `--apply`. Enrollment is all-or-nothing. A
partial, malformed, differently ordered, or mismatched claim set fails closed.
The callable also requires Firebase Auth and App Check; claims do not replace
attestation.

Use `--clear --apply` after the observation is retained or immediately when a
candidate is revoked. Clearing removes all six domain-core claims even if the
stored enrollment is partial or malformed.

## Collect V3 shadow samples

The exact client DTO is
[`domain-core-shadow-sample-v3.schema.json`](../contracts/domain-core-shadow-sample-v3.schema.json).
Every V3 sample includes the candidate commit, expected core tuple, and loaded
core tuple. The server requires its channel, consumer, candidate commit, and
expected core tuple to match the six enrollment claims, validates the operation
against its real domain and slice, and stores `promotionEligible: true` only for
accepted V3 samples.

A successful comparison requires a complete loaded tuple equal to the expected
tuple. A different loaded tuple is retained only as
`loaded_identity_mismatch`; it is a hard blocker and cannot be explained away.
Native-unavailable and native-error evidence also cannot contribute to a
passing cohort. Samples never contain uid, device identity, paths, payloads,
parsed results, plaintext, credentials, keys, or stable payload hashes.

Apple, Android, and Windows durably spool bounded JSONL batches under their
application-private support/files directories. Console CloudVault uses bounded
origin-scoped browser storage. A client removes a batch only after every sample
is accepted as new or idempotently duplicate. Sign-out and transport failures
leave the batch queued for authenticated retry.

Functions pricing comparisons do not cross a client boundary. Deployed Cloud
Functions write through the same parser and immutable Firestore persistence
path. Local and test processes do not emit production evidence. Firestore rules
deny direct client writes, and the server stamps both `receivedAt` and the
60-day `expireAt` TTL.

Before collecting beta evidence, enable and verify the TTL:

```bash
gcloud firestore fields ttls update expireAt \
  --collection-group=domain_core_shadow_samples \
  --enable-ttl \
  --project=burnbar
node scripts/ci/verify-firestore-ttl-state.mjs --project burnbar
```

Ingress still accepts exact V1 and V2 batches so already-spooled evidence can
drain idempotently. The server stores them with `promotionEligible: false`.
They are never backfilled or translated to V3, and evaluation returns
`evidence_schema_v3_required`.

## Export one exact cohort

```bash
node scripts/ops/export-domain-core-promotion-evidence.mjs \
  --project burnbar \
  --domain quota \
  --start 2026-06-29T00:00:00Z \
  --end 2026-07-13T00:00:00Z \
  --channel beta \
  --candidate-commit 0123456789abcdef0123456789abcdef01234567 \
  --expected-core-version 0.3.0 \
  --expected-core-abi-version 3 \
  --expected-core-source-sha256 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --source-uri https://console.cloud.google.com/firestore/databases/-default-/data/panel/domain_core_shadow_samples \
  --output /absolute/path/to/collected-evidence.json
```

Run export and evaluation separately for each domain. The exporter queries the
server-owned `receivedAt` field over the half-open interval
`[--start, --end)`. Client `observedAt` cannot add, remove, or move a sample in
that window. The exporter then selects only records matching the exact domain,
channel, candidate commit, expected version, expected ABI, and expected source
fingerprint.

The old `--core-version` and `--query-revision` export flags are rejected. An
operator cannot relabel one candidate's records as another revision. The output
preserves the candidate tuple at the report root and in `provenance`.

Each required `(slice, consumer)` window contains server-received daily sample
counts. Every UTC day touched by the half-open observation interval must have at
least one accepted V3 sample for every required coverage cell. Earliest/latest
timestamps alone are not continuity. Missing days, mixed candidates, same
SemVer with a different source fingerprint, unavailable versions, partial
loaded identities, unknown operations, duplicate IDs, or missing coverage fail
closed.

The command uses Application Default Credentials and writes owner-only output.
`source-uri` is provenance, not a credential; queries, fragments, usernames,
and passwords are rejected.

## Evaluate the report

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
The policy covers only the real owners in the inventory:

- quota: Claude, Codex, Cursor, and Anthropic on Apple and Windows;
- CloudVault: foundation/AES/escrow on Apple, Android, Windows, and Console;
  recovery on Apple, Android, and Windows; document rewrap/search on Apple and Android;
- Hermes: AAD, payload/key-wrap, HPKE info, and ratchet on Apple and Android;
- pricing: token cost on Apple and Functions, plus legacy Kimi in Functions.

The evaluator requires one common candidate observation window, complete daily
continuity, all real coverage cells, at least 14 days, at least 10,000 aggregate
samples, eligible channels, complete latency sampling, safe integer arithmetic,
and p95 Rust latency no more than five percent above legacy.

Ordinary result mismatches may be marked `explained` only with a GitHub issue or
PR, named reviewer, and approval timestamp. Unexplained mismatches always block.
Native-unavailable, native-error, and loaded-identity mismatches are hard
blockers even if review metadata is attached; `loaded_identity_mismatch` must
remain explicitly unexplained.

An implementation having a Rust export is not evidence. A domain remains
blocked until every real consumer submits actual candidate-bound comparisons.
The exporter never fabricates an empty, continuous, or passing window.

## Promotion and deletion sequence

1. Retain the raw V3 export, readiness report, candidate identity, and review
   links as immutable rollout evidence.
2. Confirm `ready: true` and independently satisfy fixtures, artifact-load,
   ABI/source provenance, security, release, and consumer-specific gates.
3. Promote only the reviewed domain/consumer to `rust`. Keep the explicit
   `legacy` rollback setting; do not delete the old implementation in this PR.
4. Observe one stable signed release with Rust authoritative. Any mismatch,
   missing day, latency regression, loaded-identity failure, rollback, or new
   candidate commit invalidates the applicable observation and restarts it.
5. Open a separate legacy-deletion PR only after the stable-release gate. Bind
   its deletion proof to the same candidate/core tuple and retained V3 report.
6. Run source-absence and compile gates proving the named legacy transforms,
   selectors, and fallback calls are gone while Rust-only builds still pass.
7. Clear candidate enrollment when collection is no longer authorized. Retain
   the evidence and rollback/deletion review records according to release policy.

Never commit runtime telemetry or synthetic passing evidence. Tests construct
synthetic bundles solely to prove fail-closed evaluator behavior.
