/** Hermes relay request/chunk Firestore contracts. */
namespace OpenBurnBar.Firestore.HermesRelay;

model HermesRelayRequestDoc {
  operation: string;
  status: string;
  sessionId?: string;
  createdAt: string;
  updatedAt?: string;
}

model HermesRelayChunkDoc {
  requestId: string;
  chunkIndex: int32;
  payloadBase64: string;
  createdAt: string;
}
