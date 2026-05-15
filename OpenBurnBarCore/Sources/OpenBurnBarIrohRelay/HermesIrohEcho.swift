import Foundation
import OpenBurnBarCore

/// The "relay.echo" path: the smallest end-to-end Hermes-shaped exchange we
/// can run over the iroh transport without touching the local Hermes
/// gateway. It exists so Milestone 1+2+3 of the migration is provably
/// shippable in isolation:
///
///   iOS encrypts payload with `HermesRelayCrypto` → sends a `request.start`
///   frame on an iroh stream → Mac decrypts → re-encrypts the echo → emits
///   `response.chunk` + `response.complete`.
///
/// Real chat completions over iroh (Milestone 4) reuses the same transport,
/// the same frame shape, and the same crypto envelope; only the body is
/// different.
public enum HermesIrohEcho {
    public static let operationToken = "relay.echo"

    public struct Request: Sendable, Equatable {
        public let uid: String
        public let connectionId: String
        public let requestId: String
        public let plaintextBody: String
        public init(uid: String, connectionId: String, requestId: String, plaintextBody: String) {
            self.uid = uid
            self.connectionId = connectionId
            self.requestId = requestId
            self.plaintextBody = plaintextBody
        }
    }

    public struct Response: Sendable, Equatable {
        public let requestId: String
        public let body: String
        public let chunkCount: Int
        public init(requestId: String, body: String, chunkCount: Int) {
            self.requestId = requestId
            self.body = body
            self.chunkCount = chunkCount
        }
    }
}

/// Client-side echo runner. Pairs with `HermesIrohEchoHost.serve` on the Mac
/// loop. Wraps the request in `HermesRealtimeRelayFrame` exactly the way the
/// existing Cloud Run relay does so the contract is identical.
public struct HermesIrohEchoClient: Sendable {
    public init() {}

    public func roundTrip(
        request: HermesIrohEcho.Request,
        on stream: any IrohRelayStream,
        recipientPublicKeyBase64: String
    ) async throws -> HermesIrohEcho.Response {
        let symmetricKey = try HermesRelayCrypto.generateSymmetricKeyData()
        let keyAAD = HermesRelayCrypto.keyAAD(
            uid: request.uid,
            connectionID: request.connectionId,
            requestID: request.requestId
        )
        let wrappedKey = try HermesRelayCrypto.wrapSymmetricKey(
            symmetricKey,
            recipientPublicKeyBase64: recipientPublicKeyBase64,
            aad: keyAAD
        )
        let requestAAD = HermesRelayCrypto.requestAAD(
            uid: request.uid,
            connectionID: request.connectionId,
            requestID: request.requestId
        )
        let envelope = HermesRelayEncryptedRequestPayload(
            path: HermesIrohEcho.operationToken,
            body: request.plaintextBody
        )
        let envelopeData = try JSONEncoder().encode(envelope)
        let ciphertext = try HermesRelayCrypto.sealToBase64(
            plaintext: envelopeData,
            keyData: symmetricKey,
            aad: requestAAD
        )

        let startFrame = HermesRealtimeRelayFrame(
            type: .requestStart,
            uid: request.uid,
            connectionId: request.connectionId,
            requestId: request.requestId,
            payload: HermesRealtimeRelayPayload(
                operation: nil, // echo is a private operation, not one of the public Hermes ops
                method: "POST",
                payloadCiphertext: ciphertext,
                wrappedKey: wrappedKey,
                relayEncryption: HermesRelayCrypto.algorithm,
                relayKeyVersion: HermesRelayCrypto.keyVersion
            )
        )
        try await stream.send(startFrame)

        var fragments: [Int: String] = [:]
        var chunkCount = 0
        loop: while let frame = try await stream.receive() {
            switch frame.type {
            case .responseChunk:
                guard let payload = frame.payload,
                      let sequence = payload.sequence,
                      let kind = payload.kind,
                      let ciphertext = payload.ciphertext else {
                    throw IrohRelayTransportError.decodeFailed("malformed response chunk")
                }
                let chunkAAD = HermesRelayCrypto.chunkAAD(
                    uid: request.uid,
                    connectionID: request.connectionId,
                    requestID: request.requestId,
                    sequence: sequence,
                    kind: kind.rawValue
                )
                let plaintext = try HermesRelayCrypto.openBase64(
                    ciphertext: ciphertext,
                    keyData: symmetricKey,
                    aad: chunkAAD
                )
                fragments[sequence] = String(data: plaintext, encoding: .utf8) ?? ""
            case .responseComplete:
                chunkCount = frame.payload?.chunkCount ?? fragments.count
                break loop
            case .responseError:
                throw IrohRelayTransportError.streamRejected(frame.payload?.error ?? "relay echo failed")
            default:
                continue
            }
        }

        let body = fragments
            .sorted { $0.key < $1.key }
            .map(\.value)
            .joined()
        return HermesIrohEcho.Response(requestId: request.requestId, body: body, chunkCount: chunkCount)
    }
}

