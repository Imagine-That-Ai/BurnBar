# Shared Rust Legacy Deletion

This runbook governs removal of duplicated platform implementations after a
shared-Rust row has completed promotion. It does not authorize promotion by
itself. Quantitative evidence, applicable crypto review, native artifact proof,
and stable-release observation remain required by the
[roadmap](../SHARED_RUST_DOMAIN_CORE_ROADMAP.md).

## Authoritative files

- Ledger: `config/domain-core-legacy-deletion.json`
- Schema: `config/domain-core-legacy-deletion.schema.json`
- Receipt schema: `config/domain-core-legacy-deletion-receipt.schema.json`
- Deletion plan schema: `config/domain-core-deletion-plan.schema.json`
- Qualified deletion reviewers: `config/domain-core-deletion-reviewers.json`
- Reviewer catalog schema: `config/domain-core-deletion-reviewers.schema.json`
- Release predicate schema: `config/domain-core-release-predicate.schema.json`
- Deployment receipt schema: `config/domain-core-deployment-receipt.schema.json`
- Promotion attestation schema: `config/domain-core-promotion-attestation.schema.json`
- Promotion report schema: `config/domain-core-promotion-report.schema.json`
- Gate: `scripts/ci/verify-domain-core-legacy-deletion.py`
- Receipt generator: `scripts/ops/create-domain-core-promotion-receipt.py`
- Deletion plan generator: `scripts/ops/create-domain-core-deletion-plan.py`
- Inventory: `docs/SHARED_RUST_DOMAIN_INVENTORY.md`

The gate recognizes exactly these row states:

| State | Required source state | Required active receipts |
|---|---|---|
| `rollout` | Every row target exists; authority generation is `0`; public mode is `legacy` | None; receipts are forbidden |
| `promotion_approved` | Every row target and rollback selector exists; the mapped public build-profile mode is `rust` | Generation-scoped `promotion` |
| `rust_authoritative_with_rollback` | Every row target and rollback selector exists; public mode remains `rust` | Same-generation `promotion`, `stableRelease` |
| `rollback_active` | Every row target and rollback selector exists; public mode is explicitly `legacy` | Same-generation `promotion`, `stableRelease`, `rollback`; a prior `deletionReview` remains attached if rollback followed deletion approval |
| `deletion_approved` | Every row target and rollback selector still exists; public mode remains `rust` | `promotion`, `stableRelease`, independently verified `deletionReview` |
| `legacy_deleted` | Every row target is absent; the mapped public build-profile mode remains `rust` | `promotion`, `stableRelease`, `deletionReview` |

Rows advance independently except when one public build-profile mode owns
multiple rows. Switching `quota`, `hermes`, or `pricing` to `rust` requires
every row mapped to that domain to have the same state, authority generation,
candidate commit, report digest, and core version; partial domain authority is
rejected. A selector used by multiple rows is a
`sharedTarget`, not a duplicated row target. It stays present until every member
row is `legacy_deleted`, preventing one deletion from silently removing another
row's rollback path.

The qualified reviewer catalog is intentionally empty in the initial landing.
No deletion approval can pass until a separate reviewed change names real
owners and independent crypto reviewers with their allowed review classes.
Keep reviewer objects sorted case-insensitively by handle, with each
`reviewClasses` array in `domain_owner`, `security_crypto` order. Duplicate
handles are forbidden even when their class arrays differ.

## Receipt contract

Receipts are committed JSON files referenced by repository-relative path from a
row. Their location is fixed as
`config/domain-core-legacy-deletion-receipts/<row-id>/<authority-generation>/<transition>.json`, so
receipt changes always trigger the domain-core workflow. Do not put runtime
telemetry or secrets in them. Every receipt has this exact shape:

```json
{
  "schemaVersion": 2,
  "rowId": "quota.claude_statusline",
  "authorityGeneration": 1,
  "transition": "promotion",
  "status": "active",
  "evidence": [
    "https://github.com/Imagine-That-Ai/BurnBar/pull/1234"
  ],
  "approvedBy": "@reviewer",
  "approvedAt": "2026-07-13T00:00:00Z",
  "commit": "0123456789abcdef0123456789abcdef01234567",
  "promotionAttestation": {
    "path": "config/domain-core-promotion-attestations/quota/1.json",
    "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "supersedesRollback": null
  }
}
```

