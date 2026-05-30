/** Computer Use audit and phone-control Firestore contracts. */
namespace OpenBurnBar.Firestore.ComputerUse;

model ComputerUsePhoneAuthorityDoc {
  deviceId: string;
  publicKey: string;
  createdAt: string;
  revokedAt?: string;
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
