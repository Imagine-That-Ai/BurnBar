/**
 * @fileoverview Provider Account Device Links — server-side helpers.
 *
 * Canonical path:
 *   users/{uid}/provider_account_device_links/{accountID}_{deviceID}
 *
 * ProviderAccountDoc.sourceDeviceID remains for compatibility, but new readers
 * should prefer these links because one provider account can be attached to
 * multiple devices.
 */

import { type Firestore } from "firebase-admin/firestore";
import { HttpsError } from "firebase-functions/v2/https";

import type {
  DeviceLinkCapability,
  DeviceLinkStatus,
  ProviderAccountDeviceLinkDoc,
  ProviderAccountDoc,
} from "./types.js";

const SCHEMA_VERSION = 1;

const VALID_CAPABILITIES: readonly DeviceLinkCapability[] = ["owner", "use", "add"];

export function isDeviceLinkCapability(value: unknown): value is DeviceLinkCapability {
  return typeof value === "string" && (VALID_CAPABILITIES as readonly string[]).includes(value);
}

export function deviceLinkId(accountID: string, deviceID: string): string {
  return `${safeIdentifier(accountID, "account")}_${safeIdentifier(deviceID, "device")}`;
}

export function deviceLinkPath(uid: string, accountID: string, deviceID: string): string {
  return `users/${uid}/provider_account_device_links/${deviceLinkId(accountID, deviceID)}`;
}

export function deviceLinkCollectionPath(uid: string): string {
  return `users/${uid}/provider_account_device_links`;
}

interface UpsertParams {
  db: Firestore;
  uid: string;
  accountID: string;
  deviceID: string;
  deviceDisplayName: string;
  capability: DeviceLinkCapability;
  status?: DeviceLinkStatus;
}

export async function upsertDeviceLink(params: UpsertParams): Promise<ProviderAccountDeviceLinkDoc> {
  const { db, uid, capability } = params;
  const accountID = safeIdentifier(params.accountID, "account");
  const deviceID = safeIdentifier(params.deviceID, "device");
  const id = deviceLinkId(accountID, deviceID);
  const ref = db.doc(`users/${uid}/provider_account_device_links/${id}`);
  const snap = await ref.get();
  const now = new Date().toISOString();
  const existing = snap.exists ? snap.data() as Partial<ProviderAccountDeviceLinkDoc> : undefined;
  const doc: ProviderAccountDeviceLinkDoc = {
    id,
    accountID,
    deviceID,
    deviceDisplayName: params.deviceDisplayName.trim() || deviceID,
    capability,
    status: params.status ?? "active",
    lastObservedAt: now,
    createdAt: existing?.createdAt ?? now,
    updatedAt: now,
    schemaVersion: SCHEMA_VERSION,
  };

  await ref.set(doc, { merge: true });
  return doc;
}

interface AdoptParams {
  db: Firestore;
  uid: string;
  accountID: string;
  deviceID: string;
  deviceDisplayName?: string;
  capability?: DeviceLinkCapability;
}

export async function adoptDeviceLink(params: AdoptParams): Promise<ProviderAccountDeviceLinkDoc> {
  const { db, uid } = params;
  const accountID = safeIdentifier(params.accountID, "account");
  const deviceID = safeIdentifier(params.deviceID, "device");
  const accountRef = db.doc(`users/${uid}/provider_accounts/${accountID}`);
  const accountSnap = await accountRef.get();
  if (!accountSnap.exists) {
    throw new HttpsError("not-found", "Provider account does not exist.");
  }
  const account = accountSnap.data() as ProviderAccountDoc | undefined;
  if (!account || account.status === "deleted") {
    throw new HttpsError("failed-precondition", "Provider account is not active.");
  }

  const deviceDoc = await db.doc(`users/${uid}/devices/${deviceID}`).get();
  let resolvedName = params.deviceDisplayName?.trim();
  if (!resolvedName && deviceDoc.exists) {
    const data = deviceDoc.data() as { displayName?: string } | undefined;
    resolvedName = data?.displayName?.trim();
  }
  if (!resolvedName) {
    resolvedName = deviceID;
  }

  const requested = params.capability ?? "use";
  const capability: DeviceLinkCapability =
    deviceID === account.sourceDeviceID ? "owner" : requested === "owner" ? "use" : requested;

  return upsertDeviceLink({
    db,
    uid,
    accountID,
    deviceID,
    deviceDisplayName: resolvedName,
    capability,
  });
}

interface RevokeParams {
  db: Firestore;
  uid: string;
  accountID: string;
  deviceID: string;
}

export async function revokeDeviceLink(params: RevokeParams): Promise<void> {
  const ref = params.db.doc(deviceLinkPath(params.uid, params.accountID, params.deviceID));
  const snap = await ref.get();
  if (!snap.exists) return;
  await ref.set(
    {
      status: "revoked",
      lastObservedAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
      schemaVersion: SCHEMA_VERSION,
    },
    { merge: true }
  );
}

export async function backfillUserDeviceLinks(
  db: Firestore,
  uid: string,
  callerDeviceID: string | undefined,
  callerDeviceDisplayName: string | undefined
): Promise<number> {
  const accountsSnap = await db.collection(`users/${uid}/provider_accounts`).get();
  let writes = 0;
  for (const accountDocSnap of accountsSnap.docs) {
    const account = accountDocSnap.data() as ProviderAccountDoc;
    const accountID = account.id ?? accountDocSnap.id;
    if (!accountID || account.status === "deleted") continue;

    const sourceDeviceID = account.sourceDeviceID?.trim();
    if (sourceDeviceID) {
      const sourceName = await resolveDeviceName(db, uid, sourceDeviceID);
      await upsertDeviceLink({
        db,
        uid,
        accountID,
        deviceID: sourceDeviceID,
        deviceDisplayName: sourceName,
        capability: "owner",
      });
      writes += 1;
    }

    if (callerDeviceID && callerDeviceID !== sourceDeviceID) {
      await upsertDeviceLink({
        db,
        uid,
        accountID,
        deviceID: callerDeviceID,
        deviceDisplayName: callerDeviceDisplayName?.trim() || callerDeviceID,
        capability: "use",
      });
      writes += 1;
    }
  }
  return writes;
}

export async function revokeAllLinksForAccount(
  db: Firestore,
  uid: string,
  accountID: string
): Promise<void> {
  const snap = await db
    .collection(deviceLinkCollectionPath(uid))
    .where("accountID", "==", safeIdentifier(accountID, "account"))
    .get();
  if (snap.empty) return;
  const batch = db.batch();
  const now = new Date().toISOString();
  for (const doc of snap.docs) {
    batch.set(
      doc.ref,
      {
        status: "revoked",
        lastObservedAt: now,
        updatedAt: now,
        schemaVersion: SCHEMA_VERSION,
      },
      { merge: true }
    );
  }
  await batch.commit();
}

async function resolveDeviceName(
  db: Firestore,
  uid: string,
  deviceID: string
): Promise<string> {
  try {
    const snap = await db.doc(`users/${uid}/devices/${safeIdentifier(deviceID, "device")}`).get();
    if (snap.exists) {
      const data = snap.data() as { displayName?: string };
      const name = data.displayName?.trim();
      if (name) return name;
    }
  } catch {
    // Best effort; use the stable device id as the fallback display.
  }
  return deviceID;
}

function safeIdentifier(raw: string, fallback: string): string {
  const safe = raw
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9_-]/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "");
  return safe || fallback;
}
