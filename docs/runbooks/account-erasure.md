# Account Erasure

Operational contract for the `deleteUserCloudData` callable and its
`account_erasure_audit/{sha256(uid)}` retention record.

## Safety Contract

Account erasure proceeds in this order:

1. Require the authenticated high-risk owner proof and atomically persist the schema-v2 receipt plus immutable canonical intent event.
2. Create `account_erasure_tombstones/{uid}`. Firestore rules, Storage rules, and the callable wrapper deny every operation except deletion recovery while this marker exists.
3. Revoke Firebase refresh tokens before enumerating any data.
4. Destroy hosted Secret Manager versions and delete the deterministic Cloud Storage prefixes.
5. Stop and retain a retryable manifest if any external artifact remains.
6. Delete the user/workspace trees and every UID-owned root record in the code registry.
7. Persist `cloud_data_deleted`, delete Firebase Auth, then atomically write the immutable completion event, terminal receipt, and completed tombstone state.

External cleanup is idempotent. Successful secret-reference documents are
deleted; failed references remain as the retry manifest. Storage prefixes are
deterministic, directory-delimited (`users/{uid}/` and `avatars/{uid}/`), and
attempted again on every retry. A nonterminal server-only
audit record authorizes recovery if a partial Firestore attempt removed its
trusted-device proof documents. `reconcileAccountErasures` retries pending
tombstones every 15 minutes in oldest-updated-first order, so recovery does not
depend on the user retaining a valid token after revocation. A transient failure
increments `reconciliationAttemptCount` and moves that tombstone to the back of
the queue. A pending tombstone without a schema-v2 nonterminal receipt is marked
`reconciliationStatus: quarantined` and removed from automatic selection while
the tombstone itself remains in place as the account write barrier. This keeps a
poison record from starving later privacy requests without weakening denial.

A malformed credential reference with no usable Secret Manager version remains
in place and blocks completion. Repair or investigate that server-only reference;
deleting it would discard the only retry evidence and could orphan a credential.

The callable never reports `success: true` while `retryRequired` is true or
before the terminal receipt is durable. It
returns `unavailable` with safe count/category details, and Auth remains active.

## Client Contract

The callable is authoritative for both cloud-data erasure and Firebase Auth
deletion. macOS, iOS, and Android clients must not call an SDK user-deletion API
after it returns. Before a successful response, clients preserve the local
session so the user can retry. After success, clients perform only local SDK and
UI sign-out cleanup; a local sign-out failure must not misreport an already
completed server erasure as failed.

## Audit Statuses

Schema version 2 uses these statuses:

| Status | Terminal | Meaning |
|---|---:|---|
| `intent_recorded` | No | Owner authorized erasure; cleanup may be retried. |
| `external_cleanup_incomplete` | No | Secret Manager or Cloud Storage cleanup failed. |
| `cloud_data_cleanup_failed` | No | A Firestore cleanup operation failed. |
| `cloud_data_deleted` | No | External and Firestore cleanup completed; Auth deletion still needs completion. |
| `auth_delete_failed` | No | Auth deletion failed and may be retried. |
| `session_revoke_failed` | No | Refresh-token revocation failed before cleanup; no data was enumerated. |
| `account_deleted` | Yes | Cloud data and Auth were deleted. |
| `auth_user_already_missing` | Yes | Cloud data was deleted and Auth was already absent. |

The retention record contains the UID hash, complete canonical intent and
completion events, their verifiable hash-chain head, cleanup counts/categories,
timestamps, and retry state. It must never contain a raw UID, Secret Manager
resource name, or Storage path. The tombstone document ID is necessarily the raw
Firebase UID because rules need an O(1) deny lookup; its body contains no profile
data or external resource identifiers. Completed tombstones remain as a durable
deny marker so an old token or accidentally reused identity cannot recreate data.

## Operator Recovery

1. Compute the retention document id without logging the UID:

   ```bash
   printf %s "$OPENBURNBAR_UID" | shasum -a 256
   ```

2. Inspect that document in `account_erasure_audit` and confirm its status is nonterminal.
3. Confirm the matching tombstone is `pending: true`; the scheduled reconciler should retry it within 15 minutes. An authenticated user may also retry **Delete account** without a second trusted-device approval. If `reconciliationStatus` is `quarantined`, validate or repair the schema-v2 receipt before restoring `pending: true`; never remove the tombstone barrier.
4. Confirm the receipt reaches `account_deleted` or `auth_user_already_missing`, `retryRequired` is false, both `events/intent` and `events/completion` verify against `retainedHeadHash`, and the tombstone is `pending: false`.
5. If repeated external cleanup fails, inspect structured `account_deletion_warning` events by `user_id_hash` (the first 12 hexadecimal characters of SHA-256(uid)). Do not log or copy raw object paths or secret names into tickets.

Do not manually delete Firebase Auth for a nonterminal record. Doing so removes
the authenticated retry identity before erasure proof is complete.

## Legacy Records

Schema version 1 status `cloud_data_deleted_with_secret_destroy_failures` is not
safe for automatic resume: the old implementation deleted secret-reference
documents even when Secret Manager destruction failed. Review those records
manually and prove the affected secret versions are destroyed before removing
Auth. All schema-version-1, malformed, and unknown receipts are rejected without
mutation. They are never upgraded automatically.

## Deploy and Rollback

- Deploy Firestore and Storage rules first, then Functions. Rules-first is safe
  while no tombstone exists; Functions-first would leave a write-race window.
- The audit and tombstone collections remain server-only. The reconciler query
  uses the composite `pending` + `updatedAt` index in `firestore.indexes.json`.
- Rolling back reintroduces best-effort Storage cleanup and is not privacy-safe after a version-2 intent. Prefer a forward fix.
- Focused verification: Functions build/typecheck, the account-deletion script, account-deletion audit/log tests, and the high-risk callable guard test.
