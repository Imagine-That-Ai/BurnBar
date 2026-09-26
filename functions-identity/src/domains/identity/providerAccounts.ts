/**
 * @fileoverview Provider account connect, quota, and credential callables
 */

import { HttpsError, onCall, type CallableRequest } from "firebase-functions/v2/https";

import { getConfig } from "@openburnbar/functions-shared/config.js";
import { enforceAuthAndAppCheck } from "@openburnbar/functions-shared/auth.js";
import { db, auth } from "@openburnbar/functions-shared/adminRuntime.js";
import { wrapCallableHandler } from "@openburnbar/functions-shared/logging.js";
import { accountIDFor, connectionDocFromAccount, assertHostedProvider, assertSelfHostedProvider } from "@openburnbar/functions-shared/shared/accounts.js";
import { assertActiveHostedQuotaEntitlement } from "@openburnbar/functions-shared/shared/entitlements.js";
import { connectProviderAccountInternal } from "@openburnbar/functions-shared/shared/providerConnect.js";
import { assertProvider } from "@openburnbar/functions-shared/shared/validators.js";
import { destroyCredential } from "@openburnbar/functions-shared/secrets.js";
import { eraseUserAccount, isAccountErasureResumable } from "@openburnbar/functions-shared/accountDeletion.js";
import { auditActorLabel } from "@openburnbar/functions-shared/shared/auditLog.js";
import type { ProviderAccountConnectContext } from "@openburnbar/functions-shared/types.js";
import { FUNCTIONS_REGION, HOT_PATH_OPTIONS } from "@openburnbar/functions-shared/runtimeOptions.js";
import { enforceHighRiskOwnerAction } from "@openburnbar/functions-shared/callables/highRiskOwnerAction.js";
import {
  applyHostedQuotaConnect,
  applyHostedQuotaCredentialDelete,
  applyProviderAccountDelete,
  applyProviderAccountUpdate,
  applySelfHostedQuotaConnect,
} from "../../callables/providerAccountWrites.js";

// Re-exported callables (split into cohesive sibling modules to stay under the
// per-file line cap). External imports of these symbols keep resolving here.
export { uploadProviderQuotaSnapshot, deleteProviderCredential } from "../../callables/providerAccountSnapshots.js";
export { refreshProviderAccountQuota, refreshProviderQuota } from "../../callables/providerQuotaRefresh.js";

// ---------------------------------------------------------------------------
// Callable: connectProviderAccount
// ---------------------------------------------------------------------------

export const connectProviderAccount = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
    ...HOT_PATH_OPTIONS,
  },
  wrapCallableHandler(
    "connectProviderAccount",
    async (
      request: CallableRequest<{
        provider: string;
        credential: string;
        label?: string;
        accountID?: string;
        sourceDeviceID?: string;
        deviceDisplayName?: string;
        endpointProfileID?: string;
        region?: ProviderAccountConnectContext["region"];
        tokenPlanTier?: ProviderAccountConnectContext["tokenPlanTier"];
        tokenPlanBillingCycle?: ProviderAccountConnectContext["tokenPlanBillingCycle"];
        authMethodID?: string;
      }>,
    ) => {
      const {
        provider,
        credential,
        label,
        accountID,
        sourceDeviceID,
        deviceDisplayName,
        endpointProfileID,
        region,
        tokenPlanTier,
        tokenPlanBillingCycle,
        authMethodID,
      } = request.data;
      const uid = request.auth?.uid;

      if (!uid) {
        throw new HttpsError("unauthenticated", "Sign in before adding a provider account.");
      }
      enforceAuthAndAppCheck(request, uid);
      assertProvider(provider);
      await enforceHighRiskOwnerAction(request, uid, {
        actionKind: "provider_account_connect",
        subjectId: accountIDFor(provider, accountID),
      });

      if (typeof credential !== "string" || credential.trim().length === 0) {
        throw new HttpsError("invalid-argument", "credential must be a non-empty string.");
      }
      if (credential.length > getConfig().maxCredentialLength) {
        throw new HttpsError(
          "invalid-argument",
          `credential exceeds max length (${getConfig().maxCredentialLength} characters).`,
        );
      }

      return connectProviderAccountInternal({
        uid,
        provider,
        credential,
        label,
        accountID,
        sourceDeviceID,
        deviceDisplayName,
        endpointProfileID,
        region,
        tokenPlanTier,
        tokenPlanBillingCycle,
        authMethodID,
        isDefault: accountID == null,
      });
    },
  ),
);

