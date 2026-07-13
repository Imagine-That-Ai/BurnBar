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
- Gate: `scripts/ci/verify-domain-core-legacy-deletion.py`
- Inventory: `docs/SHARED_RUST_DOMAIN_INVENTORY.md`

The gate recognizes exactly these row states:

| State | Required source state | Required active receipts |
|---|---|---|
| `rollout` | Every row target exists | None; receipts are forbidden |
| `rust_authoritative_with_rollback` | Every row target and rollback selector exists | `promotion`, `stableRelease` |
| `legacy_deleted` | Every row target is absent | `promotion`, `stableRelease`, `deletionReview` |

Rows advance independently. A selector used by multiple rows is a
`sharedTarget`, not a duplicated row target. It stays present until every member
row is `legacy_deleted`, preventing one deletion from silently removing another
row's rollback path.

## Receipt contract

Receipts are committed JSON files referenced by repository-relative path from a
row. Their location is fixed as
`config/domain-core-legacy-deletion-receipts/<row-id>/<transition>.json`, so
receipt changes always trigger the domain-core workflow. Do not put runtime
telemetry or secrets in them. Every receipt has this exact shape:

```json
{
  "schemaVersion": 1,
  "rowId": "quota.claude_statusline",
  "transition": "promotion",
  "status": "active",
  "evidence": [
    "https://github.com/Imagine-That-Ai/BurnBar/pull/1234"
  ],
  "approvedBy": "@reviewer",
  "approvedAt": "2026-07-13T00:00:00Z",
  "commit": "0123456789abcdef0123456789abcdef01234567"
}
```

`transition` is exactly `promotion`, `stable_release`, or `deletion_review`.
`commit` is the full lowercase SHA whose rollout/release state was reviewed; it
is not required to be the receipt commit itself. Evidence must be a unique,
non-empty list of credential-free HTTPS URLs without query strings or
fragments. `approvedBy` is a GitHub handle, `approvedAt` is a non-future UTC
timestamp, and `status` must be `active`. Revoking a receipt means committing a
status change; the row must simultaneously move back to a state whose receipt
requirements are satisfied.

Receipt paths, like source targets, cannot be symlinks and cannot escape the
repository. A receipt cannot be reused by two transitions or rows.

## Advance to Rust authority

1. Generate the quantitative promotion report from retained evidence. Do not
   hand-edit it.
2. Complete every non-quantitative roadmap gate, including independent security
   review for crypto rows.
3. Change the consumer to fail-closed Rust authority while retaining the
   explicit legacy rollback selector.
4. Observe one stable released build for every applicable consumer.
5. Commit active `promotion` and `stable_release` receipts and change only that
   row to `rust_authoritative_with_rollback`.
6. Run the source gate. It must prove that all legacy targets and shared
   rollback selectors still exist:

```bash
python3 tests/test_domain_core_legacy_deletion_gate.py
python3 tests/test_domain_core_legacy_deletion_workflow.py
python3 scripts/ci/verify-domain-core-legacy-deletion.py
```

If a mismatch, ABI/artifact failure, security regression, or unacceptable
latency appears, explicitly restore `legacy`, preserve the evidence, revoke the
affected receipt, and restart the applicable observation window after repair.

## Delete a row

Deletion is a separate reviewable change after the authoritative release has
been observed:

1. Confirm the row is already `rust_authoritative_with_rollback` with active
   promotion and stable-release receipts.
2. Remove every exact row target from the ledger's declared source paths. Do not
   remove platform-owned I/O, persistence, key custody, orchestration, or UI.
3. Remove a shared rollback selector only when every member row is being marked
   `legacy_deleted` in the same change or was already deleted.
4. Add an active `deletion_review` receipt linked to the independent review
   record, then change the row to `legacy_deleted`.
5. Run the focused source tests, the affected platform compile/contracts, and
   the full domain-core workflow. The source gate must prove the named symbols,
   files, and mode literals are absent.
6. Update the inventory table and changelog in the same change.

The gate intentionally fails if a target disappears while the row is still in
rollout, if a deleted row retains any target, if a source root goes missing, or
if a manifest edit attempts to rename/drop a stable row. Update target paths
only in the same reviewed refactor that preserves their presence; never use a
ledger edit to make an early deletion pass.
