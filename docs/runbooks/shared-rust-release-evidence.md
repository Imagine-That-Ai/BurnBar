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
  --rollback-artifact "$RUNNER_TEMP/domain-core-public-production-rollback.json" \
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

## Console and Hosting lane

[`deploy-hosting.yml`](../../.github/workflows/deploy-hosting.yml) always uses
`public-production` for automatic `main` and stable-tag deploys. A main deploy
may omit protected proof only while Console CloudVault remains `legacy`; a
stable tag or Rust-authoritative build fails closed without the exact protected
candidate bundle, signer run and attempt, source run and attempt, Sigstore
bundle, and candidate-matched rollback artifact.

`public-production-rollback` is manual-only. It must target an existing stable
tag and pass the separate `domain-core-promotion` protected environment before
the ordinary `production` deployment environment. Automatic pushes cannot
select it.

Every build embeds `domain-core-deployment-identity.json` and a deterministic
`domain-core-runtime-artifact-manifest.json`. The manifest hashes the deployed
identity, selected build profile, domain-core WASM, and every JavaScript loader
that can instantiate it. The live smoke reads both files from the canonical
Console origin without following redirects, verifies every manifest-listed
file byte-for-byte, and records the exact Firebase Hosting version and live
release names for both reviewed sites (`burnbar` and `burnbar-console`). The
release predicate uses the canonical per-domain public-profile digest consumed
by the deletion gate; the identity separately retains the complete resolved
profile receipt digest.

Before a stable tag can deploy again, the credentialed job reads the current
Firebase live release/version coordinates and the public runtime manifest. It
may reuse existing evidence only when both the bytes and provider coordinates
match the immutable receipt. Any moved live release, stale bytes, absent target,
or receipt mismatch fails before the Hosting release mutation.

After a healthy stable deployment,
[`domain-core-console-release-evidence.yml`](../../.github/workflows/domain-core-console-release-evidence.yml)
revalidates the exact deploy run and attempt, reruns the protected release gate,
creates the v2 Console receipt and predicate, and signs them. The signed
deployment document retains the exact deploy run and attempt alongside the live
health proof. Normal evidence is published through the create-only shared
GitHub release publisher. Each rollback evidence workflow result is retained as
an Actions artifact named with both deploy and evidence workflow coordinates.
Reruns are independently verifiable records of the same deployment, not a
permanent replay lock based on an expiring artifact. The workflow references the
signer's retained rollback artifact and never uploads a duplicate copy.

## Native release wiring

The stable native release lanes resolve the same protected chain before any
platform signing starts:

- [`.github/workflows/release.yml`](../../.github/workflows/release.yml) covers
  the notarized Apple DMG and signed Android AAB;
- [`.github/workflows/openburnbar-release-windows.yml`](../../.github/workflows/openburnbar-release-windows.yml)
  covers the Authenticode-signed x64 and ARM64 Windows packages; and
- tag-triggered releases always select `public-production`. A tag cannot request
  the rollback profile.

An emergency manual release may select `public-production-rollback`. That path
must pass the protected `domain-core-promotion` environment before signing and
must resolve the candidate-bound, all-legacy rollback profile. It is an explicit
release of legacy behavior, not an exception to candidate, signing, or evidence
verification.

The native gate downloads artifacts by exact candidate commit, deterministic
source run ID, and source run attempt. It then downloads GitHub Attestations for
the candidate bundle, verifies the protected signer identity, and binds the
signer's exact run ID and attempt. The ordinary protected-verification workflow
artifact is a diagnostic receipt and is not accepted as promotion authority.

## Generate release evidence

After the artifact is signed or the deployment is healthy, use
`create-domain-core-release-evidence.mjs` once per released domain. It verifies
the protected promotion attestation again and writes an immutable v2 predicate.
Console and Functions also supply `--deployment`; the command creates the
deployment receipt first, then hashes those exact bytes into the predicate.

The contracts are:

- [`domain-core-release-predicate.schema.json`](../../config/domain-core-release-predicate.schema.json)
- [`domain-core-deployment-receipt.schema.json`](../../config/domain-core-deployment-receipt.schema.json)

CI compiles both contracts as Draft 2020-12 schemas with Ajv and validates
generated positive receipts plus missing-coordinate, mixed-consumer, duplicate-
target, and unknown-field negatives. A schema that merely parses as JSON is not
an accepted release contract.

The generator refuses to replace an existing output unless the bytes are
identical. The release workflow must attest the artifact with the generated v2
predicate and its consumer-specific protected signer workflow.

Native release predicates are generated after platform-native verification:

- Apple verifies notarization, the protected TeamIdentifier and leaf signing
  authority, the arm64 app executable, the embedded build-profile receipt, and
  the Rust identity reported by a signed probe executed directly from the
  mounted DMG. The report includes the probe's own SHA-256 and is checked
  against those mounted bytes.
- Android verifies the approved upload-certificate fingerprint, JAR signature,
  bundletool structure, both supported 64-bit native ABIs, the embedded build-profile
  receipt, and the Rust identity observed on an arm64 emulator. The loaded
  library digest must match the arm64 library extracted from the final AAB.
