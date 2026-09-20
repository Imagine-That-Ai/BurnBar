/** Daemon Unix-socket RPC envelope. Source of truth for BurnBarRPCContracts. */
namespace OpenBurnBar.Daemon.RPC;

model RpcEnvelope {
  protocolVersion: int32;
  method: string;
  requestId: string;
  payloadJson?: string;
}

model RpcNegotiateRequest {
  clientSupportedVersions: int32[];
}

model RpcNegotiateResponse {
  selectedVersion: int32;
}

/** v1 remains in `supported` for N-1. v2 is current. */
enum RpcProtocolVersion {
  v1: 1,
  v2: 2,
}