`transition` is exactly `promotion`, `stable_release`, `rollback`, or
`deletion_review`. `commit` must be a real ancestor of the receipt checkout.
The committed attestation binds a fixed, committed aggregate readiness report,
its review URI and digest, the evaluated domain policy, canonical Rust source
fingerprint, semantic core version, authority scope, and candidate commit. The
trusted builder is a separate `main` commit cryptographically enforced as the
attestation signer and source digest. The signed report binds the candidate as
its query revision and retains absolute observation start/end timestamps. The
gate independently revalidates exact coverage, the pinned 14-day window,
10,000-sample floor, zero unexplained mismatches, and maximum 5% p95 regression.
Stable release binds the promotion receipt digest, the historical public Rust
profile, and artifact plus signed-provenance digests for every applicable consumer.
Each entry also has a fixed artifact kind, target, asset name, signer workflow,
predicate type, tag, and commit. The verified custom predicate must repeat the
exact consumer, artifact class, target, filename, artifact digest, version, tag,
release commit, and public-profile digest; a macOS artifact cannot satisfy
Android or any other consumer.
Rollback and deletion each bind the stable receipt digest. Evidence must be a unique,
non-empty list of credential-free HTTPS URLs without query strings or
fragments. `approvedBy` is a GitHub handle, `approvedAt` is a non-future UTC
timestamp, and `status` must be `active`.

Receipt, attestation, aggregate-report, provenance, and deletion-plan paths
cannot be symlinks or escape the repository. Every artifact present at the trusted PR or push base must stay
byte-identical. History is append-only: artifacts cannot be reused, rewritten,
deleted, or renamed.

## Advance to Rust authority

1. Generate the quantitative promotion report from retained evidence. Do not
   hand-edit it.
2. Complete every non-quantitative roadmap gate, including independent security
   review for crypto rows.
3. Generate the committed report, attestation, and promotion receipt:

```bash
python3 scripts/ops/create-domain-core-promotion-receipt.py \
  --row-id quota.claude_statusline \
  --authority-generation 1 \
  --report /absolute/path/to/promotion-readiness.json \
  --report-provenance /absolute/path/to/domain-core-promotion-report.sigstore.json \
  --report-uri https://github.com/Imagine-That-Ai/BurnBar/actions/runs/1234 \
  --candidate-commit "$CANDIDATE_SHA" \
  --builder-commit "$TRUSTED_MAIN_BUILDER_SHA" \
  --approved-by @reviewer \
  --approved-at 2026-07-13T00:00:00Z
```

4. Commit the generated artifacts, change every row mapped to the reviewed
   public profile domain to `promotion_approved`, and change that profile mode
   to `rust` in the same reviewable change. This is the only state that can
   authorize the first fail-closed Rust-authoritative build without claiming a
   stable release that does not exist yet.
5. Ship the candidate while retaining the explicit legacy rollback selector.
6. Observe one stable released build for every applicable consumer. Each
   consumer entry binds its tag, commit, version, artifact digest, and signed
   provenance digest. Windows uses `windows-vX.Y.Z`; the other release trains
   use `vX.Y.Z`.
   Functions can publish `OpenBurnBar-<version>-functions-deployment.json` once
   the public pricing profile selects Rust, and only after the exact stable tag
   deploy and production health gate succeed. The deploy workflow dispatches
   `domain-core-functions-release-evidence.yml`, so waiting for the matching
   GitHub Release never holds the production Functions deploy lock. Its
   custom GitHub attestation binds the pricing Rust profile, artifact digest,
   tag, and commit; reruns verify existing release assets byte-for-byte and
   never overwrite them. Apple, Android, Windows, and Console still do not publish
   every canonical asset and exact custom attestation required by this
   contract. Do not create a stable receipt from an Actions artifact or
   unsigned deployment summary.
7. Commit active `stable_release` receipts and advance the observed rows to
   `rust_authoritative_with_rollback`. The stable receipt must identify the
   actually published release commit and hash the promotion receipt and public
   Rust profile it observed.
8. Run the source gate. It must prove that all legacy targets and shared
   rollback selectors still exist:

```bash
python3 tests/test_domain_core_legacy_deletion_gate.py
python3 tests/test_domain_core_legacy_deletion_workflow.py
GH_TOKEN="$(gh auth token)" python3 scripts/ci/verify-domain-core-legacy-deletion.py \
  --base-ref "$BASE_SHA" \
  --verify-signed-evidence
```

