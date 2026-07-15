# Shared Rust Release Evidence

Use this runbook when a release or deployment includes a public build profile
with one or more shared Rust domains in `rust` mode. The release lane must prove
the exact deterministic candidate before it builds, signs, or deploys the
Rust-authoritative artifact. A matching core version or source fingerprint is
not sufficient: the candidate commit is part of the identity.

Runtime telemetry has no release authority. There is no 14-day, 10,000-sample,
user-count, or continuity requirement in this gate.

## Required chain

Every release predicate and deployment receipt uses schema version 2 and binds:

- the exact candidate tuple: `candidateCommit`, `coreVersion`, `abiVersion`, and
  `sourceSha256`;
- the deterministic `domain-core.yml` source run ID and attempt;
- the protected `domain-core-promotion-proof.yml` signer run ID and attempt;
- the SHA-256 digest of the protected Sigstore attestation bundle and its exact
  `domain-core-candidate-bundle.json` subject;
- a candidate-matched legacy rollback artifact and its SHA-256 digest;
- the exact release tag and commit; and
- the released native artifact or deployment receipt bytes.

The release commit must equal `candidateCommit`. A later commit is rejected even
when its core version, ABI version, and source fingerprint are unchanged.

## Pre-release gate

Download the unsigned candidate bundle, its protected provenance attestation,
and the exact rollback artifact selected by the release workflow. Resolve all
expected values from GitHub-authoritative run metadata and the signed build
profile, then run:

```bash
node scripts/ci/verify-domain-core-release-gate.mjs \
  --candidate-bundle "$RUNNER_TEMP/domain-core-candidate-bundle.json" \
  --promotion-attestation "$RUNNER_TEMP/promotion.sigstore.json" \
  --rollback-artifact "$RUNNER_TEMP/domain-core-legacy-rollback.json" \
  --candidate-commit "$CANDIDATE_COMMIT" \
  --core-version "$CORE_VERSION" \
  --abi-version "$ABI_VERSION" \
  --source-sha256 "$SOURCE_SHA256" \
  --source-run-id "$SOURCE_RUN_ID" \
  --source-run-attempt "$SOURCE_RUN_ATTEMPT" \
  --protected-signer-run-id "$SIGNER_RUN_ID" \
  --protected-signer-run-attempt "$SIGNER_RUN_ATTEMPT" \
  --rollback-sha256 "$ROLLBACK_SHA256" \
  --output "$RUNNER_TEMP/domain-core-release-gate.json"
```

The verifier fails closed unless `gh attestation verify` accepts the protected
workflow identity, GitHub-hosted runner requirement, main ref, SLSA predicate,
exact candidate-bundle digest, and the certificate's exact signer run invocation
URI. It also rejects any substitution in the candidate tuple, source run and
attempt, or rollback bytes. The output is create-only and a byte-identical retry
is idempotent.

Native, Console, and Functions release workflows should call this command before
their first signing or deployment mutation whenever the public profile selects
Rust. Workflow-specific wiring is deliberately separate from this substrate.

## Generate release evidence

After the artifact is signed or the deployment is healthy, use
`create-domain-core-release-evidence.mjs` once per released domain. It verifies
the protected promotion attestation again and writes an immutable v2 predicate.
Console and Functions also supply `--deployment`; the command creates the
deployment receipt first, then hashes those exact bytes into the predicate.

The contracts are:

- [`domain-core-release-predicate.schema.json`](../../config/domain-core-release-predicate.schema.json)
- [`domain-core-deployment-receipt.schema.json`](../../config/domain-core-deployment-receipt.schema.json)

The generator refuses to replace an existing output unless the bytes are
identical. The release workflow must attest the artifact with the generated v2
predicate and its consumer-specific protected signer workflow.

## Publish immutable assets

Pass the artifact and all domain attestation bundles to
`publish-domain-core-release-evidence.mjs` in a version 2 publication manifest.
The publisher:

1. validates every predicate and verifies every local attestation bundle;
2. requires the exact release tag to already exist as a published stable release;
3. downloads and verifies every existing name collision before any upload;
4. uploads attestation bundles first with create-only GitHub release operations;
5. uploads the artifact last; and
6. freshly downloads and verifies every final asset.

It never creates, edits, or deletes a release, and never uses `--clobber`.
Artifact retries and concurrent winners must be byte-identical. Existing or
concurrently published Sigstore bundles may use a different valid encoding,
but they are reused only after verification against the exact artifact,
predicate, signer workflow, repository, tag, and commit. A substituted bundle,
non-identical artifact collision, or semantic final-state mutation fails the
run.

## Ownership boundary

This substrate defines verification, evidence generation, and immutable
publication. Each consumer workflow owns artifact signing, deployment health,
its explicit legacy fallback exercise, and the decision to invoke this gate.
No workflow may ship a Rust-authoritative profile without consuming the
pre-release gate successfully.
