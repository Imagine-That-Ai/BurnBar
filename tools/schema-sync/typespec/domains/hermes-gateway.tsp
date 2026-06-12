/**
 * Hermes Gateway platform adapter Firestore contracts.
 *
 * Canonical with the Cloud Functions runtime registry
 * (functions/src/hermesGateway.ts) and, for the signal-envelope sub-models,
 * with @openburnbar/signal-envelope-contracts. The emitted TypeScript
 * (functions/src/types/generated/hermes-gateway.ts) is pinned to both by
 * tools/schema-sync/check-tsp-canon.mjs (tsp <-> emitted TS) and by the
 * compile-time Equals assertions in functions/src/types/generatedParity.ts
 * (emitted TS <-> runtime types).
 */
namespace OpenBurnBar.Firestore.HermesGateway;

alias HermesGatewayScope = "hermes.gateway.read" | "hermes.gateway.write" | "hermes.gateway.manage";
alias HermesGatewayClientStatus = "active" | "revoked";
alias HermesGatewayDestinationKind = "home" | "chat" | "thread";
alias HermesGatewayEventKind = "message" | "model_switch";
alias HermesGatewayMessageKind = "agent_message" | "typing";
alias HermesGatewayAttachmentStatus = "pending_upload" | "uploaded" | "failed" | "expired" | "rejected";
alias HermesGatewayOversightMode = "supervised" | "autonomous";
alias HermesGatewayApprovalStatus = "waiting_for_approval" | "approved" | "rejected" | "expired";
alias GatewaySignalEnvelopeMode = "transport" | "at-rest";
alias GatewaySignalEnvelopeScope = "gateway" | "cloudvault";
alias GatewaySignalRecipientKind = "device" | "escrow" | "recovery";
alias GatewaySignalTransportScheme = "signal-doubleratchet-pqxdh-v1";
alias GatewaySignalAtRestScheme = "signal-hpke-identity-seal-v1";

model HermesGatewayModelOptionDoc {
  providerId: string;
  providerName: string;
  modelId: string;
  displayName: string;
}

model GatewayRelayEnvelopeDoc {
  payloadCiphertext: string;
  wrappedKey: string;
  relayEncryption: string;
  relayKeyVersion: int32;
  enc?: string;
  senderPublicKey?: string;
}

model GatewayRatchetHeaderDoc {
  version: int32;
  algorithm: string;
  sessionID: string;
  senderDeviceID: string;
  receiverDeviceID: string;
  ratchetPublicKeyBase64: string;
  previousChainLength: int32;
  messageNumber: int32;
  epoch: int32;
}

model GatewayRatchetEnvelopeDoc {
  header: GatewayRatchetHeaderDoc;
  ciphertextBase64: string;
}

model GatewaySignalCiphertextLayerDoc {
  payloadCiphertextB64: string;
  payloadAADLabel: string;
  schemaVersion: int32;
}

model GatewaySignalBindingDoc {
  uid: string;
  scope: GatewaySignalEnvelopeScope;
  clientId?: string;
  collection?: string;
  docId?: string;
  field?: string;
  slotId?: string;
  mode: GatewaySignalEnvelopeMode;
  formatVersion: int32;
}

model GatewaySignalAtRestWrapDoc {
  recipientKind: GatewaySignalRecipientKind;
  recipientIdentityKeyId: string;
  recipientIdentityKeyB64: string;
  sealedContentKeyB64: string;
}

model GatewaySignalTransportKeyDeliveryDoc {
  scheme: GatewaySignalTransportScheme;
  signalMessageType: 2 | 3;
  signalMessageB64: string;
  senderIdentityKeyId: string;
  ratchetEpochHint?: int32;
}

model GatewaySignalAtRestKeyDeliveryDoc {
  scheme: GatewaySignalAtRestScheme;
  wraps: GatewaySignalAtRestWrapDoc[];
  contentKeyLength: 32;
}

model GatewaySignalEnvelopeDoc {
  signalEnvelopeFormatVersion: int32;
  mode: GatewaySignalEnvelopeMode;
  relayKeyVersion?: int32;
  relayEncryption: GatewaySignalTransportScheme | GatewaySignalAtRestScheme;
  ciphertextLayer: GatewaySignalCiphertextLayerDoc;
  keyDelivery: GatewaySignalTransportKeyDeliveryDoc | GatewaySignalAtRestKeyDeliveryDoc;
  binding: GatewaySignalBindingDoc;
}

