import type { Transaction } from "firebase-admin/firestore";
import { HttpsError } from "firebase-functions/v2/https";

import { db } from "../adminRuntime.js";
import {
  IROH_CONTROLLER_DEVICE_LIMIT,
  IROH_HOST_ESCROW_PLATFORMS,
  PHONE_CONTROL_ESCROW_PLATFORMS,
  boundedFirestoreDocumentId,
  normalizedControllerDeviceAllowlist,
} from "./computerUseSecurityCodecs.js";
import {
  requireActiveIrohPairing,
  requireVerifiedControllerAuthority,
} from "./irohControllerRouteSecurity.js";

type VerifiedIrohControllerRouteJoin = {
  authorityPublicKeySHA256: string;
  authorityPublicKey: Buffer;
  authorityKeyKind: "ed25519" | "se-p256";
  pairingPublishedAtMillis: number;
};

function requireRecord(
  snapshot: { exists: boolean; data(): Record<string, unknown> | undefined },
  message: string,
): Record<string, unknown> {
  const data = snapshot.exists ? snapshot.data() : undefined;
  if (!data) throw new HttpsError("failed-precondition", message);
  return data;
}

export function requireTrustedIrohRouteDevice(
  device: Record<string, unknown>,
  deviceId: string,
  allowedPlatforms: ReadonlySet<string>,
): void {
  if (
    device.trustState !== "trusted" ||
    typeof device.platform !== "string" ||
    !allowedPlatforms.has(device.platform) ||
    (device.deviceId != null && device.deviceId !== deviceId)
  ) {
    throw new HttpsError("permission-denied", "Controller route requires a trusted same-user native device.");
  }
}

export async function readAndVerifyIrohControllerRouteJoin(args: {
  transaction: Transaction;
  uid: string;
  connectionId: string;
  sourceDeviceId: string;
  authorityPeerNodeId: string;
  nowMillis: number;
}): Promise<VerifiedIrohControllerRouteJoin> {
  const pairing = requireRecord(
    await args.transaction.get(db.doc(`users/${args.uid}/iroh_pairing/${args.connectionId}`)),
    "Active iroh pairing not found.",
  );
  const hostKey = requireRecord(
    await args.transaction.get(db.doc(`users/${args.uid}/iroh_pairing_keys/host`)),
    "Iroh host trust root not found.",
  );
  const hostDeviceId = boundedFirestoreDocumentId(
    pairing.publishedByDeviceId,
    "pairing.publishedByDeviceId",
    160,
  );
  const hostDevice = requireRecord(
    await args.transaction.get(db.doc(`users/${args.uid}/escrow_devices/${hostDeviceId}`)),
    "Trusted iroh host device not found.",
  );
  const sourceDevice = requireRecord(
    await args.transaction.get(db.doc(`users/${args.uid}/escrow_devices/${args.sourceDeviceId}`)),
    "Trusted controller device not found.",
  );
  const controller = requireRecord(
    await args.transaction.get(
      db.doc(
        `users/${args.uid}/iroh_pairing/${args.connectionId}/controllers/${args.authorityPeerNodeId}`,
      ),
    ),
    "Controller authority not found.",
  );

  const allowlist = normalizedControllerDeviceAllowlist(pairing.authorizedControllerDeviceIds);
  if (allowlist.length > IROH_CONTROLLER_DEVICE_LIMIT || !allowlist.includes(args.sourceDeviceId)) {
    throw new HttpsError("permission-denied", "Iroh pairing does not authorize this controller device.");
  }
  requireTrustedIrohRouteDevice(sourceDevice, args.sourceDeviceId, PHONE_CONTROL_ESCROW_PLATFORMS);
  if (sourceDevice.peerNodeId !== args.authorityPeerNodeId) {
    throw new HttpsError("permission-denied", "Controller authority is not the device's current peer binding.");
  }
  requireTrustedIrohRouteDevice(hostDevice, hostDeviceId, IROH_HOST_ESCROW_PLATFORMS);
  const activePairing = requireActiveIrohPairing({
    uid: args.uid,
    connectionId: args.connectionId,
    pairing,
    hostKey,
    nowMillis: args.nowMillis,
  });
  const authority = requireVerifiedControllerAuthority({
    connectionId: args.connectionId,
    sourceDeviceId: args.sourceDeviceId,
    authorityPeerNodeId: args.authorityPeerNodeId,
    controller,
  });
  return {
    authorityPublicKeySHA256: authority.authorityPublicKeySHA256,
    authorityPublicKey: authority.authorityPublicKey,
    authorityKeyKind: authority.authorityKeyKind,
    pairingPublishedAtMillis: activePairing.publishedAtMillis,
  };
}
