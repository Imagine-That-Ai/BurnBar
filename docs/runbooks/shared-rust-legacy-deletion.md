# Shared Rust legacy deletion

Legacy implementations are removed row by row only after deterministic promotion, a path-restricted activation commit, a candidate-bound stable release, retained rollback, and independent review. Shadow telemetry is diagnostic. It never authorizes promotion or deletion.

## Governed inventory

[`config/domain-core-legacy-deletion.json`](../../config/domain-core-legacy-deletion.json) is the exact 11-row source ledger. Each target is either a legacy implementation or a rollback control. Public-profile groups (`quota`, `hermes`, and `pricing`) move atomically.

The seven states are:

1. `rollout`: legacy is authoritative and no receipt exists.
2. `promotion_approved`: the protected deterministic proof authorizes the exact Rust candidate.
3. `activation_annulled`: activation reached `main`, but the release train advanced before any stable receipt or release tag existed; legacy is restored and that generation is closed.
4. `rust_authoritative_with_rollback`: one stable public release of that exact candidate exists and rollback remains available.
5. `deletion_approved`: a qualified independent reviewer approved deleting the exact inventoried targets.
6. `rollback_active`: the stable release was rolled back; legacy remains and the generation is closed.
7. `legacy_deleted`: approved targets are absent and Rust-only platform builds remain green.

Rows never skip states. Every release that activates another shared domain starts a new authority epoch for domains that are already Rust-authoritative. Those rows move back to `promotion_approved`, advance their generation, and re-attest the new candidate closure before the activation commit can ship. The new promotion receipt hashes the previous active `stable_release.json`; after an operational rollback it hashes `rollback.json`; after an unshipped activation is annulled it hashes `annulment.json`. This keeps all Rust-active domains on one candidate identity without deleting or rewriting prior authority.

## Promotion authority

The only promotion authority is an official GitHub provenance attestation over the unsigned deterministic candidate bundle created by [`.github/workflows/domain-core.yml`](../../.github/workflows/domain-core.yml) and signed by [`.github/workflows/domain-core-promotion-proof.yml`](../../.github/workflows/domain-core-promotion-proof.yml) behind the protected `domain-core-promotion` environment.

The committed promotion chain binds:

- exact `candidateCommit`, `coreVersion`, `abiVersion`, and `sourceSha256`;
- exact successful `push` run id and attempt for `domain-core.yml` on `main`;
- exact protected signer run id and attempt;
- trusted-main commit plus SHA-256 digests of the promotion policy and deterministic evaluator at that commit;
- unsigned candidate bundle bytes and official Sigstore/GitHub provenance bundle bytes;
- the authority row, scope, generation, approval actor, and timestamps.

The unsigned bundle must say `promotionAuthorized: false` and require the protected signer. The following are rejected as authority:

- shadow samples, telemetry exports, observation windows, or sample counts;
- hand-written readiness reports;
- an unsigned deterministic bundle by itself;
- `protected-verification.json`, which is diagnostic signer output;
- a provenance bundle from another workflow, repository, ref, commit, run, or attempt.

### Protected governance credential

