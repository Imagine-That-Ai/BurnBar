import { FieldValue, type DocumentReference, type Transaction } from "firebase-admin/firestore";
import { HttpsError } from "firebase-functions/v2/https";

import { db } from "../adminRuntime.js";

const TRUSTED_DEVICE_PEER_NODE_ID_LIMIT = 16;

function normalizedTrustedDevicePeerNodeIds(rawPeerNodeId: unknown, rawPeerNodeIds: unknown): string[] {
  const ids: string[] = [];
  const append = (value: unknown) => {
    if (typeof value !== "string") return;
    const trimmed = value.trim();
    if (trimmed.length === 0 || ids.includes(trimmed)) return;
    ids.push(trimmed);
  };
  append(rawPeerNodeId);
  if (Array.isArray(rawPeerNodeIds)) {
    for (const value of rawPeerNodeIds) append(value);
  }
  return ids.slice(-TRUSTED_DEVICE_PEER_NODE_ID_LIMIT);
}

export async function stageTrustedEscrowDevicePeerNodeBinding(args: {
  transaction: Transaction;
  uid: string;
  deviceId: string;
  peerNodeId: string;
  permittedPriorPeerRefs?: DocumentReference[];
  permittedPriorPeerRefForPeerNodeId?: (peerNodeId: string) => DocumentReference;
}): Promise<void> {
  const {
    transaction,
    uid,
    deviceId,
    peerNodeId,
    permittedPriorPeerRefs = [],
    permittedPriorPeerRefForPeerNodeId,
  } = args;
  const deviceRef = db.doc(`users/${uid}/escrow_devices/${deviceId}`);
  const device = await transaction.get(deviceRef);
  if (!device.exists || device.get("trustState") !== "trusted") {
    throw new HttpsError("permission-denied", "Phone-control peer binding requires a trusted device.");
  }
  const existingPeerNodeIds = normalizedTrustedDevicePeerNodeIds(device.get("peerNodeId"), device.get("peerNodeIds"));
  const existingPeerNodeId = device.get("peerNodeId");
  if (
    !existingPeerNodeIds.includes(peerNodeId) &&
    typeof existingPeerNodeId === "string" &&
    existingPeerNodeId.length > 0
  ) {
    let priorPeerIsDurableForDevice = Array.isArray(device.get("peerNodeIds"));
    const priorRefs = [...permittedPriorPeerRefs];
    if (permittedPriorPeerRefForPeerNodeId) {
      priorRefs.push(permittedPriorPeerRefForPeerNodeId(existingPeerNodeId));
    }
    for (const priorRef of priorRefs) {
      const prior = await transaction.get(priorRef);
      const priorDeviceId = prior.get("deviceId") ?? prior.get("sourceDeviceId");
      if (prior.exists && priorDeviceId === deviceId && prior.get("peerNodeId") === existingPeerNodeId) {
        priorPeerIsDurableForDevice = true;
        break;
      }
    }
    if (!priorPeerIsDurableForDevice) {
      throw new HttpsError("permission-denied", "Phone-control peer node does not match the trusted device binding.");
    }
  }
  const peerNodeIds = normalizedTrustedDevicePeerNodeIds(undefined, [...existingPeerNodeIds, peerNodeId]);
  transaction.set(
    deviceRef,
    {
      peerNodeId,
      peerNodeIds,
      updatedAt: FieldValue.serverTimestamp(),
    },
    { merge: true },
  );
}

export async function bindTrustedEscrowDevicePeerNodeId(args: {
  uid: string;
  deviceId: string;
  peerNodeId: string;
  permittedPriorPeerRefs?: DocumentReference[];
  permittedPriorPeerRefForPeerNodeId?: (peerNodeId: string) => DocumentReference;
}): Promise<void> {
  await db.runTransaction(async (transaction) => {
    await stageTrustedEscrowDevicePeerNodeBinding({ transaction, ...args });
  });
}
