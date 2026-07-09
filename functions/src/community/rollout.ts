/**
 * @fileoverview Runtime rollout gates for Community.
 *
 * The feature has two independent levers:
 *   1. `communityKillSwitch` — hard stop for mutation/export/aggregation work.
 *   2. `communityPublicReadsEnabled` — publishes the Firestore status document
 *      that rules consult before allowing public leaderboard reads.
 *
 * Firestore rules cannot read environment or Remote Config directly, so the
 * backend writes a small public-read envelope at `/ops/community_status/state/current`.
 */

import { HttpsError } from "firebase-functions/v2/https";

import { getConfig } from "../config.js";
import { firestoreWithResilience } from "../resilienceHelpers.js";
import type { EnvConfig } from "../types.js";
import type { CommunityFirestoreReader } from "./firestoreTypes.js";
import { CommunityPaths } from "./consent.js";

interface CommunityRuntimeStatus {
  enabled: boolean;
  publicReadsEnabled: boolean;
  reason: "enabled" | "kill_switch" | "public_reads_disabled";
}

export function communityRuntimeStatus(
  config: Pick<EnvConfig, "communityKillSwitch" | "communityPublicReadsEnabled"> = getConfig(),
): CommunityRuntimeStatus {
  if (config.communityKillSwitch) {
    return { enabled: false, publicReadsEnabled: false, reason: "kill_switch" };
  }
  if (!config.communityPublicReadsEnabled) {
    return { enabled: true, publicReadsEnabled: false, reason: "public_reads_disabled" };
  }
  return { enabled: true, publicReadsEnabled: true, reason: "enabled" };
}

export function assertCommunityRuntimeEnabled(action: string): void {
  const status = communityRuntimeStatus();
  if (!status.enabled) {
    throw new HttpsError(
      "failed-precondition",
      `Community ${action} is temporarily disabled by the server rollout gate.`,
    );
  }
}

export async function publishCommunityRuntimeStatus(db: CommunityFirestoreReader): Promise<CommunityRuntimeStatus> {
  const status = communityRuntimeStatus();
  await firestoreWithResilience("community-runtime-status-write", () =>
    db.doc(CommunityPaths.publicReadStatus()).set({
      enabled: status.publicReadsEnabled,
      featureEnabled: status.enabled,
      reason: status.reason,
      updatedAt: new Date().toISOString(),
      schemaVersion: 1,
    }),
  );
  return status;
}
