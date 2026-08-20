/**
 * @fileoverview Provider quota refresh callables (account-scoped and legacy)
 */

import { HttpsError, onCall, type CallableRequest } from "firebase-functions/v2/https";

import { getConfig } from "../config.js";
import { enforceAuthAndAppCheck } from "../auth.js";
import { db } from "../adminRuntime.js";
import { wrapCallableHandler } from "../logging.js";
import { accountIDFor, assertProvider, checkRefreshRateLimit } from "./shared.js";
import { refreshUserProviderAccountQuota, refreshUserProviderQuota } from "../quota.js";
import { errorMessage, requireProviderAccountDoc } from "../guards.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";
import { HOSTED_RUNNER_SECRETS } from "../hostedRunnerConfig.js";
import { isDemoProviderAccountRecord } from "../providerAccountIsolation.js";

// ---------------------------------------------------------------------------
// Callable: refreshProviderAccountQuota
// ---------------------------------------------------------------------------

async function rateLimitProviderForAccountRefresh(uid: string, accountID: string): Promise<void> {
  const accountSnap = await db.doc(`users/${uid}/provider_accounts/${accountID}`).get();
  if (!accountSnap.exists) {
    throw new HttpsError("not-found", `No provider account found for ${accountID}.`);
  }

  const accountData = accountSnap.data();
  if (isDemoProviderAccountRecord(accountData, accountID)) {
    return;
  }

  const account = requireProviderAccountDoc(accountData);
  if (account.id !== accountID) {
    throw new HttpsError("invalid-argument", `Provider account ID mismatch for ${accountID}.`);
  }

  assertProvider(account.providerID);
  await checkRefreshRateLimit(db, uid, account.providerID);
}

export const refreshProviderAccountQuota = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
    secrets: HOSTED_RUNNER_SECRETS,
  },
  wrapCallableHandler("refreshProviderAccountQuota", async (request: CallableRequest<{ accountID: string }>) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in before refreshing provider quota.");
    }
    enforceAuthAndAppCheck(request, uid);

    const accountID = accountIDFor("account", request.data.accountID);
    await rateLimitProviderForAccountRefresh(uid, accountID);
    const snapshot = await refreshUserProviderAccountQuota(db, uid, accountID);
    if (!snapshot) {
      throw new HttpsError("failed-precondition", "Quota refresh returned no snapshot. Please try again.");
    }
    return snapshot;
  }),
);

// ---------------------------------------------------------------------------
// Callable: refreshProviderQuota (legacy provider-scoped fan-out)
// ---------------------------------------------------------------------------

export const refreshProviderQuota = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
    secrets: HOSTED_RUNNER_SECRETS,
  },
  wrapCallableHandler("refreshProviderQuota", async (request: CallableRequest<{ provider: string }>) => {
    const { provider } = request.data;
    const uid = request.auth?.uid;

    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in before refreshing provider quota.");
    }
    enforceAuthAndAppCheck(request, uid);
    assertProvider(provider);

    await checkRefreshRateLimit(db, uid, provider);

    const accountSnapshot = await db
      .collection(`users/${uid}/provider_accounts`)
      .where("providerID", "==", provider)
      .where("status", "in", ["connected", "stale", "error"])
      .get();

    if (!accountSnapshot.empty) {
      return refreshAccountsForProvider(uid, provider, accountSnapshot.docs);
    }

    assertProvider(provider);
    const snapshot = await refreshUserProviderQuota(db, uid, provider);
    if (!snapshot) {
      throw new HttpsError("failed-precondition", "Quota refresh returned no snapshot. Please try again.");
    }

    return {
      success: true,
      provider,
      refreshedAccountIDs: [snapshot.accountID ?? `${provider}_default`],
      skippedAccountIDs: [],
      errorAccountIDs: [],
      snapshots: [snapshot],
    };
  }),
);

type ProviderAccountQuerySnapshot = FirebaseFirestore.QueryDocumentSnapshot<FirebaseFirestore.DocumentData>;

async function refreshAccountsForProvider(uid: string, provider: string, docs: ProviderAccountQuerySnapshot[]) {
  const snapshots = [];
  const skippedAccountIDs: string[] = [];
  const errors: Array<{ accountID: string; message: string }> = [];

  for (const doc of docs) {
    const accountData = doc.data();
    const account = requireProviderAccountDoc(accountData);
    if (isDemoProviderAccountRecord(accountData, account.id)) {
      skippedAccountIDs.push(account.id);
      continue;
    }
    if (account.storageScope !== "cloud_refreshable" && account.storageScope !== "server_private") {
      skippedAccountIDs.push(account.id);
      continue;
    }

    try {
      const snapshot = await refreshUserProviderAccountQuota(db, uid, account.id);
      if (snapshot) {
        snapshots.push(snapshot);
      }
    } catch (err) {
      errors.push({
        accountID: account.id,
        message: errorMessage(err),
      });
    }
  }

  if (snapshots.length === 0 && errors.length > 0) {
    throw new Error(
      `failed-precondition: no ${provider} accounts refreshed: ${errors
        .map((err) => `${err.accountID}: ${err.message}`)
        .join("; ")}`,
    );
  }

  return {
    success: true,
    provider,
    refreshedAccountIDs: snapshots.map((snapshot) => snapshot.accountID),
    skippedAccountIDs,
    errorAccountIDs: errors.map((err) => err.accountID),
    snapshots,
  };
}