// ---------------------------------------------------------------------------
// Callable: connectProviderCredential (legacy compatibility)
// ---------------------------------------------------------------------------

export const connectProviderCredential = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  wrapCallableHandler(
    "connectProviderCredential",
    async (request: CallableRequest<{ provider: string; credential: string }>) => {
      const { provider, credential } = request.data;
      const uid = request.auth?.uid;

      if (!uid) {
        throw new HttpsError("unauthenticated", "Sign in before connecting a provider.");
      }
      enforceAuthAndAppCheck(request, uid);

      assertProvider(provider);
      await enforceHighRiskOwnerAction(request, uid, {
        actionKind: "provider_credential_connect",
        subjectId: `${provider}_default`,
      });

      if (typeof credential !== "string" || credential.trim().length === 0) {
        throw new HttpsError("invalid-argument", "credential must be a non-empty string.");
      }
      if (credential.length > getConfig().maxCredentialLength) {
        throw new HttpsError(
          "invalid-argument",
          `credential exceeds max length (${getConfig().maxCredentialLength} characters).`,
        );
      }

      const accountDoc = await connectProviderAccountInternal({
        uid,
        provider,
        credential,
        label: "Default",
        accountID: `${provider}_default`,
        isDefault: true,
      });

      return connectionDocFromAccount(accountDoc);
    },
  ),
);

// ---------------------------------------------------------------------------
// Callable: connectHostedQuotaAccount
// ---------------------------------------------------------------------------

export const connectHostedQuotaAccount = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  wrapCallableHandler(
    "connectHostedQuotaAccount",
    async (
      request: CallableRequest<{
        provider: string;
        credential: string;
        label?: string;
        accountID?: string;
        sourceDeviceID?: string;
        deviceDisplayName?: string;
      }>,
    ) => {
      const uid = request.auth?.uid;
      if (!uid) {
        throw new HttpsError("unauthenticated", "Sign in before adding hosted quota sync.");
      }
      enforceAuthAndAppCheck(request, uid);
      const provider = String(request.data.provider ?? "");
      assertHostedProvider(provider);
      await assertActiveHostedQuotaEntitlement(uid);
      const accountID = accountIDFor(provider, request.data.accountID);
      await enforceHighRiskOwnerAction(request, uid, {
        actionKind: "hosted_quota_account_connect",
        subjectId: accountID,
      });

      return applyHostedQuotaConnect(uid, accountID, { ...request.data, provider });
    },
  ),
);

// ---------------------------------------------------------------------------
// Callable: connectSelfHostedQuotaAccount
// ---------------------------------------------------------------------------

export const connectSelfHostedQuotaAccount = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  wrapCallableHandler(
    "connectSelfHostedQuotaAccount",
    async (
      request: CallableRequest<{
        provider: string;
        label?: string;
        accountID?: string;
        sourceDeviceID?: string;
        deviceDisplayName?: string;
      }>,
    ) => {
      const uid = request.auth?.uid;
      if (!uid) {
        throw new HttpsError("unauthenticated", "Sign in before adding self-hosted quota sync.");
      }
      enforceAuthAndAppCheck(request, uid);
      const provider = String(request.data.provider ?? "");
      assertSelfHostedProvider(provider);

      const accountID = accountIDFor(provider, request.data.accountID);
      await enforceHighRiskOwnerAction(request, uid, {
        actionKind: "self_hosted_quota_account_connect",
        subjectId: accountID,
      });

      return applySelfHostedQuotaConnect(uid, accountID, { ...request.data, provider });
    },
  ),
);

