/** iroh pairing and device-link Firestore contracts. */
namespace OpenBurnBar.Firestore.IrohPairing;

model IrohPairingDoc {
  pairingCodeDigest: string;
  status: string;
  createdAt: string;
  expiresAt: string;
  platform?: string;
}

model DeviceLinkDoc {
  deviceId: string;
  platform: string;
  linkedAt: string;
  revokedAt?: string;
}

model IrohControllerRouteDoc {
  connectionId: string;
  sourceDeviceId: string;
  transportNodeId: string;
  authorityPeerNodeId: string;
  authorityPublicKeySHA256: string;
  status: string;
  generation: int64;
  registeredAtMillis: int64;
  expiresAtMillis: int64;
  revokedAtMillis?: int64;
  schemaVersion: int64;
  updatedAt: string;
}

model IrohControllerRouteChallengeDoc {
  challengeId: string;
  challengeNonce: string;
  connectionId: string;
  sourceDeviceId: string;
  transportNodeId: string;
  authorityPeerNodeId: string;
  proofKind: string;
  expectedPriorGeneration: int64;
  expectedRegisteredAtMillis?: int64;
  registrationGeneration: int64;
  canonicalPayloadBase64: string;
  issuedAtMillis: int64;
  expiresAtMillis: int64;
  status: string;
  consumedAtMillis?: int64;
  schemaVersion: int64;
  expireAt: string;
}
