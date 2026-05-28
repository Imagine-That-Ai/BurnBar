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
