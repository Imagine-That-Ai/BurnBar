/** Hermes Gateway platform adapter Firestore contracts. */
namespace OpenBurnBar.Firestore.HermesGateway;

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

model HermesGatewayClientDoc {
  id: string;
  uid: string;
  displayName: string;
  status: string;
  tokenHash: string;
  tokenPreview: string;
  scopes: string[];
  homeDestinationId: string;
  lastSeenAt?: string;
  runtimeModelId?: string;
  runtimeProviderId?: string;
  runtimeModelOptions?: HermesGatewayModelOptionDoc[];
  runtimeUpdatedAt?: string;
  agentVersion?: string;
  pendingModelId?: string;
  pendingModelRequestedAt?: string;
  oversightMode?: string;
  relayPublicKey?: string;
  relayKeyVersion?: int32;
  relayEncryption?: string;
  agentRelayPublicKey?: string;
  agentRelayKeyVersion?: int32;
  agentRelayEncryption?: string;
  agentSupportsRelayEnvelopeVersions?: int32[];
  agentPreferredRelayEnvelopeVersion?: int32;
  agentSupportsHpkeV3?: boolean;
  agentPlatform?: string;
  agentAppBuild?: string;
  phoneRelayPublicKey?: string;
  phoneRelayKeyVersion?: int32;
  phoneRelayEncryption?: string;
  phoneSupportsRelayEnvelopeVersions?: int32[];
  phonePreferredRelayEnvelopeVersion?: int32;
  phoneSupportsHpkeV3?: boolean;
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
  relayCapable?: boolean;
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
  status: string;
  requestedAt: string;
  expiresAt: string;
  respondedAt?: string;
  approvedByDeviceId?: string;
  schemaVersion: int32;
}

model HermesGatewayDestinationDoc {
  id: string;
  displayName: string;
  kind: string;
  status: string;
  isDefault: boolean;
  createdAt: string;
  updatedAt: string;
  schemaVersion: int32;
}

model HermesGatewayEventDoc {
  id: string;
  sequence: int32;
  kind: string;
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
  createdAt: string;
  schemaVersion: int32;
}

model HermesGatewayMessageDoc {
  id: string;
  clientId: string;
  kind: string;
  destinationId: string;
  threadId?: string;
  replyToEventId?: string;
  text?: string;
  attachmentIds: string[];
  relayEnvelope?: GatewayRelayEnvelopeDoc;
  ratchetEnvelope?: GatewayRatchetEnvelopeDoc;
  createdAt: string;
  schemaVersion: int32;
}

model HermesGatewayAttachmentManifestDoc {
  id: string;
  clientId: string;
  destinationId?: string;
  fileName?: string;
  contentType?: string;
  byteCount?: int32;
  storagePath?: string;
  bodyStoragePath?: string;
  status?: string;
  relayEnvelope?: GatewayRelayEnvelopeDoc;
  ratchetEnvelope?: GatewayRatchetEnvelopeDoc;
  createdAt: string;
  expiresAt: string;
  schemaVersion: int32;
}
