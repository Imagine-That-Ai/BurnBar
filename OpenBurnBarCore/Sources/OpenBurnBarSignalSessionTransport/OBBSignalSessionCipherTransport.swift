import Foundation
import LibSignalClient
import OpenBurnBarCore
import OpenBurnBarFirestoreModels
import OpenBurnBarIrohRelay
@_exported import OpenBurnBarSignalCore

public struct OBBSignalSessionReceivedMessage: Equatable, Sendable {
    public let frame: HermesRealtimeRelayFrame
    public let plaintext: Data
    public let messageType: Int

    public init(frame: HermesRealtimeRelayFrame, plaintext: Data, messageType: Int) {
        self.frame = frame
        self.plaintext = plaintext
        self.messageType = messageType
    }
}

public struct OBBSignalGatewayEnvelopeContext: Equatable, Sendable {
    public let uid: String
    public let clientId: String
    public let slotId: String

    public init(uid: String, clientId: String, slotId: String) {
        self.uid = uid
        self.clientId = clientId
        self.slotId = slotId
    }
}

/// Drives one peer's side of an end-to-end-encrypted Signal session over an iroh
/// relay stream. Actor-isolated so the libsignal Double Ratchet state (`store`)
/// is mutated under compiler-enforced serialization — out-of-order
/// `establishOutbound`/`send`/`receive`/`decrypt` calls on one session, which
/// would corrupt forward secrecy and replay protection, are impossible.
public actor OBBSignalSessionCipherTransport {
    public typealias ClaimSignalPreKeyBundle = @Sendable () async throws -> OBBSignalClaimedPreKeyBundle

    private let store: OBBSignalProtocolStore
    private let localAddress: ProtocolAddress

    public init(store: sending OBBSignalProtocolStore, localAddress: ProtocolAddress) {
        self.store = store
        self.localAddress = localAddress
    }

    @discardableResult
    public func establishOutbound(
        claimSignalPrekeyBundle: ClaimSignalPreKeyBundle,
        plaintext: Data,
        on stream: any IrohRelayStream,
        uid: String,
        connectionId: String,
        requestId: String? = nil,
        pinnedIdentityPublicKey: Data? = nil,
        context: StoreContext = NullContext()
    ) async throws -> HermesRealtimeRelayFrame {
        let claimed = try await claimSignalPrekeyBundle()
        // F6: gate the server-supplied bundle on the out-of-band identity pin
        // before any session state is created. The store's `identityTrustEvaluator`
        // is the second, always-on gate that also covers the inbound path.
        let remote = try OBBSignalRemoteBundleDecoder.decode(claimed, pinnedIdentityPublicKey: pinnedIdentityPublicKey)
        try processPreKeyBundle(
            remote.bundle,
            for: remote.address,
            ourAddress: localAddress,
            sessionStore: store,
            identityStore: store,
            context: context
        )
        return try await send(
            plaintext,
            to: remote.address,
            on: stream,
            uid: uid,
            connectionId: connectionId,
            requestId: requestId,
            context: context
        )
    }

    @discardableResult
    public func send(
        _ plaintext: Data,
        to remoteAddress: ProtocolAddress,
        on stream: any IrohRelayStream,
        uid: String,
        connectionId: String,
        requestId: String? = nil,
        context: StoreContext = NullContext()
    ) async throws -> HermesRealtimeRelayFrame {
        let ciphertext = try signalEncrypt(
            message: Array(plaintext),
            for: remoteAddress,
            localAddress: localAddress,
            sessionStore: store,
            identityStore: store,
            context: context
        )
        let frame = Self.frame(
            for: ciphertext,
            uid: uid,
            connectionId: connectionId,
            requestId: requestId
        )
        try await stream.send(frame)
        return frame
    }

    /// Establish or reuse the official libsignal session and return a Gateway
    /// v4 transport envelope without touching a relay stream. Callers must
    /// persist the returned session state through `store`.
    public func sealGatewayEnvelope(
        _ plaintext: Data,
        context envelopeContext: OBBSignalGatewayEnvelopeContext,
        claimSignalPrekeyBundle: ClaimSignalPreKeyBundle,
        pinnedIdentityPublicKey: Data? = nil,
        remoteAddress: ProtocolAddress? = nil,
        storeContext: StoreContext = NullContext()
    ) async throws -> FirestoreGatewaySignalEnvelopeDoc {
        let address: ProtocolAddress
        if let remoteAddress {
            address = remoteAddress
        } else {
            let claimed = try await claimSignalPrekeyBundle()
            let remote = try OBBSignalRemoteBundleDecoder.decode(
                claimed,
                pinnedIdentityPublicKey: pinnedIdentityPublicKey
            )
            try processPreKeyBundle(
                remote.bundle,
                for: remote.address,
                ourAddress: localAddress,
                sessionStore: store,
                identityStore: store,
                context: storeContext
            )
            address = remote.address
        }
        let ciphertext = try signalEncrypt(
            message: Array(plaintext),
            for: address,
            localAddress: localAddress,
            sessionStore: store,
            identityStore: store,
            context: storeContext
        )
        let ciphertextB64 = ciphertext.serialize().base64EncodedString()
        let senderIdentityKeyId = SHA256.hash(data: store.identityKeypair.publicKey.serialize())
            .prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
        return FirestoreGatewaySignalEnvelopeDoc(
            signalEnvelopeFormatVersion: 1,
            mode: "transport",
            relayKeyVersion: HermesRelayCrypto.gatewayRelayKeyVersionSignalV4,
            relayEncryption: "signal-doubleratchet-pqxdh-v1",
            ciphertextLayer: FirestoreGatewaySignalCiphertextLayerDoc(
                payloadCiphertextB64: ciphertextB64,
                payloadAADLabel: "gateway-v4-signal",
                schemaVersion: 1
            ),
            keyDelivery: FirestoreGatewaySignalKeyDeliveryDoc(
                scheme: "signal-doubleratchet-pqxdh-v1",
                signalMessageType: Int(ciphertext.messageType.rawValue),
                signalMessageB64: ciphertextB64,
                senderIdentityKeyId: senderIdentityKeyId,
                ratchetEpochHint: nil,
                wraps: nil,
                contentKeyLength: nil
            ),
            binding: FirestoreGatewaySignalBindingDoc(
                uid: envelopeContext.uid,
                scope: "gateway",
                clientId: envelopeContext.clientId,
                collection: nil,
                docId: nil,
                field: nil,
                slotId: envelopeContext.slotId,
                mode: "transport",
                formatVersion: 1
            ),
            senderAuth: nil
        )
    }

    /// Decode a Gateway v4 envelope through the same official session actor.
    public func decryptGatewayEnvelope(
        _ envelope: FirestoreGatewaySignalEnvelopeDoc,
        from remoteAddress: ProtocolAddress,
        context: StoreContext = NullContext()
    ) throws -> Data {
        guard
            let messageType = envelope.keyDelivery.signalMessageType,
            let ciphertextB64 = envelope.keyDelivery.signalMessageB64,
            let ciphertext = Data(base64Encoded: ciphertextB64),
            envelope.mode == "transport",
            envelope.binding.scope == "gateway"
        else { throw OBBSignalSessionTransportError.missingSignalCiphertext }
        if messageType == Int(CiphertextMessage.MessageType.preKey.rawValue) {
            return Data(try signalDecryptPreKey(
                message: try PreKeySignalMessage(bytes: ciphertext),
                from: remoteAddress,
                localAddress: localAddress,
                sessionStore: store,
                identityStore: store,
                preKeyStore: store,
                signedPreKeyStore: store,
                kyberPreKeyStore: store,
                context: context
            ))
        }
        guard messageType == Int(CiphertextMessage.MessageType.whisper.rawValue) else {
            throw OBBSignalSessionTransportError.unsupportedSignalMessageType(messageType)
        }
        return Data(try signalDecrypt(
            message: try SignalMessage(bytes: ciphertext),
            from: remoteAddress,
            to: localAddress,
            sessionStore: store,
            identityStore: store,
            context: context
        ))
    }

    public func receive(
        from stream: any IrohRelayStream,
        remoteAddress: ProtocolAddress,
        context: StoreContext = NullContext()
    ) async throws -> OBBSignalSessionReceivedMessage {
        guard let frame = try await stream.receive() else {
            throw OBBSignalSessionTransportError.streamClosed
        }
        return try decrypt(frame: frame, from: remoteAddress, context: context)
    }

    public func decrypt(
        frame: HermesRealtimeRelayFrame,
        from remoteAddress: ProtocolAddress,
        context: StoreContext = NullContext()
    ) throws -> OBBSignalSessionReceivedMessage {
        guard frame.type == .signalSessionMessage else {
            throw OBBSignalSessionTransportError.unexpectedFrameType(frame.type)
        }
        guard
            let ciphertextB64 = frame.signalSessionCiphertextB64,
            let messageType = frame.signalMessageType,
            let ciphertext = Data(base64Encoded: ciphertextB64)
        else {
            throw OBBSignalSessionTransportError.missingSignalCiphertext
        }

        let plaintext: Data
        if messageType == Int(CiphertextMessage.MessageType.preKey.rawValue) {
            plaintext = Data(try signalDecryptPreKey(
                message: try PreKeySignalMessage(bytes: ciphertext),
                from: remoteAddress,
                localAddress: localAddress,
                sessionStore: store,
                identityStore: store,
                preKeyStore: store,
                signedPreKeyStore: store,
                kyberPreKeyStore: store,
                context: context
            ))
        } else if messageType == Int(CiphertextMessage.MessageType.whisper.rawValue) {
            plaintext = Data(try signalDecrypt(
                message: try SignalMessage(bytes: ciphertext),
                from: remoteAddress,
                to: localAddress,
                sessionStore: store,
                identityStore: store,
                context: context
            ))
        } else {
            throw OBBSignalSessionTransportError.unsupportedSignalMessageType(messageType)
        }

        return OBBSignalSessionReceivedMessage(frame: frame, plaintext: plaintext, messageType: messageType)
    }

    public static func frame(
        for ciphertext: CiphertextMessage,
        uid: String,
        connectionId: String,
        requestId: String? = nil
    ) -> HermesRealtimeRelayFrame {
        HermesRealtimeRelayFrame(
            type: .signalSessionMessage,
            uid: uid,
            connectionId: connectionId,
            requestId: requestId,
            signalSessionCiphertextB64: ciphertext.serialize().base64EncodedString(),
            signalMessageType: Int(ciphertext.messageType.rawValue)
        )
    }
}

