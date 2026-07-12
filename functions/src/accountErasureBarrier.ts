/** Server-side account-erasure write barrier for authenticated callables. */

import { HttpsError } from "firebase-functions/v2/https";

import { db } from "./adminRuntime.js";
import { ACCOUNT_ERASURE_TOMBSTONE_COLLECTION } from "./accountErasureConstants.js";

const ERASURE_CALLABLE_ALLOWLIST = new Set(["deleteUserCloudData"]);

export async function assertAccountErasureAllowsCallable(uid: string, callableName: string): Promise<void> {
  if (ERASURE_CALLABLE_ALLOWLIST.has(callableName)) return;
  const tombstone = await db.doc(`${ACCOUNT_ERASURE_TOMBSTONE_COLLECTION}/${uid}`).get();
  if (tombstone.exists) {
    throw new HttpsError(
      "failed-precondition",
      "Account deletion is in progress. Only the account-deletion recovery operation is available.",
    );
  }
}
