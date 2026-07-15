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

The native release lanes resolve the same protected chain before any platform
signing starts:

- [`.github/workflows/release.yml`](../../.github/workflows/release.yml) covers
  the notarized Apple DMG and signed Android AAB;
- [`.github/workflows/openburnbar-release-windows.yml`](../../.github/workflows/openburnbar-release-windows.yml)
  covers the Authenticode-signed x64 and ARM64 Windows packages; and
- stable and prerelease tag-triggered releases always select
  `public-production`. A tag cannot request the rollback profile.

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

- Apple verifies notarization and the committed signing pins in
  [`config/apple-release-signing-policy.json`](../../config/apple-release-signing-policy.json).
  `APPLE_TEAM_ID`, `APPLE_SIGNING_IDENTITY`, and the `codesign` output for the
  outer DMG and mounted app must all match Team ID `4Y367DF25B` and the exact
  Developer ID leaf authority. The mounted app's shipped
  `Contents/MacOS/OpenBurnBar` executable runs its internal
  `--domain-core-release-identity-report` mode before normal app startup. That
  mode calls the loaded Rust identity exports directly and hashes its own
  executable bytes. The verifier checks the reported digest against the same
  mounted executable, so no helper executable can substitute for the binary
  users receive.
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

Apple and Android use one combined publication manifest and one state machine:

1. retain the exact general release assets, release notes, notarized DMG, signed
   AAB, observed identities, protected gate, and rollback chain as Actions
   artifacts without mutating a GitHub release;
2. mount and reverify the final DMG, reverify the final AAB, and generate v2
   predicates against those exact local artifact bytes;
3. look up the exact tag and release state, then hydrate any evidence already
   present on a retry. Existing evidence is reused only after cryptographic
   verification against its exact predicate and artifact;
4. attest only missing evidence while the release is absent or draft;
5. create the release as a draft when absent, then upload every general asset,
   the DMG, the AAB, and every evidence bundle with create-only operations;
6. recheck the tag, target commit, metadata, draft state, and current asset-name
   subset before each mutation;
7. freshly download the complete asset set, compare every ordinary asset
   byte-for-byte, and cryptographically verify every evidence bundle; and
8. recheck the final tag, target, metadata, state, and exact asset-name set,
   then perform one explicit `--draft=false` edit with explicit prerelease and
   latest state.

Stable and prerelease releases use the same state machine. Prereleases are
always non-latest; only an explicitly promoted stable release may become latest.
Under the exclusive-writer boundary below, no partial release is published, and
no attestation is generated against bytes other than the DMG or AAB that will
be published.

GitHub does not expose a compare-and-swap operation for publishing a release.
The workflow therefore serializes release runs by the exact tag with
`cancel-in-progress: false`, and the release workflow is the exclusive trusted
contents writer for that tag while publication is in progress. A repository
administrator or manual API client can still race the final edit. The publisher
detects any metadata or asset-set change in its immediate post-publication
audit and makes a best-effort transition back to draft before failing, but a
concurrent privileged writer can cause transient exposure. Trusted consumers
must bind the expected signed manifest, exact asset names, and verified hashes;
they must not treat the mere existence of a published GitHub release as proof.

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

Published retries are strictly read-only. They succeed only when the complete
asset-name set is exact, every ordinary asset is byte-identical, every evidence
bundle verifies, and release metadata remains unchanged through the final
audit. A published release with a missing DMG, AAB, general asset, or evidence
bundle fails without mutation. Draft retries may fill only missing assets.
Concurrent exact uploads and a concurrent final publication are accepted after
fresh verification; substituted collisions, unexpected assets, moved tags,
state changes, or byte tampering fail closed and leave the release draft.

For recovery, rerun only failed jobs in the original workflow run. Every
producer exports the exact Actions artifact name it uploaded, so an attempt-2
publication consumer downloads the successful attempt-1 signed DMG, AAB,
identities, protected gate, and general asset set byte-for-byte. Starting a new
workflow dispatch rebuilds nondeterministic signed artifacts and is not a retry
of an existing partial draft; ordinary assets from that new run must still be
byte-identical or publication fails. Evidence bundles are the sole encoding
exception and are adopted only after cryptographic verification against the
exact predicate and native artifact.

The publisher never deletes a release, never replaces an asset, and never uses
`--clobber`. Windows retains its separate draft-then-publish state machine, with
the same create-only collision checks and final verification. An all-legacy
native profile still publishes the canonical artifact through the appropriate
state machine with an explicitly empty evidence bundle set.

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
The pre-integration seed list lives in
[`scripts/lib/domain-core-native-control-plane-seeds.mjs`](../../scripts/lib/domain-core-native-control-plane-seeds.mjs);
its tests require every directly executed native workflow helper and the full
recursive relative JavaScript import closure, so an imported verifier cannot
fall outside the protected set. The list also binds the shipped Apple reporter
source, Android native observer, signing policies, and native test observers.
After the release-workflow rebase, import it into the protected control-plane
verifier and regenerate the committed manifest from that exact tree.
