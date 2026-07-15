# Shared Rust Promotion Evidence

Use this runbook before changing a shared-Rust consumer from `shadow` to `rust`.
Promotion authority is the protected deterministic GitHub attestation described
below. Runtime telemetry is optional diagnostic input; it is not a gate and no
duration, daily continuity, user count, or sample count is required.

No V1, V2, or V3 telemetry bundle can authorize promotion or legacy deletion.
V3 is the only candidate-bound diagnostic schema. V1 and V2 are drain-only.

After protected promotion, every Rust-authoritative release must consume the
candidate-bound pre-release gate in
[`shared-rust-release-evidence.md`](shared-rust-release-evidence.md).

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

## Optionally enroll the candidate for diagnostics

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

## Optionally collect V3 shadow samples

The exact client DTO is
[`domain-core-shadow-sample-v3.schema.json`](../contracts/domain-core-shadow-sample-v3.schema.json).
Every V3 sample includes the candidate commit, expected core tuple, and loaded
core tuple. The server requires its channel, consumer, candidate commit, and
expected core tuple to match the six enrollment claims, validates the operation
against its real domain and slice. The historical `promotionEligible` storage
field identifies valid V3 diagnostic records; it does not grant promotion
authority.

A successful comparison requires a complete loaded tuple equal to the expected
tuple. A different loaded tuple is retained only as
`loaded_identity_mismatch`; it is a hard blocker and cannot be explained away.
Native-unavailable and native-error evidence also cannot contribute to a
passing cohort. Samples never contain uid, device identity, paths, payloads,
parsed results, plaintext, credentials, keys, or stable payload hashes.

Apple, Android, and Windows durably spool bounded JSONL batches under their
application-private support/files directories. Each spool namespace is derived
from the complete expected candidate tuple, so a new candidate never reads or
uploads a prior candidate's queue. Console CloudVault applies the same rule to
bounded origin-scoped browser storage. Native clients discard V1, V2,
incomplete, and stale candidate namespaces when a signed candidate is
installed. Console preserves legacy shared V2/V3 keys byte-for-byte for older
deployments to drain and never reads, relabels, or deletes them. New V3 samples
use immutable candidate-, writer-, and sample-bound keys, so tabs never share a
mutable read-modify-write queue.
Coalesced maintenance removes malformed and out-of-window immutable records
and retains at most 800 active-candidate samples and 3,200 samples globally.
No client reads, uploads, rewrites, or relabels
another candidate's records as V3 evidence for the active candidate. A client
removes an active-candidate batch only after every sample is accepted as new or
idempotently duplicate. Sign-out and transport failures leave that batch queued
for authenticated retry. Successfully read records that are malformed, older
than 31 days, or more than five minutes in the future are discarded locally
without blocking valid records behind them; transient storage read failures
retain the unacknowledged batch for retry. Evidence setup, persistence,
acknowledgement, and cleanup are best-effort diagnostics and must never change
the result of quota, CloudVault, Hermes, pricing, or application startup work.

Functions pricing comparisons do not cross a client boundary and therefore do
not carry client enrollment claims. A deployed process may write them only when
its immutable compiled receipt contains a complete signed candidate tuple. It
records the actually loaded Wasm version, ABI, and source fingerprint, or an
all-null tuple when the module identity cannot be read, then writes through the
same V3 parser and immutable Firestore persistence path. A different readable
tuple is retained only as `loaded_identity_mismatch` blocker evidence; it can
never become a promotable success. Local, test, unsigned, or incomplete
processes do not emit production evidence. Firestore rules deny direct client
writes, and the server stamps both `receivedAt` and the 60-day `expireAt` TTL.

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

## Optionally export one exact diagnostic cohort

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

The export retains server-received daily counts and real `(slice, consumer)`
dimensions so sparse coverage, mixed candidates, unavailable versions, partial
loaded identities, unknown operations, and duplicate IDs remain visible. Those
conditions are diagnostic alerts. The exporter never relabels or fabricates
records, but a complete export is still not promotion authority.

The command uses Application Default Credentials and writes owner-only output.
`source-uri` is provenance, not a credential; queries, fragments, usernames,
and passwords are rejected.

## Evaluate optional diagnostics

```bash
node scripts/ci/evaluate-domain-core-promotion.mjs \
  --domain quota \
  --evidence /absolute/path/to/collected-evidence.json \
  --output /absolute/path/to/promotion-readiness.json
```

Exit status `2` with `status: diagnostic`, `ready: false`, and
`authority: diagnostic-only` means the candidate-bound diagnostic report was
validly evaluated. Exit status `1` means invalid input or policy. This command
never exits with promotion success and no report-file state grants authority.

The CLI accepts only the committed
[`config/domain-core-shadow-diagnostic-policy.json`](../../config/domain-core-shadow-diagnostic-policy.json)
and has no policy override. It covers only the real owners in the inventory:

