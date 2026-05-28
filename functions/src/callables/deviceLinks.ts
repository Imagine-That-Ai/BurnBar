/**
 * @fileoverview Provider account device link callables and scheduled backfill
 */

import { HttpsError, onCall, type CallableRequest } from "firebase-functions/v2/https";
import { onSchedule } from "firebase-functions/v2/scheduler";

import { getConfig } from "../config.js";
import { enforceAuthAndAppCheck } from "../auth.js";
import { db } from "../adminRuntime.js";
import { logInfo, wrapCallableHandler } from "../logging.js";
import {
  adoptDeviceLink,
  backfillUserDeviceLinks,
  isDeviceLinkCapability,
  revokeDeviceLink,
} from "../domains/device-links/index.js";

// ---------------------------------------------------------------------------
// Callable: adoptProviderAccountForDevice
//
// Owner-only. Writes a `use` device link onto an existing provider account.
// Validates that the calling user owns both the account and the device.
// ---------------------------------------------------------------------------

export const adoptProviderAccountForDevice = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 50,
  },
  wrapCallableHandler("adoptProviderAccountForDevice", async (
    request: CallableRequest<{
      accountID: string;
      deviceID: string;
      deviceDisplayName?: string;
      capability?: string;
    }>
  ) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in before adopting a provider account.");
    }
    enforceAuthAndAppCheck(request, uid);

    const accountID = String(request.data.accountID ?? "").trim();
    const deviceID = String(request.data.deviceID ?? "").trim();
    if (!accountID) {
      throw new HttpsError("invalid-argument", "accountID is required.");
    }
    if (!deviceID) {
      throw new HttpsError("invalid-argument", "deviceID is required.");
    }

    const requestedCap = request.data.capability;
    if (requestedCap !== undefined && !isDeviceLinkCapability(requestedCap)) {
      throw new HttpsError("invalid-argument", "capability must be one of owner/use/add.");
    }

    const doc = await adoptDeviceLink({
      db,
      uid,
      accountID,
      deviceID,
      deviceDisplayName: request.data.deviceDisplayName,
      capability: requestedCap,
    });
    return { success: true, link: doc };
  }
));

// ---------------------------------------------------------------------------
// Callable: revokeProviderAccountDeviceLink
//
// Soft-revoke a single device link. Owner-only.
// ---------------------------------------------------------------------------

export const revokeProviderAccountDeviceLink = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 50,
  },
  wrapCallableHandler("revokeProviderAccountDeviceLink", async (
    request: CallableRequest<{ accountID: string; deviceID: string }>
  ) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in before revoking device links.");
    }
    enforceAuthAndAppCheck(request, uid);

    const accountID = String(request.data.accountID ?? "").trim();
    const deviceID = String(request.data.deviceID ?? "").trim();
    if (!accountID || !deviceID) {
      throw new HttpsError("invalid-argument", "accountID and deviceID are required.");
    }
    await revokeDeviceLink({ db, uid, accountID, deviceID });
    return { success: true };
  }
));

// ---------------------------------------------------------------------------
// Callable: backfillProviderAccountDeviceLinks
//
// Idempotent. Walks every provider_accounts/* doc for the caller and writes
// owner + use links so existing accounts surface at least one device chip
// after the rollout.
// ---------------------------------------------------------------------------

export const backfillProviderAccountDeviceLinks = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 20,
    timeoutSeconds: 300,
  },
  wrapCallableHandler("backfillProviderAccountDeviceLinks", async (
    request: CallableRequest<{
      callerDeviceID?: string;
      callerDeviceDisplayName?: string;
    }>
  ) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in before running backfill.");
    }
    enforceAuthAndAppCheck(request, uid);

    const callerDeviceID = String(request.data.callerDeviceID ?? "").trim() || undefined;
    const callerDeviceDisplayName =
      String(request.data.callerDeviceDisplayName ?? "").trim() || undefined;

    const writes = await backfillUserDeviceLinks(
      db,
      uid,
      callerDeviceID,
      callerDeviceDisplayName
    );
    return { success: true, writes };
  }
));

export const backfillProviderAccountDeviceLinksScheduled = onSchedule(
  {
    region: "us-central1",
    schedule: "every 24 hours",
    timeoutSeconds: 300,
    memory: "512MiB",
  },
  async () => {
    const users = await db.collection("users").limit(500).get();
    let usersScanned = 0;
    let writes = 0;
    for (const user of users.docs) {
      usersScanned += 1;
      writes += await backfillUserDeviceLinks(db, user.id, undefined, undefined);
    }
    logInfo({ event: "callable_info", message: "provider_account_device_links scheduled backfill", ...{ usersScanned, writes } });
  }
);