model HermesGatewayClientDoc {
  id: string;
  uid: string;
  displayName: string;
  status: HermesGatewayClientStatus;
  tokenHash: string;
  tokenPreview: string;
  agentClientSigningPublicKeyBase64?: string;
  agentClientSigningKeyId?: string;
  popRequired?: boolean;
  popVersion?: int32;
  scopes: HermesGatewayScope[];
  homeDestinationId: string;
  expiresAt?: string;
  rotatedAt?: string;
  lastSeenAt?: string;
  agentRelayPublicKey?: string;
  agentRelayKeyVersion?: int32;
  agentRelayEncryption?: string;
  agentSupportsRelayEnvelopeVersions?: int32[];
  agentPreferredRelayEnvelopeVersion?: int32;
  agentSupportsHpkeV3?: boolean;
  agentSupportsSignalEnvelope?: boolean;
  agentPlatform?: string;
  agentAppBuild?: string;
  phoneRelayPublicKey?: string;
  phoneRelayKeyVersion?: int32;
  phoneRelayEncryption?: string;
  phoneSupportsRelayEnvelopeVersions?: int32[];
  phonePreferredRelayEnvelopeVersion?: int32;
  phoneSupportsHpkeV3?: boolean;
  phoneSupportsSignalEnvelope?: boolean;
  phonePlatform?: string;
  phoneAppBuild?: string;
  agentRatchetIdentityPublicKey?: string;
  agentRatchetSigningPublicKey?: string;
  agentRatchetSignedPreKeyPublicKey?: string;
  agentRatchetSignedPreKeyId?: string;
  agentRatchetSignedPreKeySignature?: string;
  agentSupportsRatchetV1?: boolean;
  phoneRatchetIdentityPublicKey?: string;
  phoneRatchetSigningPublicKey?: string;
  phoneRatchetSignedPreKeyPublicKey?: string;
  phoneRatchetSignedPreKeyId?: string;
  phoneRatchetSignedPreKeySignature?: string;
  phoneSupportsRatchetV1?: boolean;
  supportsRatchetV1?: boolean;
  supportsRelayEnvelopeVersions?: int32[];
  preferredRelayEnvelopeVersion?: int32;
  supportsHpkeV3?: boolean;
  supportsSignalEnvelope?: boolean;
  relayCapable?: boolean;
  runtimeModelId?: string;
  runtimeProviderId?: string;
  runtimeModelOptions?: HermesGatewayModelOptionDoc[];
  runtimeUpdatedAt?: string;
  agentVersion?: string;
  pendingModelId?: string;
  pendingModelRequestedAt?: string;
  oversightMode?: HermesGatewayOversightMode;
  revokedAt?: string;
  createdAt: string;
  updatedAt: string;
  schemaVersion: int32;
}

model HermesGatewayApprovalDoc {
  id: string;
  clientId: string;
  destinationId: string;
  actionId: string;
  toolName?: string;
  summary: string;
  status: HermesGatewayApprovalStatus;
  requestedAt: string;
  expiresAt: string;
  respondedAt?: string;
  approvedByDeviceId?: string;
  schemaVersion: int32;
}

model HermesGatewayDestinationDoc {
  id: string;
  displayName: string;
  kind: HermesGatewayDestinationKind;
  status: "active" | "archived";
  isDefault: boolean;
  createdAt: string;
  updatedAt: string;
  schemaVersion: int32;
}

model HermesGatewayEventDoc {
  id: string;
  sequence: int32;
  kind: HermesGatewayEventKind;
  destinationId: string;
  targetClientId?: string;
  threadId?: string;
  senderId: string;
  senderDisplayName?: string;
  text?: string;
  modelId?: string;
  attachmentIds: string[];
  relayEnvelope?: GatewayRelayEnvelopeDoc;
  ratchetEnvelope?: GatewayRatchetEnvelopeDoc;
  signalEnvelope?: GatewaySignalEnvelopeDoc;
  createdAt: string;
  schemaVersion: int32;
}

model HermesGatewayMessageDoc {
  id: string;
  clientId: string;
  kind: HermesGatewayMessageKind;
  destinationId: string;
  threadId?: string;
  replyToEventId?: string;
  text?: string;
  relayEnvelope?: GatewayRelayEnvelopeDoc;
  ratchetEnvelope?: GatewayRatchetEnvelopeDoc;
  signalEnvelope?: GatewaySignalEnvelopeDoc;
  attachmentIds: string[];
  createdAt: string;
  schemaVersion: int32;
}

model HermesGatewayAttachmentManifestDoc {
  id: string;
  clientId: string;
  destinationId?: string;
  fileName?: string;
  contentType: string;
  byteCount: int32;
  storagePath: string;
  status: HermesGatewayAttachmentStatus;
  relayEnvelope?: GatewayRelayEnvelopeDoc;
  ratchetEnvelope?: GatewayRatchetEnvelopeDoc;
  signalEnvelope?: GatewaySignalEnvelopeDoc;
  createdAt: string;
  updatedAt?: string;
  expiresAt: string;
  uploadedAt?: string;
  finalizedAt?: string;
  sha256?: string;
  storageGeneration?: string;
  schemaVersion: int32;
}
