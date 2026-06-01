/**
 * @fileoverview Barrel re-export for Firestore document types and generated schema types.
 *
 * Hand-maintained legacy types remain canonical for Cloud Functions runtime code.
 * Generated schema-sync types are re-exported only where they do not collide with legacy names.
 */

export * from "./types/legacy.js";

export type {
  GeneratedProviderAccountDoc,
  GeneratedProviderAccountConnectContext,
  GeneratedProviderAccountDeviceLinkDoc,
  GeneratedModelBenchmarkSnapshotDoc,
  GeneratedModelBenchmarkSourceStatusDoc,
  GeneratedHermesGatewayAttachmentManifestDoc,
  GeneratedHermesGatewayClientDoc,
  GeneratedHermesGatewayDestinationDoc,
  GeneratedHermesGatewayEventDoc,
  GeneratedHermesGatewayMessageDoc,
  GeneratedHermesGatewayModelOptionDoc,
} from "./types/generated/index.js";
