/**
 * @fileoverview BurnBar Cloud Hermes Gateway HTTP API and management callables.
 *
 * This module is the stable import surface for the Hermes Gateway. The
 * implementation was split into cohesive sibling modules to stay within the
 * per-file size cap; everything that was previously exported here is re-exported
 * below byte-identically so every `import … from "./hermesGateway.js"` keeps
 * resolving unchanged:
 *   - ./hermesGatewayHttp.js     — HTTP plumbing + id/content-type contracts
 *   - ./hermesGatewayCrypto.js   — relay/ratchet keys + proof-of-possession
 *   - ./hermesGatewayResolve.js  — entitlement/grant/attachment resolution
 *   - ./hermesGatewayRoutes.js   — HTTP route handlers + dispatcher + onRequest
 *   - ./hermesGatewayApprove.js  — device-grant approval callable
 *   - ./hermesGatewayEnqueue.js  — event-enqueue callable
 *   - ./hermesGatewayCallables.js — owner-authenticated callables + reaper
 */

export {
  HERMES_GATEWAY_HTTP_ID_MAX_LENGTH,
  HERMES_GATEWAY_HTTP_ID_PATTERN,
  adoptedGatewayDocId,
  assertSafeAttachmentContentType,
  legacyAttachmentContentTypeAllowed,
  requiredHttpIdentifier,
} from "./hermesGatewayHttp.js";

export {
  burnBarHermesGateway,
  dispatchHermesGatewayRequest,
  getHermesGatewayAttachmentDownloadUrl,
} from "./hermesGatewayRoutes.js";

export { handleHermesGatewayAttachmentDownloadUrl } from "./hermesGatewayAttachmentRoutes.js";

export { approveHermesGatewayDeviceGrant } from "./hermesGatewayApprove.js";

export { enqueueHermesGatewayEvent } from "./hermesGatewayEnqueue.js";

export {
  listHermesGatewayClients,
  reapHermesGatewayApprovals,
  respondHermesGatewayApproval,
  revokeHermesGatewayClient,
  rotateHermesGatewayClientToken,
  setHermesGatewayOversightMode,
} from "./hermesGatewayCallables.js";
