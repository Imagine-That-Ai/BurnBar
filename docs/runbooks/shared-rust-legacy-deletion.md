# Shared Rust legacy deletion

Legacy implementations are removed row by row only after deterministic promotion, an exact-candidate stable release, retained rollback, and independent review. Shadow telemetry is diagnostic. It never authorizes promotion or deletion.

## Governed inventory

[`config/domain-core-legacy-deletion.json`](../../config/domain-core-legacy-deletion.json) is the exact 11-row source ledger. Each target is either a legacy implementation or a rollback control. Public-profile groups (`quota`, `hermes`, and `pricing`) move atomically.

The six states are:

1. `rollout`: legacy is authoritative and no receipt exists.
2. `promotion_approved`: the protected deterministic proof authorizes the exact Rust candidate.
3. `rust_authoritative_with_rollback`: one stable public release of that exact candidate exists and rollback remains available.
4. `deletion_approved`: a qualified independent reviewer approved deleting the exact inventoried targets.
5. `rollback_active`: the stable release was rolled back; legacy remains and the generation is closed.
6. `legacy_deleted`: approved targets are absent and Rust-only platform builds remain green.

Rows never skip states. A rollback closes the current authority generation. Re-promotion starts the next generation and its promotion receipt must hash the previous rollback receipt.

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

Deletion requires one stable public release of the exact attested candidate, not a descendant with similar Rust sources. Every applicable consumer release predicate must bind the same four-field candidate identity and exact public Rust profile.

The stable-release receipt must also bind a dedicated `legacy-rollback-bundle`:

- built and tagged from the exact candidate commit;
- separately hashed and covered by official release-workflow provenance;
- targeted to all supported consumers;
- retained under `retain_until_legacy_deletion_complete`;
- listed in stable-release evidence and stored with append-only provenance.

This is different from the deterministic rollback drill. The drill proves the selector and retained legacy artifact work before promotion. The stable-release artifact preserves the actual rollback payload after release.

An operational rollback creates `rollback.json`, restores the public profile to legacy, and closes that authority generation. It never reuses the old promotion proof.

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
   `legacy_deleted`, and pass the source-absence and Rust-only compile gates.

The gate requires the reviewed plan commit to be an ancestor of the receipt
commit and the review PR to retain that exact reviewed head.

## Deletion gate

Run locally:

```bash
python3 tests/test_domain_core_legacy_deletion_gate.py
python3 tests/test_domain_core_legacy_deletion_workflow.py
python3 scripts/ci/verify-domain-core-legacy-deletion.py
```

CI additionally supplies the trusted base SHA and `--verify-signed-evidence`. The gate fails closed on:

- changed or removed append-only generations, receipts, bundles, or provenance;
- missing or unexpected rows and targets;
- non-atomic public-profile transitions;
- invalid promotion provenance or candidate identity;
- a release not tagged at the exact candidate;
- missing consumer evidence or retained signed rollback artifact;
- an unqualified, stale, self-authored, or mismatched deletion review;
- target absence before `legacy_deleted` or target presence afterward.

The normal domain-core jobs then compile and load the Rust core across Apple, Android, Windows, browser, Functions, and native test surfaces. Once a row reaches `legacy_deleted`, the source-absence gate plus those required jobs form the Rust-only compile gate.

## Recovery

Do not edit old receipts. If evidence is wrong, leave the generation intact, activate rollback, fix the issue, and start a new authority generation. If a supposedly retained rollback artifact is unavailable or fails provenance verification, deletion is blocked.