// ---------------------------------------------------------------------------
// Callable: deleteHostedQuotaCredentials
// ---------------------------------------------------------------------------

export const deleteHostedQuotaCredentials = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  wrapCallableHandler(
    "deleteHostedQuotaCredentials",
    async (request: CallableRequest<{ accountID: string; provider?: string }>) => {
      const uid = request.auth?.uid;
      if (!uid) {
        throw new HttpsError("unauthenticated", "Sign in before deleting hosted credentials.");
      }
      enforceAuthAndAppCheck(request, uid);
      const provider =
        typeof request.data.provider === "string" && request.data.provider.trim()
          ? request.data.provider.trim()
          : "codex";
      assertHostedProvider(provider);
      const accountID = accountIDFor(provider, request.data.accountID);
      await enforceHighRiskOwnerAction(request, uid, {
        actionKind: "hosted_quota_credential_delete",
        subjectId: accountID,
      });
      return applyHostedQuotaCredentialDelete(uid, accountID);
    },
  ),
);

// ---------------------------------------------------------------------------
// Callable: updateProviderAccount
// ---------------------------------------------------------------------------

export const updateProviderAccount = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  wrapCallableHandler(
    "updateProviderAccount",
    async (
      request: CallableRequest<{
        accountID: string;
        label?: string;
        isDefault?: boolean;
        disabled?: boolean;
      }>,
    ) => {
      const uid = request.auth?.uid;
      if (!uid) {
        throw new HttpsError("unauthenticated", "Sign in before updating provider accounts.");
      }
      enforceAuthAndAppCheck(request, uid);

      const accountID = accountIDFor("account", request.data.accountID);
      await enforceHighRiskOwnerAction(request, uid, {
        actionKind: "provider_account_update",
        subjectId: accountID,
      });
      return applyProviderAccountUpdate(uid, accountID, request.data);
    },
  ),
);

// ---------------------------------------------------------------------------
// Callable: deleteProviderAccount
// ---------------------------------------------------------------------------

export const deleteProviderAccount = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  wrapCallableHandler("deleteProviderAccount", async (request: CallableRequest<{ accountID: string }>) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in before deleting provider accounts.");
    }
    enforceAuthAndAppCheck(request, uid);

    const accountID = accountIDFor("account", request.data.accountID);
    await enforceHighRiskOwnerAction(request, uid, {
      actionKind: "provider_account_delete",
      subjectId: accountID,
    });
    return applyProviderAccountDelete(uid, accountID);
  }),
);

// ---------------------------------------------------------------------------
// Callable: deleteUserCloudData
// ---------------------------------------------------------------------------

export const deleteUserCloudData = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 20,
    timeoutSeconds: 540,
    memory: "1GiB",
  },
  wrapCallableHandler("deleteUserCloudData", async (request: CallableRequest<Record<string, never>>) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in before deleting cloud data.");
    }
    enforceAuthAndAppCheck(request, uid);
    // The first attempt requires the full fresh high-risk proof. A server-only
    // nonterminal erasure record authorizes retries for this same authenticated
    // uid, even if a partial Firestore cleanup removed trusted-device records.
    const resumeExistingIntent = await isAccountErasureResumable(db, uid);
    if (!resumeExistingIntent) {
      await enforceHighRiskOwnerAction(request, uid, {
        actionKind: "user_cloud_data_delete",
        subjectId: uid,
      });
    }

    const summary = await eraseUserAccount(db, uid, {
      destroyCredential,
      revokeAuthTokens: async (targetUID) => {
        await auth.revokeRefreshTokens(targetUID);
      },
      deleteAuthUser: async (targetUID) => {
        await auth.deleteUser(targetUID);
      },
      resumeExistingIntent,
      audit: {
        actor: auditActorLabel(request),
        domain: "account",
      },
    });
    if (summary.retryRequired) {
      throw new HttpsError(
        "unavailable",
        "Account erasure is incomplete because one or more external artifacts could not be deleted. Retry account deletion; your sign-in remains active until cleanup completes.",
        summary,
      );
    }

    return {
      success: true,
      ...summary,
    };
  }),
);