/// Host-side echo runner. Lives on the Mac, served from one accepted stream.
/// Real Hermes chat completions reuse this loop pattern with the addition of
/// SSE pass-through and the upstream HTTP call.
public struct HermesIrohEchoHost: Sendable {
    private let privateKey: HermesRelayPrivateKey

    public init(privateKey: HermesRelayPrivateKey) {
        self.privateKey = privateKey
    }

    public func serve(on stream: any IrohRelayStream) async throws {
        while let frame = try await stream.receive() {
            guard frame.type == .requestStart,
                  let payload = frame.payload,
                  let ciphertext = payload.payloadCiphertext,
                  let wrappedKey = payload.wrappedKey,
                  payload.relayEncryption == HermesRelayCrypto.algorithm,
                  let requestId = frame.requestId else {
                continue
            }
            let symmetricKey = try HermesRelayCrypto.unwrapSymmetricKey(
                wrappedKey,
                privateKey: privateKey,
                aad: HermesRelayCrypto.keyAAD(
                    uid: frame.uid,
                    connectionID: frame.connectionId,
                    requestID: requestId
                )
            )
            let plaintext = try HermesRelayCrypto.openBase64(
                ciphertext: ciphertext,
                keyData: symmetricKey,
                aad: HermesRelayCrypto.requestAAD(
                    uid: frame.uid,
                    connectionID: frame.connectionId,
                    requestID: requestId
                )
            )
            let envelope = try JSONDecoder().decode(HermesRelayEncryptedRequestPayload.self, from: plaintext)
            let body = envelope.body ?? ""

            // Single-chunk echo response.
            let chunkAAD = HermesRelayCrypto.chunkAAD(
                uid: frame.uid,
                connectionID: frame.connectionId,
                requestID: requestId,
                sequence: 0,
                kind: HermesRelayChunkKind.data.rawValue
            )
            let chunkCiphertext = try HermesRelayCrypto.sealToBase64(
                plaintext: Data(body.utf8),
                keyData: symmetricKey,
                aad: chunkAAD
            )
            let chunkFrame = HermesRealtimeRelayFrame(
                type: .responseChunk,
                uid: frame.uid,
                connectionId: frame.connectionId,
                requestId: requestId,
                payload: HermesRealtimeRelayPayload(
                    sequence: 0,
                    kind: .data,
                    ciphertext: chunkCiphertext
                )
            )
            try await stream.send(chunkFrame)

            let completeFrame = HermesRealtimeRelayFrame(
                type: .responseComplete,
                uid: frame.uid,
                connectionId: frame.connectionId,
                requestId: requestId,
                payload: HermesRealtimeRelayPayload(chunkCount: 1)
            )
            try await stream.send(completeFrame)
            return
        }
    }
}