The signer must re-read the live `main` branch-protection policy after the
required environment review. GitHub's ordinary `GITHUB_TOKEN` cannot read the
repository Administration API, so the `domain-core-promotion` environment must
define the environment-scoped secret
`DOMAIN_CORE_GOVERNANCE_READ_TOKEN`. Use a fine-grained personal access token or
GitHub App installation token restricted to this repository with only
**Administration: read** (plus GitHub's implicit Metadata read). Do not grant
contents write.

Configure the secret under **Settings → Environments →
`domain-core-promotion` → Environment secrets**. The signer fails before
attestation when the secret is absent, expired, or lacks access. Only the
trusted-main branch-control verifier receives this token; candidate discovery,
artifact download, and attestation continue to use the job-scoped
`GITHUB_TOKEN`.

Create a promotion receipt only after downloading the exact candidate bundle and official provenance bundle:

```bash
python3 scripts/ops/create-domain-core-promotion-receipt.py \
  --row-id quota.claude_statusline \
  --authority-generation 1 \
  --bundle /secure/download/domain-core-candidate-bundle.json \
  --provenance-bundle /secure/download/attestation.sigstore.json \
  --candidate-commit <40-char-candidate-sha> \
  --trusted-main-commit <40-char-signer-head-sha> \
  --source-run-id <domain-core-run-id> \
  --source-run-attempt <domain-core-run-attempt> \
  --signer-run-id <promotion-proof-run-id> \
  --signer-run-attempt <promotion-proof-run-attempt> \
  --attestation-uri https://github.com/Imagine-That-Ai/BurnBar/attestations/<id> \
  --attested-at 2026-07-15T01:00:00Z \
  --approved-by @release-owner \
  --approved-at 2026-07-15T02:00:00Z
```

The creator verifies GitHub provenance and writes append-only artifacts under:

- `config/domain-core-promotion-bundles/<scope>/<generation>.json`
- `config/domain-core-promotion-provenance/<scope>/<generation>.json`
- `config/domain-core-promotion-attestations/<scope>/<generation>.json`
- `config/domain-core-legacy-deletion-receipts/<row>/<generation>/promotion.json`

## Stable release and rollback

Promotion uses two commits so the authority chain is not circular:

1. Candidate `C` contains the complete Rust source with the public profile still on legacy. A successful `domain-core.yml` push run and the protected signer attest `C`.
2. Activation `P` is a descendant of `C`. It adds the promotion receipts, switches the public profile to Rust, and refreshes the trusted control-plane manifest for those exact profile bytes. The `C..P` diff may contain only the build-profile catalog, control-plane manifest, deletion ledger, append-only promotion authority artifacts, and these shared-Rust runbooks. It must not change the core version, ABI, source fingerprint, Rust source, or consumer code.
3. Stable artifacts are built and tagged at `P`, embed the candidate identity from `C`, and include the SHA-256 of the restricted `C..P` path set.

Before attesting `C`, serialize the release train: record and temporarily dequeue unrelated `main` merge-queue entries, merge the candidate, and keep the queue clear until activation `P` completes. If the unrelated queue has already drained naturally, record that empty state and do not invent a dequeue/re-enqueue cycle. Re-enqueue any recorded pull requests in their original order after `P` lands. This preserves every required check; it prevents unrelated commits from entering the restricted `C..P` path set. If `main` advances after `C`, abandon that attestation and produce a new exact-main candidate rather than allowlisting incidental paths. The replacement candidate must modify a governed `domain-core.yml` push path so GitHub produces a fresh authoritative push run; a manual dispatch or empty commit is diagnostic only and cannot replace that proof.

If `P` reaches `main` but unrelated commits land before any stable receipt or stable release tag exists, do not delete promotion evidence and do not pretend an operational rollback occurred. Create append-only `annulment.json` receipts, move the affected rows to `activation_annulled`, and restore the public profile to legacy in one commit. The annulment gate requires the exact old candidate and activation closure, the promotion receipt digest, an incidental `main` advance outside the activation path set, no stable/rollback/deletion receipt, no stable tag at `P`, and an explicit replacement-candidate requirement:

```bash
python3 scripts/ops/create-domain-core-activation-annulment-receipt.py \
  --row-id quota.claude_statusline \
  --authority-generation 1 \
  --activation-commit <40-char-stale-activation-sha> \
  --advanced-main-commit <40-char-main-sha-after-incidental-merges> \
  --evidence https://github.com/Imagine-That-Ai/BurnBar/pull/<annulment-pr> \
  --approved-by @release-owner \
  --approved-at <past-or-current-rfc3339-utc>
```

The merged annulment commit is the new legacy-safe candidate `C2` only after its authoritative `domain-core.yml` push run succeeds and the protected signer attests it. Activation `P2` then advances the rows to the next generation, adds fresh promotion artifacts whose `supersedes` pointer hashes `annulment.json`, and switches the public profile back to Rust. Keep the release train frozen from `C2` through the stable tag at `P2`.

Every applicable consumer release predicate must bind the same candidate `C`, activation `P`, exact Rust closure, and exact public Rust profile. Apple, Linux, Android, Windows, Console, and Functions are covered where the governed row applies. iOS is additionally required for the five mobile runtime rows: CloudVault portable primitives, document rewrap, encrypted search, Hermes relay crypto, and Hermes ratchet transforms; it is not a quota-parser or pricing-arithmetic consumer.

The stable-release receipt must also bind a dedicated `legacy-rollback-bundle`:

- built and tagged from activation `P` while binding candidate `C`;
- separately hashed and covered by official release-workflow provenance;
- targeted to all supported consumers;
- contains a full `git archive` of candidate `C`, the exact signed all-legacy profile, a portable `rollback.env` with every domain mode set to `legacy`, and exact embedded rollback-settings plus provenance bytes for Apple, iOS, Linux, Android, Windows, Console, and Functions;
- verifies the retained source archive's Git PAX commit header is exactly `C`,
  its top-level prefix matches the app release, every entry is a regular file
  or directory, and its embedded shared-Rust source recomputes to the candidate
  union fingerprint; the retained bytes must also exactly equal a freshly
  regenerated, complete `git archive` of candidate `C`;
- rejects missing, encrypted, linked, path-traversing, or digest-mismatched restoration material during stable-receipt verification;
- retained under `retain_until_legacy_deletion_complete`;
- listed in stable-release evidence and stored with append-only provenance.

This is different from the deterministic rollback drill. The drill proves the selector and retained legacy artifact work before promotion. The stable-release artifact preserves the actual rollback payload after release.

An operational rollback creates `rollback.json`, restores the public profile to legacy, and closes that authority generation. It never reuses the old promotion proof. A later release epoch also never reuses an old proof: already-Rust rows receive a fresh promotion and stable receipt for the new candidate, while a newly activated row is promoted from a candidate that still has that row in legacy mode.

Use the append-only writers rather than hand-authoring lifecycle receipts:

```bash
python3 scripts/ops/create-domain-core-activation-annulment-receipt.py --help
python3 scripts/ops/create-domain-core-stable-receipt.py --help
python3 scripts/ops/create-domain-core-rollback-receipt.py --help
```

## Deletion review

Generate the immutable plan after the exact stable receipt exists:

```bash
python3 scripts/ops/create-domain-core-deletion-plan.py \
  --row-id cloudvault.portable_primitives \
  --authority-generation 1 \
  --reviewer @qualified-reviewer
```

The plan hashes the stable receipt and exact target inventory. Crypto-sensitive CloudVault and Hermes rows require a reviewer in the `security_crypto` class. Other rows require `domain_owner`. The reviewer must be independent, approve the exact PR head, and remain the latest decisive review.

Use three reviewable commits/PRs so approval cannot be invalidated by a circular
receipt dependency:

1. Merge a review-only PR containing the immutable plan. The qualified reviewer
   approves that exact head; it does not delete source.
2. From a descendant of that merged head, rerun the command with `--review-uri`,
   `--reviewed-commit`, `--approved-by`, and `--approved-at` to create the
   append-only deletion-review receipt and move the row to
   `deletion_approved`.
3. In a separate deletion PR, remove only the approved targets, move the row to
   `legacy_deleted`, and pass its current PR number and exact head SHA to the
   trusted deletion gate. The same qualified reviewer must approve that exact
   current deletion head.

The gate requires the reviewed plan commit to be an ancestor of the receipt
commit and the review PR to retain that exact reviewed head.

## Deletion gate

Run locally:

```bash
python3 tests/test_domain_core_legacy_deletion_gate.py
python3 tests/test_domain_core_legacy_deletion_workflow.py
python3 scripts/ci/verify-domain-core-legacy-deletion.py
```

The `pull_request_target`-based `Domain Core Trusted Deletion Guard` comes from the default branch, checks out candidate bytes as data only, and runs only the default branch's committed evaluator. CI also supplies the trusted base SHA, `--verify-signed-evidence`, and actual deletion PR/head coordinates. This always-running trusted guard must be required on official `main`. The path-scoped `Domain Core PR Gate` additionally requires every meaningful domain-core matrix and proof job to succeed when governed paths change; it is not a classic global required context because it intentionally does not emit for unrelated PRs. Required native, Android, and Windows aggregate checks provide the remaining compile gates. The trusted deletion guard fails closed on:

- changed or removed append-only generations, receipts, bundles, or provenance;
- missing or unexpected rows and targets;
- non-atomic public-profile transitions;
- invalid promotion provenance or candidate identity;
- a release not tagged at activation `P`, or a `C..P` diff outside the restricted authority paths;
- missing consumer evidence or retained signed rollback artifact;
- an unqualified, stale, self-authored, or mismatched deletion review;
- target absence before `legacy_deleted` or target presence afterward;
- a deletion PR that comes from a fork or lacks qualified approval on its exact current head;
- a merge-queue evaluation whose base ref is anything other than `refs/heads/main`.

Internal same-repo PRs that target a branch other than official `main` (stacked PRs) are the one deliberate exception: the guard emits an explicit neutral pass without evaluating. The `pull_request_target` "trusted" checkout for such a PR is the unreviewed base branch, not default-branch code, so evaluating there proves nothing. Enforcement is unchanged at the boundary that matters: the base branch's own PR into `main` and the merge queue evaluate the full accumulated diff with genuinely trusted default-branch code. The same-repo base and head repository assertions run before the neutral pass, so fork PRs gain nothing from it.

The source-absence gate scans the whole declared source root for deleted symbols and literals, rejects deleted paths still referenced by tracked build graphs, and verifies exact identity receipts against the final XCFramework, AAR, native Windows and Linux binaries, browser WASM, Node WASM, and C# native artifact. Symbol-only absence is not sufficient.

### Two-release completion sequence

Do not collapse deletion authorization and post-deletion release completion into
one circular gate:

1. Stable release **A** is Rust-authoritative, still contains the reviewed
   legacy fallback, and retains the signed seven-consumer rollback bundle. Its
   candidate/activation evidence authorizes the deletion PR.
2. The deletion PR proves source, build-graph, primitive, and consumer-library
   absence against release A's authority. It does not claim that post-merge
   stores or deployments already contain the deletion.
3. Stable release **B** is built from the merged deletion. The normal Apple,
   iOS, Android, Windows, Linux, Console, and Functions release/deploy evidence
   creator adds a signed `legacyAbsence` block to each exact final-artifact
   predicate. iOS additionally binds and stages the exact processed IPA bytes.
4. The protected `Domain Core Post-Deletion Completion` workflow aggregates
   the seven release-B surfaces, requires one candidate/activation/version and
   exact 11-row coverage, then signs the completion receipt. Until that receipt
   exists, source deletion may be merged but the structural program is not
   operationally complete.

The release-B aggregator is
[`verify-domain-core-final-absence-receipts.py`](../../scripts/ci/verify-domain-core-final-absence-receipts.py).
It rejects intermediate XCFramework/AAR/DLL/Wasm evidence as a substitute for
the final DMG, processed IPA, AAB, Windows/Linux bundles, or Console/Functions
deployment receipts.

The iOS stable predicate is created only after App Store Connect accepts the exact IPA and reports completed processing. Its receipt binds the archive digest, IPA digest, and shipped executable digest. The executable verifier reads candidate commit, core version, ABI, and source fingerprint from the dedicated `__TEXT,__obb_core_id` Mach-O section and also requires the three linked UniFFI identity symbols; unrelated strings in the app cannot satisfy this proof.

The protected signer and trusted deletion guard audit the live default-branch protection settings without mutating them. Official `main` must require strict `Domain Core Trusted Deletion Guard`, native, Android, and Windows aggregate checks, admin enforcement, one current independent approval, stale-approval dismissal, and disabled force-pushes/deletions. The path-scoped `Domain Core PR Gate` remains additional evidence on governed changes without deadlocking unrelated PRs. Signed release artifacts are cached by immutable SHA-256 under runner-temporary storage during a gate run; attestations are separately deduplicated by their complete verification key.

The live protection query cannot eliminate GitHub administrator time-of-check/time-of-use risk by itself. Branch protection and the required checks remain the final merge-time authority: an administrator who changes those controls after the query can bypass repository policy, and that administrative action must be handled through GitHub audit-log monitoring and incident response.

## Recovery

Do not edit old receipts. If evidence is wrong, leave the generation intact, activate rollback, fix the issue, and start a new authority generation. If a supposedly retained rollback artifact is unavailable or fails provenance verification, deletion is blocked.
