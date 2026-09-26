/**
 * @fileoverview Cross-codebase test seam for knip (media codebase).
 *
 * The admin vitest suite imports sibling `src/` modules and the .mjs
 * harnesses import compiled `lib/` output. Per-package knip analyzes only
 * this package's `src/`, so it cannot see those edges; this knip entry
 * re-exports each test-consumed module as a namespace to mark it live.
 * Every entry must stay live: `scripts/ci/verify-functions-test-seams.mjs`
 * fails on a seam with no knip-invisible importer. Production code must
 * never import from this module.
 */

export * as callablesHermesGatewayHttpTesting from "./callables/hermesGatewayHttp.js";
export * as callablesHermesGatewayRoutesTesting from "./callables/hermesGatewayRoutes.js";
export * as domainsAttachmentsBurnbarAttachmentsTesting from "./domains/attachments/burnbarAttachments.js";
export * as domainsAttachmentsReapBurnbarAttachmentsTesting from "./domains/attachments/reapBurnbarAttachments.js";
export * as domainsHermesHermesGatewayTesting from "./domains/hermes/hermesGateway.js";
export * as domainsPushApnsSenderTesting from "./domains/push/apnsSender.js";
export * as domainsPushFcmAndroidSenderTesting from "./domains/push/fcmAndroidSender.js";
export * as domainsPushLiveActivityPushTesting from "./domains/push/liveActivityPush.js";
export * as domainsRelayIrohMonitoringTesting from "./domains/relay/irohMonitoring.js";
export * as voipPushTesting from "./voipPush.js";
