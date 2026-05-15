import Foundation
@preconcurrency import FirebaseAuth
import OpenBurnBarCore
import OpenBurnBarIrohRelay

/// iOS-side iroh transport. Conforms to `HermesRelayTransporting` so it
/// slots into `HermesCompositeRelayTransport` next to the existing
/// `HermesRealtimeRelayTransport` (WSS) and `FirestoreHermesRelayTransport`
/// (fallback). Picks up the Mac's NodeId from the signed
/// `iroh_pairing` Firestore record, verifies the Ed25519 signature, then
/// dials the iroh QUIC stream and serves one frame round-trip per request.
@MainActor
final class HermesIrohRelayTransport: HermesRelayTransporting {
    static let shared = HermesIrohRelayTransport()

    private let directory: any IrohPairingDirectory
    private let transportFactory: @MainActor () -> any IrohRelayTransport
    private let pairingPublicKeyProvider: any IrohPairingPublicKeyProviding
    private let auditLogger: any IrohTransportAuditLogging
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var endpoint: (any IrohRelayTransport)?
    private var identity: IrohEndpointIdentity?
    private let now: @Sendable () -> Date

    init(
        directory: any IrohPairingDirectory = FirestoreIrohPairingDirectory.shared,
        pairingPublicKeyProvider: any IrohPairingPublicKeyProviding = FirestoreIrohPairingPublicKeyProvider.shared,
        auditLogger: any IrohTransportAuditLogging = FirestoreIrohAuditLogger.shared,
        transportFactory: @escaping @MainActor () -> any IrohRelayTransport = {
            HermesIrohRelayTransport.defaultTransport()
        },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.directory = directory
        self.pairingPublicKeyProvider = pairingPublicKeyProvider
        self.auditLogger = auditLogger
        self.transportFactory = transportFactory
        self.now = now
    }

    func sendUnary(_ payload: HermesRelayPayload, timeout: TimeInterval) async throws -> Data {
        var fragments: [Int: String] = [:]
        try await send(payload, timeout: timeout) { chunk in
            switch chunk.kind {
            case .data:
                fragments[chunk.sequence] = chunk.data ?? chunk.text ?? ""
            case .error:
                throw HermesServiceError.relayUnavailable(chunk.error ?? "Hermes iroh relay failed.")
            case .sse:
                break
            }
        }
        let body = fragments
            .sorted { $0.key < $1.key }
            .map(\.value)
            .joined()
        return Data(body.utf8)
    }

    func sendStreaming(
        _ payload: HermesRelayPayload,
        timeout: TimeInterval,
        onSSEEvent: @escaping @MainActor (String) -> Void
    ) async throws {
        try await send(payload, timeout: timeout) { chunk in
            switch chunk.kind {
            case .sse:
                if let data = chunk.data ?? chunk.text, !data.isEmpty {
                    onSSEEvent(data)
                }
            case .error:
                throw HermesServiceError.relayUnavailable(chunk.error ?? "Hermes iroh relay stream failed.")
            case .data:
                break
            }
        }
    }