- quota: Claude, Codex, Cursor, and Anthropic on Apple and Windows;
- CloudVault: foundation/AES/escrow on Apple, Android, Windows, and Console;
  recovery on Apple, Android, and Windows; document rewrap/search on Apple and Android;
- Hermes: AAD, payload/key-wrap, HPKE info, and ratchet on Apple and Android;
- pricing: token cost on Apple and Functions, plus legacy Kimi in Functions.

The diagnostic evaluator checks candidate identity, real coverage cells,
channels, mismatch categories, and latency when samples exist. It intentionally
has no minimum duration or sample target and always reports `ready: false`.

Ordinary result mismatches may be marked `explained` only with a GitHub issue or
PR, named reviewer, and approval timestamp. Unexplained mismatches always block.
Native-unavailable, native-error, and loaded-identity mismatches are hard
blockers even if review metadata is attached; `loaded_identity_mismatch` must
remain explicitly unexplained.

An implementation having a Rust export is not proof. The exporter never
fabricates an empty, continuous, or passing window, and telemetry volume never
substitutes for the deterministic workflow below.

## Create and attest deterministic proof

1. Merge the exact candidate to `main`. A PR merge ref, dispatch checkout, or
   unmerged commit is ineligible.
2. Require the `Shared Rust domain core` `push` run at that commit to succeed.
   Its 14 exact policy job IDs expand to 16 exact GitHub API jobs because Windows
   runs x64 and ARM64 separately and the final `candidate-bundle` job aggregates
   them. Any failed, skipped, missing, duplicate, extra, mixed-run, or
   mixed-candidate job fails closed.
3. The jobs emit suite reports and artifact hashes tied to the exact run ID,
   attempt, commit, version, ABI, and source fingerprint. Required native/Wasm
   load suites prove Swift, Kotlin, C#, both Python native packages, browser
   Wasm, and Node Wasm artifacts.
   The same run executes all 51 policy coverage cells, deterministic KATs and
   fuzz/property suites, the paired five-percent performance ceiling, and the
   real signed-legacy rollback drill.
4. The final job creates
   `domain-core-candidate-bundle-COMMIT-RUN-ATTEMPT`. It is unsigned and says
   only `eligible_for_attestation`; it is not promotion authority.
5. Dispatch `Shared Rust domain core promotion proof` with the full candidate
   commit. The workflow runs under the protected `domain-core-promotion`
   environment, pins the evaluator and policy checkout to the exact `main`
   commit that GitHub used for the dispatch, proves the candidate is reachable
   from `main`, queries GitHub for the exact
   successful push run, downloads its immutable bundle, and independently
   verifies the API run/jobs, policy, bundle, and candidate checkout.
6. Only the GitHub provenance attestation produced after that trusted-main
   verification authorizes the reviewed promotion. The uploaded
   `protected-verification.json` receipt remains non-authoritative; it is an
   audit record containing the pinned evaluator commit and control-plane
   manifest digest, not a signature or shortcut.

The GitHub environment is a live security control. It must retain at least one
required reviewer and a deployment branch policy allowing only `main`; the
signer verifies both through the GitHub API before attesting. Operator
verification on 2026-07-14 confirmed required reviewer `Ajnunezg` and only the
`main` branch. If those settings drift, stop and repair the environment rather
than weakening the workflow.

## Promotion and deletion sequence

1. Retain the protected provenance attestation, unsigned candidate bundle,
   candidate identity, workflow run/attempt, and review links. Retain any V3
   export only as optional diagnostic evidence.
2. Verify the attestation and independently satisfy security and
   consumer-specific release gates.
3. Promote only the attested domain/consumer to `rust`. Publish and retain the
   exact candidate-bound `public-production-rollback` artifact, whose signed
   modes are permanently all-legacy; do not delete the old implementation in
   this PR.
4. Ship one stable signed release of the exact attested candidate with Rust
   authoritative. Retain a dedicated signed legacy rollback artifact until
   deletion completes. Any mismatch, performance regression, loaded-identity
   failure, rollback, or new candidate commit requires a new exact
   deterministic proof.
5. Open a separate legacy-deletion PR only after the stable-release gate. Bind
   its proof to the same attested candidate/core tuple, official GitHub
   provenance bundle, and exact retained rollback artifact hash. Neither the
   unsigned bundle nor `protected-verification.json` is authority.
6. Run source-absence and compile gates proving the named legacy transforms,
   selectors, and fallback calls are gone while Rust-only builds still pass.
7. Clear candidate enrollment when collection is no longer authorized. Retain
   the evidence and rollback/deletion review records according to release policy.

Never commit runtime telemetry or synthetic passing proof. Tests construct
synthetic bundles solely to prove fail-closed evaluator behavior.
