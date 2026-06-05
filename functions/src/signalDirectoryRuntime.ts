/**
 * @fileoverview L41 server runtime helpers for Signal session REVOCATION —
 * shared by the targeted device-trust revoke (computerUseSecurity.ts) and the
 * panic button (panic.ts).
 *
 * When an escrow device is revoked, its Signal session-directory entries must
 * stop showing "active": both the sessions the device OWNS and the sessions in
 * which it is the PEER. The serialized Signal session + ratchet state always
 * lived on-device, so revocation here is METADATA-ONLY (status -> revoked).
 *
 * Re-wrapping the existing CloudVault content keys to the surviving device set
 * (so the revoked device is excluded from FUTURE reads) is a device-driven
 * crypto task; the server side of that is recorded as a rewrap-required
 * rotation_event via recordSignalRotation (signalPrekeyDirectory.ts). Excluding
 * the revoked device from new wraps is enforced by the producers, which only
 * wrap to escrow devices whose trustState is pending/trusted.
 */

import { FieldValue } from "firebase-admin/firestore";
import type { DocumentData, WriteBatch } from "firebase-admin/firestore";

import { db } from "./adminRuntime.js";
import { commitBatchedWrites } from "./callables/shared.js";

/** Pure: does this session-directory doc involve the given device (owner or peer)? */
export function sessionInvolvesDevice(data: DocumentData, deviceId: string): boolean {
  return data.deviceId === deviceId || data.peerDeviceId === deviceId;
}

/** Flip every ACTIVE session under the user that involves `deviceId` to revoked. */
export async function revokeSignalSessionsForDevice(uid: string, deviceId: string): Promise<number> {
  return revokeSignalSessionsMatching(uid, (data) => sessionInvolvesDevice(data, deviceId));
}

/** Flip every ACTIVE session under the user to revoked (panic button). */
export async function revokeAllSignalSessions(uid: string): Promise<number> {
  return revokeSignalSessionsMatching(uid, () => true);
}

/**
 * Walk the user's published Signal identities and flip every active session
 * matching `predicate` to status=revoked. Bounded by (#identities * #sessions),
 * which is small per user; revocation is rare and security-critical, so the
 * extra reads are acceptable.
 */
async function revokeSignalSessionsMatching(
  uid: string,
  predicate: (data: DocumentData) => boolean,
): Promise<number> {
  const identities = await db.collection(`users/${uid}/signal_identity_public_keys`).get();
  const writes: Array<(batch: WriteBatch) => void> = [];
  for (const identity of identities.docs) {
    const sessions = await identity.ref.collection("sessions").where("status", "==", "active").get();
    for (const session of sessions.docs) {
      if (predicate(session.data())) {
        writes.push((batch) =>
          batch.set(
            session.ref,
            { status: "revoked", updatedAt: FieldValue.serverTimestamp() },
            { merge: true },
          ),
        );
      }
    }
  }
  if (writes.length > 0) await commitBatchedWrites(writes);
  return writes.length;
}