    private func send(
        _ payload: HermesRelayPayload,
        timeout: TimeInterval,
        onChunk: @MainActor (HermesRelayChunkRecord) throws -> Void
    ) async throws {
        guard let uid = Auth.auth().currentUser?.uid else {
            throw HermesServiceError.relayUnavailable("Iroh relay requires a signed-in Firebase user.")
        }
        guard payload.relayEncryption == HermesRelayCrypto.algorithm,
              let relayPublicKey = payload.relayPublicKey,
              !relayPublicKey.isEmpty else {
            throw HermesServiceError.relayUnavailable("Update OpenBurnBar on your Mac and re-enable Remote Relay so this iPhone/iPad can use encrypted relay traffic.")
        }

        let publicKey = try await pairingPublicKeyProvider.fetchPublicKey(uid: uid)

        // 1. Fetch + verify the Mac's signed iroh pairing record.
        let publisher = IrohPairingPublisher(directory: directory)
        let verifiedNodeId: String
        do {
            verifiedNodeId = try await publisher.fetchAndVerify(
                uid: uid,
                connectionId: payload.connectionID,
                publicKey: publicKey,
                now: now()
            )
            await auditLogger.record(
                event: .pairingVerified,
                uid: uid,
                connectionId: payload.connectionID,
                transport: nil,
                rttMillis: nil,
                detail: [:]
            )
        } catch {
            await auditLogger.record(
                event: .pairingRejected,
                uid: uid,
                connectionId: payload.connectionID,
                transport: nil,
                rttMillis: nil,
                detail: ["error": String(error.localizedDescription.prefix(256))]
            )
            throw HermesServiceError.relayUnavailable("Could not verify iroh pairing record: \(error.localizedDescription)")
        }

        // 2. Bring up the iroh endpoint (idempotent) and dial.
        let transport = try await transport()
        let stream = try await transport.connect(to: verifiedNodeId, timeout: timeout)
        defer { Task { await stream.close() } }

        let requestID = "iroh_\(UUID().uuidString.lowercased())"
        let keyData = try HermesRelayCrypto.generateSymmetricKeyData()
        let bodyString = payload.body.flatMap { String(data: $0, encoding: .utf8) }
        let encryptedPayload = HermesRelayEncryptedRequestPayload(
            path: payload.path,
            sessionId: payload.sessionID,
            body: bodyString
        )
        let plaintext = try JSONEncoder().encode(encryptedPayload)
        let requestAAD = HermesRelayCrypto.requestAAD(
            uid: uid,
            connectionID: payload.connectionID,
            requestID: requestID
        )
        let keyAAD = HermesRelayCrypto.keyAAD(
            uid: uid,
            connectionID: payload.connectionID,
            requestID: requestID
        )

        let startFrame = HermesRealtimeRelayFrame(
            type: .requestStart,
            uid: uid,
            connectionId: payload.connectionID,
            requestId: requestID,
            payload: HermesRealtimeRelayPayload(
                operation: payload.operation,
                method: payload.method,
                payloadCiphertext: try HermesRelayCrypto.sealToBase64(
                    plaintext: plaintext,
                    keyData: keyData,
                    aad: requestAAD
                ),
                wrappedKey: try HermesRelayCrypto.wrapSymmetricKey(
                    keyData,
                    recipientPublicKeyBase64: relayPublicKey,
                    aad: keyAAD
                ),
                relayEncryption: HermesRelayCrypto.algorithm,
                relayKeyVersion: payload.relayKeyVersion ?? HermesRelayCrypto.keyVersion
            )
        )
        try await stream.send(startFrame)

        let started = Date()
        let deadline = started.addingTimeInterval(timeout)
        while Date() < deadline {
            guard let frame = try await stream.receive() else {
                throw HermesServiceError.relayUnavailable("Iroh stream closed before completion.")
            }
            guard frame.uid == uid,
                  frame.connectionId == payload.connectionID,
                  frame.requestId == requestID else {
                continue
            }
            switch frame.type {
            case .responseChunk:
                guard let chunk = try chunkRecord(from: frame, keyData: keyData, uid: uid, connectionID: payload.connectionID, requestID: requestID) else { continue }
                try onChunk(chunk)
            case .responseComplete:
                let rtt = Int(Date().timeIntervalSince(started) * 1000)
                await auditLogger.record(
                    event: .streamClosed,
                    uid: uid,
                    connectionId: payload.connectionID,
                    transport: .irohDirect,
                    rttMillis: rtt,
                    detail: [:]
                )
                return
            case .responseError:
                throw HermesServiceError.relayUnavailable(frame.payload?.error ?? "Hermes iroh relay failed.")
            case .ping, .pong, .requestCancel, .requestStart, .hostReady, .hostRegister:
                continue
            }
        }
        throw HermesServiceError.relayUnavailable("Iroh relay timed out before response.complete.")
    }

    private func transport() async throws -> any IrohRelayTransport {
        if let endpoint, identity != nil { return endpoint }
        let transport = transportFactory()
        let identity = try await transport.start()
        self.endpoint = transport
        self.identity = identity
        return transport
    }

    private func chunkRecord(
        from frame: HermesRealtimeRelayFrame,
        keyData: Data,
        uid: String,
        connectionID: String,
        requestID: String
    ) throws -> HermesRelayChunkRecord? {
        guard let payload = frame.payload,
              let kind = payload.kind,
              let sequence = payload.sequence,
              let ciphertext = payload.ciphertext else {
            return nil
        }
        let plaintext = try HermesRelayCrypto.openBase64(
            ciphertext: ciphertext,
            keyData: keyData,
            aad: HermesRelayCrypto.chunkAAD(
                uid: uid,
                connectionID: connectionID,
                requestID: requestID,
                sequence: sequence,
                kind: kind.rawValue
            )
        )
        let text = String(data: plaintext, encoding: .utf8)
        return HermesRelayChunkRecord(
            sequence: sequence,
            kind: kind,
            data: text,
            text: text,
            error: nil
        )
    }

    static func defaultTransport() -> any IrohRelayTransport {
        let secretProvider: @Sendable () throws -> IrohSecretKeyMaterial = {
            try IrohRelayKeyStore.shared.secretKeyMaterial()
        }
        if let backend = OpenBurnBarIrohFFIBackendFactory.make() {
            return IrohXcframeworkTransport(backend: backend, secretProvider: secretProvider)
        }
        let rendezvous = LoopbackIrohRelayRendezvous()
        return LoopbackIrohRelayTransport(rendezvous: rendezvous)
    }
}

protocol IrohPairingPublicKeyProviding: Sendable {
    func fetchPublicKey(uid: String) async throws -> Data
}
