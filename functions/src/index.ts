/**
 * @fileoverview OpenBurnBar Cloud Functions v2 — admin codebase entry point.
 *
 * Initializes Firebase Admin and re-exports this codebase's callable,
 * scheduled, and trigger functions from domains/ modules. (3.5 split:
 * functions/ (admin), functions-identity, functions-sync, functions-media.)
 */

import "@openburnbar/functions-shared/adminRuntime.js";

export { healthCheck, healthLive, healthReady } from "./domains/ops/health.js";
export { reconcileAccountErasures } from "./domains/lifecycle/accountDeletionReconciler.js";
export { reapExpiredCounterDayBuckets } from "./domains/scheduled/reapExpiredCounterDays.js";
export { exportUserData } from "./domains/compliance/dataExport.js";
export { deleteDomainData } from "./domains/compliance/dataDeletion.js";
export { setupRecovery, confirmRecovery, listRecovery } from "./domains/ops/recovery.js";
export { revokeAllAccess } from "./domains/ops/panic.js";
export { getAuditLog, verifyAuditLog } from "./domains/audit/auditLog.js";
export { rebuildUsageRollups, seedAndroidDemoAccount } from "./domains/ops/misc.js";
export {
  onUsageWritten,
  rebuildRollups,
  rollupUserRebuild,
  refreshAllProviderQuotas,
  refreshModelLandscapeBenchmarks,
  anchorAuditLogHeads,
  latestRouterRundown,
} from "./domains/scheduled/scheduledExports.js";
export { backfillPrivacyPlaintext, backfillPrivacyPlaintextScheduled } from "./domains/compliance/privacyBackfill.js";
export { scanLegacyPlaintextArtifacts } from "./domains/ops/sharedArtifactLegacyScan.js";
