/** Computer Use audit, relay sender, grant, and phone-control Firestore contracts. */
namespace OpenBurnBar.Firestore.ComputerUse;

model ComputerUsePhoneAuthorityDoc {
  deviceId: string;
  connectionId: string;
  peerNodeId: string;
  publicKeyBase64: string;
  publishedAtMillis: int64;
  protocolVersion: int32;
  schemaVersion: int32;
  createdAt: string;
  updatedAt: string;
}

model RelaySenderKeyDoc {
  id: string;
  deviceId: string;
  peerNodeId: string;
  keyId: string;
  publicKeyBase64: string;
  relayKeyVersion: int32;
  relayEncryption: string;
  signalIdentityKeyVersion: int32;
  signalIdentityFingerprint: string;
  signalIdentityVerification: "verified";
  status: "active" | "revoked";
  publishedAtMillis: int64;
  createdAt: string;
  updatedAt: string;
  schemaVersion: int32;
}

model AgentGrantAuthorityDoc {
  id: string;
  deviceId: string;
  peerNodeId: string;
  publicKeyBase64: string;
  authorityKind: "agent_capability_grant";
  status: "active" | "revoked";
  publishedAtMillis: int64;
  createdAt: string;
  updatedAt: string;
  schemaVersion: int32;
}

model ComputerUseAuditExportSignerPublicKeyDoc {
  signerIdentifier: string;
  publicKey: string;
  trustRoot: string;
  createdAt: string;
}

/** Short-lived capability token for privileged input leaves (Remote Unlock / Computer Use). */
model CapabilityToken {
  schemaVersion: int32;
  domain: "remote_unlock" | "computer_use";
  nonce: string;
  issuedAt: string;
  expiresAt: string;
  allowedActionKinds: string[];
  scopeHash: string;
  actionBudget: int32;
  boundEscrowDeviceId?: string;
  attestationHashBlake3?: string;
  signatureEd25519Base64?: string;
}