public struct OBBSignalSessionGatewayEnvelopeProvider: OBBSignalGatewayEnvelopeProvider {
    private let transport: OBBSignalSessionCipherTransport
    private let peerBundle: OBBSignalClaimedPreKeyBundle
    private let pinnedIdentityPublicKey: Data?

    public init(
        transport: OBBSignalSessionCipherTransport,
        peerBundle: OBBSignalClaimedPreKeyBundle,
        pinnedIdentityPublicKey: Data? = nil
    ) {
        self.transport = transport
        self.peerBundle = peerBundle
        self.pinnedIdentityPublicKey = pinnedIdentityPublicKey
    }

    public func seal(
        plaintext: Data,
        uid: String,
        clientId: String,
        slotId: String
    ) async throws -> Data {
        let envelope = try await transport.sealGatewayEnvelope(
            plaintext,
            context: OBBSignalGatewayEnvelopeContext(uid: uid, clientId: clientId, slotId: slotId),
            claimSignalPrekeyBundle: { peerBundle },
            pinnedIdentityPublicKey: pinnedIdentityPublicKey
        )
        return try JSONEncoder().encode(envelope)
    }

    /// Open an inbound Gateway v4 envelope with the same durable session actor
    /// used for outbound writes. The claimed peer bundle is decoded and pinned
    /// before libsignal sees the ciphertext; this prevents a server-controlled
    /// bundle swap from creating a new trusted session on the read path.
    public func open(
        envelopeData: Data,
        uid: String,
        clientId: String,
        slotId: String
    ) async throws -> Data {
        let envelope = try JSONDecoder().decode(FirestoreGatewaySignalEnvelopeDoc.self, from: envelopeData)
        guard
            envelope.binding.uid == uid,
            envelope.binding.clientId == clientId,
            envelope.binding.slotId == slotId,
            envelope.binding.scope == "gateway"
        else {
            throw OBBSignalSessionTransportError.invalidEnvelopeBinding
        }
        let remote = try OBBSignalRemoteBundleDecoder.decode(
            peerBundle,
            pinnedIdentityPublicKey: pinnedIdentityPublicKey
        )
        return try await transport.decryptGatewayEnvelope(
            envelope,
            from: remote.address
        )
    }
}
