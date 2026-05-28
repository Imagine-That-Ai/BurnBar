/** Pi Agent relay pairing contracts (mirrors Hermes relay shape). */
namespace OpenBurnBar.Firestore.PiAgentRelay;

model PiAgentConnectionDoc {
  mode: string;
  status: string;
  endpointURL?: string;
  createdAt: string;
  updatedAt?: string;
}

model PiAgentPairingDoc {
  pairingCodeDigest: string;
  status: string;
  expiresAt: string;
}
