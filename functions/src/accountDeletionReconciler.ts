/** Durable reconciliation for erasures interrupted after the write barrier. */

import { onSchedule } from "firebase-functions/v2/scheduler";

import { auth, db } from "./adminRuntime.js";
import { eraseUserAccount, isAccountErasureResumable } from "./accountDeletion.js";
import { logError, logInfo } from "./logging.js";
import { FUNCTIONS_REGION } from "./runtimeOptions.js";
import { destroyCredential } from "./secrets.js";

const RECONCILE_BATCH_LIMIT = 5;

interface PendingErasureTombstone {
  readonly id: string;
  get(field: string): unknown;
  readonly ref: {
    set(data: Record<string, unknown>, options: { merge: true }): Promise<unknown>;
  };
}

interface AccountErasureReconcileDependencies {
  isResumable(uid: string): Promise<boolean>;
  erase(uid: string): Promise<unknown>;
  now(): Date;
}

interface AccountErasureReconcileResult {
  uid: string;
  status: "completed" | "failed" | "quarantined";
  errorCode?: string;
}

function errorCode(reason: unknown): string {
  if (reason && typeof reason === "object" && "code" in reason && typeof reason.code === "string") {
    return reason.code;
  }
  return reason instanceof Error ? reason.name : "unknown";
}

function incompleteEraseCode(result: unknown): string | undefined {
  if (result == null || typeof result !== "object") return undefined;
  return Reflect.get(result, "cloudDataDeleted") === false || Reflect.get(result, "retryRequired") === true
    ? "external_cleanup_incomplete"
    : undefined;
}

function priorAttemptCount(document: PendingErasureTombstone): number {
  const value = document.get("reconciliationAttemptCount");
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0 ? value : 0;
}

export async function reconcilePendingAccountErasures(
  documents: readonly PendingErasureTombstone[],
  dependencies: AccountErasureReconcileDependencies,
): Promise<AccountErasureReconcileResult[]> {
  return Promise.all(
    documents.map(async (document) => {
      const uid = document.id;
      const attemptedAt = dependencies.now().toISOString();
      if (!(await dependencies.isResumable(uid))) {
        const code = "missing_resumable_receipt";
        await document.ref.set(
          {
            pending: false,
            reconciliationStatus: "quarantined",
            reconciliationErrorCode: code,
            reconciliationAttemptedAt: attemptedAt,
            updatedAt: attemptedAt,
          },
          { merge: true },
        );
        return { uid, status: "quarantined", errorCode: code };
      }

      try {
        const eraseResult = await dependencies.erase(uid);
        const incompleteCode = incompleteEraseCode(eraseResult);
        if (incompleteCode) {
          throw Object.assign(new Error(incompleteCode), { code: incompleteCode });
        }
        return { uid, status: "completed" };
      } catch (reason) {
        const code = errorCode(reason);
        await document.ref.set(
          {
            reconciliationStatus: "retry_pending",
            reconciliationErrorCode: code,
            reconciliationAttemptCount: priorAttemptCount(document) + 1,
            reconciliationAttemptedAt: attemptedAt,
            // The query is oldest-first. Moving a failure to the tail prevents
            // a fixed poison batch from starving later erasure requests.
            updatedAt: attemptedAt,
          },
          { merge: true },
        );
        return { uid, status: "failed", errorCode: code };
      }
    }),
  );
}

export const reconcileAccountErasures = onSchedule(
  {
    schedule: "every 15 minutes",
    region: FUNCTIONS_REGION,
    timeoutSeconds: 540,
    memory: "1GiB",
    maxInstances: 1,
  },
  async () => {
    const pending = await db
      .collection("account_erasure_tombstones")
      .where("pending", "==", true)
      .orderBy("updatedAt", "asc")
      .limit(RECONCILE_BATCH_LIMIT)
      .get();

    const results = await reconcilePendingAccountErasures(pending.docs, {
      isResumable: (uid) => isAccountErasureResumable(db, uid),
      erase: (uid) =>
        eraseUserAccount(db, uid, {
          destroyCredential,
          revokeAuthTokens: async (targetUID) => auth.revokeRefreshTokens(targetUID),
          deleteAuthUser: async (targetUID) => auth.deleteUser(targetUID),
          resumeExistingIntent: true,
          audit: {
            actor: "system:account-erasure-reconciler",
            domain: "account",
          },
        }),
      now: () => new Date(),
    });

    const failed = results.filter((result) => result.status === "failed" || result.status === "quarantined");
    logInfo({
      event: "account_erasure_reconcile_complete",
      attempted: results.length,
      completed: results.filter((result) => result.status === "completed").length,
      failed: results.filter((result) => result.status === "failed").length,
      quarantined: results.filter((result) => result.status === "quarantined").length,
    });
    for (const result of failed) {
      logError({
        event: "account_erasure_reconcile_failed",
        error_code: result.errorCode ?? "unknown",
        status: result.status,
      });
    }
  },
);
