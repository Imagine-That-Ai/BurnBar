/** Hermes Gateway platform adapter Firestore contracts. */
namespace OpenBurnBar.Firestore.HermesGateway;

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
  revokedAt?: string;
  createdAt: string;
  updatedAt: string;
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
  threadId?: string;
  senderId: string;
  senderDisplayName?: string;
  text: string;
  attachmentIds: string[];
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
  createdAt: string;
  schemaVersion: int32;
}

model HermesGatewayAttachmentManifestDoc {
  id: string;
  clientId: string;
  destinationId?: string;
  fileName: string;
  contentType: string;
  byteCount: int32;
  storagePath: string;
  status: string;
  createdAt: string;
  expiresAt: string;
  schemaVersion: int32;
}
