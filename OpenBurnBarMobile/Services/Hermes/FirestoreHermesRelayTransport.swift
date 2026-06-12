import Foundation
import FirebaseAppCheck
import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import OpenBurnBarCore
import OpenBurnBarComputerUseCore

@MainActor
final class FirestoreHermesRelayTransport: HermesRelayTransporting {
    static let shared = FirestoreHermesRelayTransport()

    private let injectedDB: Firestore?
    private var db: Firestore { injectedDB ?? Firestore.firestore() }
    private let pollIntervalNanoseconds: UInt64

    private struct RelayRequestHandle {
        let requestID: String
        let connectionID: String
        let keyData: Data
    }

    init(db: Firestore? = nil, pollIntervalNanoseconds: UInt64 = 250_000_000) {
        self.injectedDB = db
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
    }

    func sendUnary(_ payload: HermesRelayPayload, timeout: TimeInterval) async throws -> Data {
        let handle = try await createRelayRequest(payload, timeout: timeout)
        var fragments: [Int: String] = [:]
        do {
            try await pollRelay(
                handle: handle,
                timeout: timeout,
                onChunk: { chunk in
                    switch chunk.kind {
                    case .data:
                        fragments[chunk.sequence] = chunk.data ?? chunk.text ?? ""
                    case .error:
                        throw HermesServiceError.relayFailure(chunk.error, fallback: "Hermes relay request failed.")
                    case .sse:
                        break
                    }
                }
            )
        } catch {
            try? await cancelRelayRequest(handle.requestID)
            throw error
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
        let handle = try await createRelayRequest(payload, timeout: timeout)
        do {
            try await pollRelay(
                handle: handle,
                timeout: timeout,
                onChunk: { chunk in
                    switch chunk.kind {
                    case .sse:
                        if let data = chunk.data ?? chunk.text, !data.isEmpty {
                            onSSEEvent(data)
                        }
                    case .error:
                        throw HermesServiceError.relayFailure(chunk.error, fallback: "Hermes relay stream failed.")
                    case .data:
                        break
                    }
                }
            )
        } catch {
            try? await cancelRelayRequest(handle.requestID)
            throw error
        }
    }

    private func createRelayRequest(_ payload: HermesRelayPayload, timeout: TimeInterval) async throws -> RelayRequestHandle {
        guard FirebaseApp.app() != nil else {
            throw FirestoreError.firebaseUnavailable
        }
        guard let uid = Auth.auth().currentUser?.uid else {
            throw FirestoreError.notAuthenticated
        }
        guard payload.connectionID != HermesConnectionRecord.localDefault.id else {
            throw HermesServiceError.relayUnavailable("Select a Remote Relay Hermes connection first.")
        }
        guard payload.relayEncryption == HermesRelayCrypto.relayEncryptionV3,
              payload.relayKeyVersion == HermesRelayCrypto.gatewayRelayKeyVersionV3,
              let relayPublicKey = payload.relayPublicKey,
              !relayPublicKey.isEmpty else {
            throw HermesServiceError.relayUnavailable("Update OpenBurnBar on your Mac and re-enable Remote Relay so this iPhone/iPad can use authenticated relay traffic.")
        }
        let requestID = "relay_\(UUID().uuidString.lowercased())"
        let now = Date()
        let expiresAt = now.addingTimeInterval(max(timeout, 30))
        _ = relayPublicKey
        let sealed = try await MobileHermesAuthenticatedRelayRequestSealer.seal(
            payload: payload,
            uid: uid,
            requestID: requestID
        )
        let data: [String: Any] = [
            "id": requestID,
            "connectionId": payload.connectionID,
            "operation": payload.operation.rawValue,
            "status": HermesRelayRequestStatus.pending.rawValue,
            "method": payload.method.uppercased(),
            "payloadCiphertext": sealed.payload.payloadCiphertext ?? "",
            "enc": sealed.payload.enc ?? "",
            "wrappedKey": sealed.payload.wrappedKey ?? "",
            "relayEncryption": HermesRelayCrypto.relayEncryptionV3,
            "relayKeyVersion": HermesRelayCrypto.gatewayRelayKeyVersionV3,
            "senderPublicKey": sealed.payload.senderPublicKey ?? "",
            "senderDeviceId": sealed.payload.senderDeviceId ?? "",
            "senderPeerNodeId": sealed.payload.senderPeerNodeId ?? "",
            "senderCounter": sealed.payload.senderCounter ?? 0,
            "keyId": sealed.payload.keyId ?? "",
            "chunkCount": 0,
            "createdAt": Self.iso8601.string(from: now),
            "updatedAt": Self.iso8601.string(from: now),
            "expiresAt": Self.iso8601.string(from: expiresAt),
            "expireAt": Timestamp(date: expiresAt),
            "schemaVersion": 2
        ]
        try await requestRef(uid: uid, requestID: requestID).setData(data, merge: false)
        return RelayRequestHandle(requestID: requestID, connectionID: payload.connectionID, keyData: sealed.keyData)
    }

    private func pollRelay(
        handle: RelayRequestHandle,
        timeout: TimeInterval,
        onChunk: (HermesRelayChunkRecord) throws -> Void
    ) async throws {
        guard FirebaseApp.app() != nil else {
            throw FirestoreError.firebaseUnavailable
        }
        guard let uid = Auth.auth().currentUser?.uid else {
            throw FirestoreError.notAuthenticated
        }
        let request = requestRef(uid: uid, requestID: handle.requestID)
        let deadline = Date().addingTimeInterval(timeout)
        var lastSequence = -1
        while Date() < deadline {
            try Task.checkCancellation()

            let chunkSnapshot = try await request
                .collection("chunks")
                .whereField("sequence", isGreaterThan: lastSequence)
                .order(by: "sequence")
                .getDocuments()
            for document in chunkSnapshot.documents {
                if let chunk = decodeChunk(document.data(), docID: document.documentID) {
                    try onChunk(decryptChunkIfNeeded(chunk, uid: uid, handle: handle))
                    lastSequence = max(lastSequence, chunk.sequence)
                }
            }

            let requestSnapshot = try await request.getDocument()
            let requestData = requestSnapshot.data() ?? [:]
            guard let statusText = requestData["status"] as? String,
                  let status = HermesRelayRequestStatus(rawValue: statusText) else {
                throw HermesServiceError.relayUnavailable("Remote Hermes relay request disappeared.")
            }
            switch status {
            case .completed:
                let expectedChunkCount = requestData["chunkCount"] as? Int ?? 0
                if expectedChunkCount == 0 || lastSequence + 1 >= expectedChunkCount {
                    return
                }
                try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
            case .failed:
                let error = requestData["error"] as? String
                throw HermesServiceError.relayFailure(error, fallback: "Remote Hermes relay failed.")
            case .cancelled, .expired:
                throw HermesServiceError.relayUnavailable("Remote Hermes relay request was \(status.rawValue).")
            case .pending, .claimed, .streaming:
                try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
            }
        }
        try? await cancelRelayRequest(handle.requestID)
        throw HermesServiceError.relayTimeout
    }

    private func decryptChunkIfNeeded(
        _ chunk: HermesRelayChunkRecord,
        uid: String,
        handle: RelayRequestHandle
    ) throws -> HermesRelayChunkRecord {
        guard chunk.schemaVersion >= 2 || chunk.ciphertext != nil else {
            return chunk
        }
        guard let ciphertext = chunk.ciphertext else {
            throw HermesServiceError.relayUnavailable("Remote Hermes relay returned an encrypted chunk without ciphertext.")
        }
        let plaintext = try HermesRelayCrypto.openBase64(
            ciphertext: ciphertext,
            keyData: handle.keyData,
            aad: HermesRelayCrypto.chunkAAD(
                uid: uid,
                connectionID: handle.connectionID,
                requestID: handle.requestID,
                sequence: chunk.sequence,
                kind: chunk.kind.rawValue
            )
        )
        let text = String(data: plaintext, encoding: .utf8) ?? ""
        switch chunk.kind {
        case .error:
            return HermesRelayChunkRecord(
                id: chunk.id,
                requestId: chunk.requestId,
                sequence: chunk.sequence,
                kind: chunk.kind,
                error: text,
                schemaVersion: chunk.schemaVersion
            )
        case .data, .sse:
            return HermesRelayChunkRecord(
                id: chunk.id,
                requestId: chunk.requestId,
                sequence: chunk.sequence,
                kind: chunk.kind,
                data: text,
                schemaVersion: chunk.schemaVersion
            )
        }
    }

    private func cancelRelayRequest(_ requestID: String) async throws {
        guard FirebaseApp.app() != nil else { return }
        guard let uid = Auth.auth().currentUser?.uid else { return }
        try await requestRef(uid: uid, requestID: requestID).setData([
            "status": HermesRelayRequestStatus.cancelled.rawValue,
            "updatedAt": Self.iso8601.string(from: Date())
        ], merge: true)
    }

    private func requestRef(uid: String, requestID: String) -> DocumentReference {
        db.collection("users").document(uid).collection("hermes_relay_requests").document(requestID)
    }

    private func decodeChunk(_ data: [String: Any], docID: String) -> HermesRelayChunkRecord? {
        guard let requestID = data["requestId"] as? String,
              let sequence = data["sequence"] as? Int,
              let kindText = data["kind"] as? String,
              let kind = HermesRelayChunkKind(rawValue: kindText) else {
            return nil
        }
        return HermesRelayChunkRecord(
            id: data["id"] as? String ?? docID,
            requestId: requestID,
            sequence: sequence,
            kind: kind,
            data: data["data"] as? String,
            text: data["text"] as? String,
            error: data["error"] as? String,
            ciphertext: data["ciphertext"] as? String,
            schemaVersion: data["schemaVersion"] as? Int ?? 1
        )
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
