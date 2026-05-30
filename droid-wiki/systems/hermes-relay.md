# Hermes realtime relay

Node.js WebSocket relay service for real-time agent-to-device streaming: screen share frames, audio datagrams, control events, and Agent Watch frames.

**Location:** `services/hermes-realtime-relay/`  
**Also see:** `services/hosted-mcp/` (related hosted MCP package)

## Service structure

```
services/hermes-realtime-relay/
  src/          TypeScript source
  lib/          Compiled output
  Dockerfile    Container packaging
  package.json  Dependencies and start script
  tsconfig.json
```

## Protocol

Frames travel over the iroh `openburnbar/1` ALPN channel as a `HermesRealtimeRelayFrame` JSON envelope with a big-endian u32 length prefix.

```
[u32 length][HermesRealtimeRelayFrame JSON]
```

All frames carry an Ed25519 signature from the originating device. The relay validates signatures using the public key registered during the pairing flow.

## Ed25519 pairing flow

1. Initiating device calls `createHermesPairing` Cloud Function — generates a pairing code and registers a Firestore pairing document.
2. Target device reads the pairing document and calls `completeHermesPairing` — both sides exchange Ed25519 public keys.
3. Subsequent relay frames are signed by the sender and verified by the receiver. The relay itself does not terminate TLS — it proxies authenticated frames between paired endpoints.

Public keys are stored in:
- `AgentLens/Services/IrohRelay/IrohPairingKeyStore.swift` (macOS)
- `AgentLens/Services/IrohRelay/IrohRelayKeyStore.swift` (macOS, relay key management)
- Firestore: `hermes_pairings/{pairingId}`

## iOS client

**File:** `AgentLens/Services/IrohRelay/HermesIrohRelayHostClient.swift` (~24KB)

Manages the iroh endpoint lifecycle, frame dispatch queue, and reconnect backoff on the macOS side.

## macOS relay files

| File | Purpose |
|---|---|
| `HermesIrohRelayHostClient.swift` | Host-side client: endpoint, dispatch, reconnect |
| `HermesRelayHostFanout.swift` | Fan-out relay frames to multiple connected devices |
| `IrohRelayRequestHandler.swift` | ~53KB request handler for incoming relay frames |
| `IrohRelayKeyStore.swift` | Persistent relay key storage |
| `IrohPairingKeyStore.swift` | Per-pairing key storage |
| `IrohPairingPublicKeyPublisher.swift` | Publishes local public key to Firestore pairing doc |
| `FirestoreIrohPairingDirectory.swift` | Reads/writes pairing records in Firestore |
| `IrohTransportAuditLogger.swift` | Appends transport events to the Computer Use audit chain |

## Frame types

Frame type definitions live in `OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/HermesRealtimeRelayTypes.swift` (~99KB). This is the canonical reference for all frame variants — video, audio, control, cursor metadata, Agent Watch, Computer Use approval, etc.

## Relationship to iroh transport

The relay service does not own the QUIC transport. It runs on top of the iroh endpoint managed by `HermesIrohRelayHostClient`. See [iroh transport](iroh-transport.md) for the underlying P2P layer.
