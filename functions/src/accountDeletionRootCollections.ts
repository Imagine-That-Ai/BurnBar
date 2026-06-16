/**
 * @fileoverview Single source of truth for ROOT (non-`users/{uid}`) Firestore
 * collections that carry per-document `uid` ownership.
 *
 * Each such collection escapes the `users/{uid}` subtree walk during account
 * erase, so GDPR Art.17 requires it to be either explicitly deleted
 * (`disposition: "delete"`) or consciously exempted (`disposition: "exempt"`)
 * with a documented reason. The companion test
 * `accountDeletionRootCollectionCoverage.test.ts` scans the codebase for
 * `.collection("X").where("uid", ...)` writes/reads and FAILS CI if any
 * discovered root uid-keyed collection is missing from this manifest — so a
 * newly-added collection cannot silently escape erasure (mirrors the BOLA
 * catalog-completeness pattern).
 */

export type RootCollectionDisposition = "delete" | "exempt";

export interface RootCollectionUidDeletionEntry {
  /** The root collection id (the literal passed to `db.collection(...)`). */
  readonly collection: string;
  readonly disposition: RootCollectionDisposition;
  /**
   * For `delete` entries, how the documents are purged:
   *  - `rootSweep`   : the generic uid-scoped sweep in `eraseUserCloudData`.
   *  - `secretDestroy`: purged alongside its Secret Manager versions.
   */
  readonly handledBy?: "rootSweep" | "secretDestroy";
  readonly reason: string;
}

export const ROOT_COLLECTION_UID_DELETION_MANIFEST: readonly RootCollectionUidDeletionEntry[] = [
  {
    collection: "voip_outbound",
    disposition: "delete",
    handledBy: "rootSweep",
    reason:
      "VoIP push fan-out queue keyed by owner uid; carries caller name + live push tokens (F-RR09-001). TTL-bounded, but a deletion request must purge it immediately.",
  },
  {
    collection: "fcm_outbound",
    disposition: "delete",
    handledBy: "rootSweep",
    reason:
      "FCM push fan-out queue keyed by owner uid; carries device id + push payload metadata. TTL-bounded, but a deletion request must purge it immediately.",
  },
  {
    collection: "provider_account_secret_refs",
    disposition: "delete",
    handledBy: "secretDestroy",
    reason:
      "Secret Manager reference docs keyed by uid; purged by destroyProviderSecrets() (which also destroys the underlying secret versions) earlier in eraseUserCloudData.",
  },
];

/**
 * Root collections purged by the generic uid-scoped sweep in `eraseUserCloudData`.
 * Derived from the manifest so the sweep and the audited inventory can never drift.
 */
export const ROOT_COLLECTIONS_KEYED_BY_UID: readonly string[] = ROOT_COLLECTION_UID_DELETION_MANIFEST
  .filter((entry) => entry.disposition === "delete" && entry.handledBy === "rootSweep")
  .map((entry) => entry.collection);
