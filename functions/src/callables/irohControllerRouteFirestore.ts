import { FieldValue, type DocumentReference } from "firebase-admin/firestore";

import { db } from "../adminRuntime.js";
import { boundedInteger, normalizedControllerDeviceAllowlist } from "./computerUseSecurityCodecs.js";

export async function revokeIrohPairingAndControllerRoutes(
  uid: string,
  connectionId: string,
  revokedAtMillis = Date.now(),
): Promise<void> {
  const pairingRef = db.doc(`users/${uid}/iroh_pairing/${connectionId}`);
  await db.runTransaction(async (transaction) => {
    const pairing = await transaction.get(pairingRef);
    if (pairing.exists) {
      const controllerDeviceIds = normalizedControllerDeviceAllowlist(pairing.get("authorizedControllerDeviceIds"));
      const routes: Array<{ ref: DocumentReference; generation: number }> = [];
      for (const sourceDeviceId of controllerDeviceIds) {
        const routeRef = db.doc(`users/${uid}/iroh_pairing/${connectionId}/controller_routes/${sourceDeviceId}`);
        const route = await transaction.get(routeRef);
        if (route.exists) {
          const generation =
            boundedInteger(route.get("generation"), "route.generation", 1, Number.MAX_SAFE_INTEGER - 1, true) ?? 0;
          routes.push({ ref: routeRef, generation });
        }
      }
      for (const route of routes) {
        transaction.set(
          route.ref,
          {
            status: "revoked",
            generation: route.generation + 1,
            expiresAtMillis: revokedAtMillis,
            revokedAtMillis,
            updatedAt: FieldValue.serverTimestamp(),
          },
          { merge: true },
        );
      }
    }
    transaction.delete(pairingRef);
  });
}
