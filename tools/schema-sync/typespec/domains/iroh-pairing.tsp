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