If a mismatch, ABI/artifact failure, security regression, or unacceptable
latency appears, explicitly restore `legacy`, add a same-generation `rollback`
receipt, and move every affected row to `rollback_active`. Never delete or
rewrite the rollback receipt. Rust restoration increments the authority
generation and requires a new ready promotion report whose receipt hashes the
previous generation's rollback receipt. The new generation must then observe a
new stable Rust release before deletion is possible. The gate rejects reuse of
any pre-rollback stable receipt.

## Approve and delete a row

Deletion requires two reviewable changes after the authoritative release has
been observed. A stable row cannot move directly to `legacy_deleted`.

1. Confirm the row is already `rust_authoritative_with_rollback` with active,
   same-generation promotion and stable-release receipts. It must not be in
   `rollback_active`, and its generation must be newer than every rollback in
   the append-only receipt history.
2. The proposed reviewer must already be qualified for the row's review class
   in `config/domain-core-deletion-reviewers.json` at the trusted base commit.
   Add or change reviewer qualifications in a separate earlier PR; the deletion
   PR cannot authorize its own reviewer. Generate the immutable plan, then
   commit it to a dedicated review PR whose tree already contains the active
   stable receipt:

```bash
python3 scripts/ops/create-domain-core-deletion-plan.py \
  --row-id cloudvault.search \
  --authority-generation 1 \
  --reviewer @reviewer
```

   For quota, Hermes, and pricing, generate one plan per mapped row in the same
   PR. Their plans, receipts, state, generation, and public profile must advance
   atomically.
3. Obtain GitHub approval on that exact PR head. The reviewer must not be the
   PR author, and their latest decisive review on that commit must remain
   `APPROVED`. Crypto rows require a reviewer qualified for `security_crypto`;
   other rows require `domain_owner`. The gate downloads the plan and stable receipt
   from the reviewed PR head and verifies both byte digests, so an unrelated
   approved PR cannot authorize deletion.
   Record the approved head SHA, merge this plan PR without changing that head,
   update local `main`, and create a new receipt branch from the merged result.
   Do not add the receipt to the still-open plan PR: pushing it changes the PR
   head and invalidates the approval.
4. Generate the deletion-review receipt. This rechecks the live PR approval and
   reviewed file bytes before writing the append-only receipt:

```bash
python3 scripts/ops/create-domain-core-deletion-plan.py \
  --row-id cloudvault.search \
  --authority-generation 1 \
  --reviewer @reviewer \
  --review-uri https://github.com/Imagine-That-Ai/BurnBar/pull/1234 \
  --reviewed-commit "$REVIEWED_HEAD_SHA" \
  --approved-by @release-owner \
  --approved-at 2026-07-14T00:00:00Z
```

   Commit the receipt that binds the reviewed PR head, declared
   reviewer, review class, plan path and digest, stable receipt, and approved
   outcome. Advance the row only to `deletion_approved`. All legacy targets
   must still exist in this change.
5. If a regression appears after approval, retain the immutable deletion
   review, add the rollback receipt, restore the whole mapped profile to
   `legacy`, and move it to `rollback_active`.
6. In a later PR, remove every exact row target from the ledger's declared source paths. Do not
   remove platform-owned I/O, persistence, key custody, orchestration, or UI.
7. Remove a shared rollback selector only when every member row is being marked
   `legacy_deleted` in the same change or was already deleted.
8. Reuse the immutable deletion-review receipt and change the row from
   `deletion_approved` to `legacy_deleted`.
9. Run the focused source tests, the affected platform compile/contracts, and
   the full domain-core workflow. The source gate must prove the named symbols,
   files, and mode literals are absent.
10. Update the inventory table and changelog in the same change.

Signed-evidence verification requires authenticated `gh` network access. CI
sets `GH_TOKEN` from the pull-request token with `pull-requests: read`; local
runs must use an authenticated `gh` session.

The gate intentionally fails if a target disappears while the row is still in
rollout, if a deleted row retains any target, if a source root goes missing, or
if a manifest edit attempts to rename/drop a stable row. Update target paths
only in the same reviewed refactor that preserves their presence; never use a
ledger edit to make an early deletion pass.
