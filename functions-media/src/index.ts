/**
 * @fileoverview OpenBurnBar Cloud Functions v2 — media codebase entry point.
 *
 * Initializes Firebase Admin and re-exports this codebase's callable,
 * scheduled, and trigger functions from domains/ modules. (3.5 split:
 * functions/ (admin), functions-identity, functions-sync, functions-media.)
 */

import "@openburnbar/functions-shared/adminRuntime.js";

export { markIrohAuditEventRollupEligible, rollupIrohTransportDaily } from "./domains/relay/irohMonitoring.js";
export { triggerVoIPCall } from "./domains/push/voipPush.js";
export { sendVoIPOutbound, retryStuckVoIPPushes } from "./domains/push/apnsSender.js";
export {
  onComputerUseActionLiveActivity,
  onComputerUseSessionLiveActivity,
} from "./domains/push/liveActivityPush.js";
export { retryStuckFcmPushes, sendFcmOutbound } from "./domains/push/fcmAndroidSender.js";
export {
  createHermesPairing,
  completeHermesPairing,
  listHermesConnections,
  revokeHermesConnection,
  updateHermesConnectionStatus,
} from "./domains/hermes/hermes.js";
export {
  burnBarHermesGateway,
  getHermesGatewayAttachmentDownloadUrl,
  approveHermesGatewayDeviceGrant,
  listHermesGatewayClients,
  revokeHermesGatewayClient,
  rotateHermesGatewayClientToken,
  enqueueHermesGatewayEvent,
  setHermesGatewayOversightMode,
  respondHermesGatewayApproval,
  reapHermesGatewayApprovals,
} from "./domains/hermes/hermesGateway.js";
export { reapBurnbarAttachments } from "./domains/attachments/reapBurnbarAttachments.js";
export {
  beginBurnbarAttachment,
  mintBurnbarAttachmentPartURL,
  composeBurnbarAttachment,
  finalizeBurnbarAttachment,
  ticketBurnbarAttachmentDownload,
  deleteBurnbarAttachment,
} from "./domains/attachments/burnbarAttachments.js";