- Windows verifies both x64 and ARM64 profile receipts and executes the signed
  x64 domain-core DLL extracted from the final portable ZIP. Its observed
  digest must match that exact packaged DLL before the deterministic canonical
  bundle containing both signed architectures is attested.

Only domains in `rust` mode receive public-release predicates. A rollback
release intentionally retains predicates for every consumer domain so the
all-legacy rollback event remains auditable.

## Publish immutable assets

Pass the artifact and all domain attestation bundles to
`publish-domain-core-release-evidence.mjs` in a version 2 publication manifest.
The publisher:

1. validates every predicate and verifies every local attestation bundle;
2. requires the exact release tag and candidate commit; Apple and Android use
   an existing published stable release, while Windows uses an exact private
   draft;
3. downloads and verifies every existing name collision before any upload;
4. uploads attestation bundles first with create-only GitHub release operations;
5. uploads the artifact last; and
6. freshly downloads and verifies every final asset; and
7. publishes the Windows draft only after every final verification succeeds.

It never deletes a release and never uses `--clobber`. The only edit it may
perform is the final draft-to-published transition for a completely verified
Windows release. An all-legacy native profile still publishes the canonical
artifact through the same create-only path, with an explicitly empty evidence
bundle set.
Artifact retries and concurrent winners must be byte-identical. Existing or
concurrently published Sigstore bundles may use a different valid encoding,
but they are reused only after verification against the exact artifact,
predicate, signer workflow, repository, tag, and commit. A substituted bundle,
non-identical artifact collision, or semantic final-state mutation fails the
run.

## Functions release lane

[`deploy-production.yml`](../../.github/workflows/deploy-production.yml) owns
the Functions-specific consumer boundary:

- release-tag pushes always select `public-production`;
- a manual `public-production-rollback` deploy first requires approval in the
  `domain-core-promotion` environment, then the existing `production`
  environment approval;
- the exact source run bundle, candidate-matched rollback artifact, protected
  Sigstore bundle, and protected signer run and attempt pass the pre-release
  gate before `npm ci`, compilation, or Firebase deployment;
- the generated `domainCoreCandidateReceipt.js`, selected profile bytes,
  deterministic runtime artifact manifest, and v2 release-gate receipt are
  captured in a create-only deploy proof;
- the live `healthLive` and `healthReady` endpoints must serve the exact source
  commit, release version, candidate tuple, profile name, pricing mode, and
  production Sentry state before deploy-health evidence can be written; and
- both endpoints report the intrinsic core identity, SHA-256 of the actual
  loaded WASM bytes, runtime-manifest digest, and Cloud Run service/revision.

The protected target inventory is
[`domain-core-functions-relevant-targets.json`](../../config/domain-core-functions-relevant-targets.json).
After deploy, every listed Function must be `ACTIVE`, carry the exact tag,
commit, and runtime-manifest environment, and resolve to one immutable provider
source object. Evidence records each Function, build, service, and revision.
Missing, extra, duplicate, or mixed old/new targets fail closed.

A stable-tag replay authenticates only for provider readback, queries every
protected Function, and compares the current source/build/service/revision set
and health-served bytes to the existing receipt. Byte-identical code on a new
revision is not reusable evidence. The replay becomes a no-op only when both
artifact and provider coordinates are unchanged; otherwise it fails before
Sentry or Firebase deployment mutation.

After that gate succeeds, the deploy workflow dispatches
[`domain-core-functions-release-evidence.yml`](../../.github/workflows/domain-core-functions-release-evidence.yml)
with the exact deploy run and attempt. The evidence workflow downloads only
those uniquely named artifacts, waits for that attempt to finish successfully,
requires the exact normal or protected-rollback job matrix, recreates the deploy
proof byte-for-byte, reverifies the protected promotion attestation, creates the
v2 Functions deployment receipt and predicate, and emits an official GitHub
attestation. The durable receipt retains the deploy workflow, run ID, attempt,
event, tag ref, head commit, canonical job-set digest, and deploy-health artifact
digest so the stable asset remains auditable after temporary Actions artifacts
expire.

Normal `public-production` evidence is published through the create-only v2
release publisher after the exact stable GitHub release exists. A rollback does
not overwrite those stable assets: it retains a uniquely named Actions artifact
containing the receipt, predicate, official provenance bundle, deploy proof, and
health evidence keyed by tag, deploy run, and attempt.

The general macOS publisher never includes the DMG in a clobber upload. It
preflights an existing same-name DMG before any release mutation. Stable DMGs
are uploaded only by the evidence publisher; prerelease DMGs use the dedicated
create-only asset publisher and receive the same collision and final-download
checks.

## Ownership boundary

This substrate defines verification, evidence generation, and immutable
publication. Each consumer workflow owns artifact signing, deployment health,
its explicit legacy fallback exercise, and the decision to invoke this gate.
No workflow may ship a Rust-authoritative profile without consuming the
pre-release gate successfully.

The protected signer control-plane manifest must cover these native release
workflows and every helper they execute with attestation or publication
permissions. Regenerate and review that manifest whenever this wiring changes;
otherwise a candidate commit could change its own verifier. Native workflow
changes and signer-manifest changes therefore land as one reviewed integration.
