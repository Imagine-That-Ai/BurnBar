/**
 * @fileoverview BurnBar Community — consent-gated cross-platform leaderboards
 * and Looking Glass Mode.
 *
 * Barrel re-export for the community subsystem. The three modules are:
 *   - consent.ts       — server-side consent recheck (dark-before-opt-in gate)
 *   - aggregation.ts   — hourly onSchedule leaderboard computation
 *   - callables.ts     — joinCommunity, updateCommunityProfile,
 *                         revokeCommunityParticipation, exportLookingGlassBundle
 */

export { deriveGeoKeys, populateGeoKeys, type GeoKeys } from "./geo.js";
export { COMMUNITY_K_THRESHOLD, recheckConsent, type CommunityConsentSnapshot } from "./consent.js";
export { aggregateCommunityLeaderboards } from "./aggregation.js";
export {
  joinCommunity,
  updateCommunityProfile,
  revokeCommunityParticipation,
  exportLookingGlassBundle,
} from "./callables.js";
