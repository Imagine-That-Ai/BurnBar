import { FieldValue } from "firebase-admin/firestore";
import { HttpsError } from "firebase-functions/v2/https";

import { logInfo } from "../logging.js";
import { sameGatewaySignalIdentity } from "../hermesGatewaySignalPrekeys.js";
import type { HermesGatewayRelayEnvelopeCapabilities } from "../hermesGatewayEnvelope.js";
import type {
  HermesGatewayClientDoc,
  HermesGatewaySignalPrekeyBundleDoc,
} from "../types/generated/hermes-gateway.js";
import {
  type ParsedRatchetPrekeyBundle,
  type ParsedRelayPublicKey,
} from "./hermesGatewayCrypto.js";

function stripUndefinedObject(value: Record<string, unknown>): Record<string, unknown> {
  return Object.fromEntries(Object.entries(value).filter(([, item]) => item !== undefined));
}

/** Permit public one-time prekey refreshes only under the pairing's identity pin. */
export function resolveRuntimeSignalPrekeyWrite(
  requested: HermesGatewaySignalPrekeyBundleDoc | undefined,
  pinned: HermesGatewaySignalPrekeyBundleDoc | undefined,
  client: HermesGatewayClientDoc,
  uid: string,
): HermesGatewaySignalPrekeyBundleDoc | undefined {
  if (!requested) return undefined;
  if (!pinned || sameGatewaySignalIdentity(pinned, requested)) return requested;
  logInfo({
    event: "hermes_gateway.signal_identity_change_rejected",
    reason: "agent_signal_identity_immutable",
    client_id: client.id,
    user_id_hash: uid.slice(0, 8),
  });
  throw new HttpsError(
    "failed-precondition",
    "agent_signal_identity_immutable: rotate the Signal identity only by explicitly re-pairing this client.",
  );
}

type RuntimePersistInput = {
  runtimeModelId: string | undefined;
  runtimeProviderId: string | undefined;
  runtimeModelOptions: unknown[];
  agentVersion: string | undefined;
  agentRelayKeyWrite: ParsedRelayPublicKey | undefined;
  agentCapabilities: HermesGatewayRelayEnvelopeCapabilities | undefined;
  negotiatedCapabilities: HermesGatewayRelayEnvelopeCapabilities | undefined;
  agentRatchetWrite: ParsedRatchetPrekeyBundle | undefined;
  agentSignalPrekeyBundleWrite: HermesGatewaySignalPrekeyBundleDoc | undefined;
  supportsRatchetV1: boolean | undefined;
  relayCapable: boolean | undefined;
  settled: boolean;
  now: string;
};

/** Assemble the merge payload persisted by /runtime. A pure builder. */
export function buildRuntimePersistDoc(input: RuntimePersistInput): Record<string, unknown> {
  return stripUndefinedObject({
    runtimeModelId: input.runtimeModelId,
    runtimeProviderId: input.runtimeProviderId,
    runtimeModelOptions: input.runtimeModelOptions,
    agentVersion: input.agentVersion,
    agentRelayPublicKey: input.agentRelayKeyWrite?.publicKey,
    agentRelayKeyVersion: input.agentRelayKeyWrite?.keyVersion,
    agentRelayEncryption: input.agentRelayKeyWrite?.encryption,
    agentSupportsRelayEnvelopeVersions: input.agentCapabilities?.supportsRelayEnvelopeVersions,
    agentPreferredRelayEnvelopeVersion: input.agentCapabilities?.preferredRelayEnvelopeVersion,
    agentSupportsHpkeV3: input.agentCapabilities?.supportsHpkeV3,
    agentSupportsSignalEnvelope: input.agentCapabilities?.supportsSignalEnvelope,
    agentSignalPrekeyBundle: input.agentSignalPrekeyBundleWrite,
    agentPlatform: input.agentCapabilities?.platform,
    agentAppBuild: input.agentCapabilities?.appBuild,
    supportsRelayEnvelopeVersions: input.negotiatedCapabilities?.supportsRelayEnvelopeVersions,
    preferredRelayEnvelopeVersion: input.negotiatedCapabilities?.preferredRelayEnvelopeVersion,
    supportsHpkeV3: input.negotiatedCapabilities?.supportsHpkeV3,
    supportsSignalEnvelope: input.negotiatedCapabilities?.supportsSignalEnvelope,
    agentRatchetIdentityPublicKey: input.agentRatchetWrite?.identityPublicKey,
    agentRatchetSigningPublicKey: input.agentRatchetWrite?.signingPublicKey,
    agentRatchetSignedPreKeyPublicKey: input.agentRatchetWrite?.signedPreKeyPublicKey,
    agentRatchetSignedPreKeyId: input.agentRatchetWrite?.signedPreKeyId,
    agentRatchetSignedPreKeySignature: input.agentRatchetWrite?.signedPreKeySignature,
    agentSupportsRatchetV1: input.agentRatchetWrite?.supportsRatchetV1,
    supportsRatchetV1: input.supportsRatchetV1,
    relayCapable: input.relayCapable,
    runtimeUpdatedAt: input.now,
    lastSeenAt: input.now,
    updatedAt: input.now,
    pendingModelId: input.settled ? FieldValue.delete() : undefined,
    pendingModelRequestedAt: input.settled ? FieldValue.delete() : undefined,
    schemaVersion: 4,
  });
}
