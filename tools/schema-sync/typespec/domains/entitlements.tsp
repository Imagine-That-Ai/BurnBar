/** Device escrow and entitlement surface contracts. */
namespace OpenBurnBar.Firestore.Entitlements;

model EscrowDeviceDoc {
  deviceId: string;
  trustState: string;
  registeredAt: string;
  approvedAt?: string;
}

model EscrowEnvelopeDoc {
  envelopeId: string;
  sourceDeviceId: string;
  targetDeviceId: string;
  ciphertext: string;
  createdAt: string;
}
