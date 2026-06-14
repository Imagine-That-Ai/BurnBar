import CryptoKit
import Foundation
import LibSignalClient
import OpenBurnBarCore
import OpenBurnBarIrohRelay
import OpenBurnBarSignalCore

public enum OBBSignalSessionTransportError: LocalizedError, Equatable {
    case invalidBase64(String)
    case missingSignalCiphertext
    case streamClosed
    case unexpectedFrameType(HermesRealtimeRelayFrameType)
    case unsupportedSignalMessageType(Int)
    /// F6: the directory-advertised identity key does not match the key the
    /// caller pinned out-of-band. Fail closed before establishing a session.
    case identityPinMismatch

    public var errorDescription: String? {
        switch self {
        case .invalidBase64(let field):
            return "Invalid base64 in Signal session field \(field)."
        case .missingSignalCiphertext:
            return "Signal session frame is missing ciphertext or message type."
        case .streamClosed:
            return "Signal session stream closed before a message frame arrived."
        case .unexpectedFrameType(let type):
            return "Expected signal.session.message frame, received \(type.rawValue)."
        case .unsupportedSignalMessageType(let type):
            return "Unsupported Signal session message type \(type)."
        case .identityPinMismatch:
            return "Remote identity key does not match the pinned key; refusing to establish a session."
        }
    }
}

public struct OBBSignalSessionPeer: Equatable, Hashable, Sendable {
    public let uid: String
    public let deviceId: String
    public let identityKeyId: String
    public let keyVersion: Int?
    public let signalDeviceIdOverride: UInt32?
    public let registrationIdOverride: UInt32?

    public init(
        uid: String,
        deviceId: String,
        identityKeyId: String,
        keyVersion: Int? = nil,
        signalDeviceId: UInt32? = nil,
        registrationId: UInt32? = nil
    ) {
        self.uid = uid
        self.deviceId = deviceId
        self.identityKeyId = identityKeyId
        self.keyVersion = keyVersion
        self.signalDeviceIdOverride = signalDeviceId
        self.registrationIdOverride = registrationId
    }

    public var protocolAddressName: String {
        let normalized = [uid, deviceId, identityKeyId].map(Self.protocolSafeSegment)
        return "openburnbar.\(normalized.joined(separator: "."))"
    }

    public var signalDeviceId: UInt32 {
        signalDeviceIdOverride ?? Self.stableUInt32(
            seed: "device|\(uid)|\(deviceId)|\(identityKeyId)|\(keyVersion ?? 0)",
            min: 1,
            max: 127
        )
    }

    public var registrationId: UInt32 {
        registrationIdOverride ?? Self.stableUInt32(
            seed: "registration|\(uid)|\(deviceId)|\(identityKeyId)|\(keyVersion ?? 0)",
            min: 1,
            max: 0x3FFF
        )
    }

    public func protocolAddress() throws -> ProtocolAddress {
        try ProtocolAddress(name: protocolAddressName, deviceId: signalDeviceId)
    }

    private static func protocolSafeSegment(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let scalars = trimmed.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar)
                || scalar.value == 45
                || scalar.value == 95
                ? Character(scalar)
                : "_"
        }
        let result = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return result.isEmpty ? "unknown" : result
    }

    private static func stableUInt32(seed: String, min: UInt32, max: UInt32) -> UInt32 {
        precondition(min <= max)
        let digest = SHA256.hash(data: Data(seed.utf8))
        let raw = digest.prefix(4).reduce(UInt32(0)) { partial, byte in
            (partial << 8) | UInt32(byte)
        }
        return min + (raw % (max - min + 1))
    }
}

public struct OBBSignalClaimedSignedPreKey: Equatable, Sendable {
    public let id: String
    public let numericId: UInt32
    public let publicKeyB64: String
    public let signatureB64: String

    public init(id: String, numericId: UInt32, publicKeyB64: String, signatureB64: String) {
        self.id = id
        self.numericId = numericId
        self.publicKeyB64 = publicKeyB64
        self.signatureB64 = signatureB64
    }
}

public struct OBBSignalClaimedOneTimePreKey: Equatable, Sendable {
    public let id: String
    public let numericId: UInt32
    public let publicKeyB64: String

    public init(id: String, numericId: UInt32, publicKeyB64: String) {
        self.id = id
        self.numericId = numericId
        self.publicKeyB64 = publicKeyB64
    }
}

public struct OBBSignalClaimedKyberPreKey: Equatable, Sendable {
    public let id: String
    public let numericId: UInt32
    public let publicKeyB64: String
    public let signatureB64: String

    public init(id: String, numericId: UInt32, publicKeyB64: String, signatureB64: String) {
        self.id = id
        self.numericId = numericId
        self.publicKeyB64 = publicKeyB64
        self.signatureB64 = signatureB64
    }
}

public struct OBBSignalClaimedPreKeyBundle: Equatable, Sendable {
    public let peerUid: String
    public let identityKeyId: String
    public let deviceId: String
    public let keyVersion: Int
    public let identityPublicKeyData: String
    public let signedPreKey: OBBSignalClaimedSignedPreKey
    public let kyberPreKey: OBBSignalClaimedKyberPreKey
    public let oneTimePreKey: OBBSignalClaimedOneTimePreKey?
    public let signalDeviceId: UInt32?
    public let signalRegistrationId: UInt32?

    public init(
        peerUid: String,
        identityKeyId: String,
        deviceId: String,
        keyVersion: Int,
        identityPublicKeyData: String,
        signedPreKey: OBBSignalClaimedSignedPreKey,
        kyberPreKey: OBBSignalClaimedKyberPreKey,
        oneTimePreKey: OBBSignalClaimedOneTimePreKey?,
        signalDeviceId: UInt32? = nil,
        signalRegistrationId: UInt32? = nil
    ) {
        self.peerUid = peerUid
        self.identityKeyId = identityKeyId
        self.deviceId = deviceId
        self.keyVersion = keyVersion
        self.identityPublicKeyData = identityPublicKeyData
        self.signedPreKey = signedPreKey
        self.kyberPreKey = kyberPreKey
        self.oneTimePreKey = oneTimePreKey
        self.signalDeviceId = signalDeviceId
        self.signalRegistrationId = signalRegistrationId
    }
}

public struct OBBSignalDecodedRemotePreKeyBundle {
    public let peer: OBBSignalSessionPeer
    public let address: ProtocolAddress
    public let bundle: PreKeyBundle
}

public enum OBBSignalRemoteBundleDecoder {
    public static func decode(
        _ claimed: OBBSignalClaimedPreKeyBundle,
        pinnedIdentityPublicKey: Data? = nil
    ) throws -> OBBSignalDecodedRemotePreKeyBundle {
        let peer = OBBSignalSessionPeer(
            uid: claimed.peerUid,
            deviceId: claimed.deviceId,
            identityKeyId: claimed.identityKeyId,
            keyVersion: claimed.keyVersion,
            signalDeviceId: claimed.signalDeviceId,
            registrationId: claimed.signalRegistrationId
        )
        let address = try peer.protocolAddress()
        let identityKeyData = try decodeBase64(claimed.identityPublicKeyData, field: "identityPublicKeyData")
        // F6: out-of-band identity pin. Reject a server-supplied bundle whose
        // identity key is not the operator-pinned key BEFORE `processPreKeyBundle`
        // persists any session/identity state bound to it. The shipped at-rest
        // path (`SignalAtRestSealer`) pins sender keys the same way.
        if let pinnedIdentityPublicKey, identityKeyData != pinnedIdentityPublicKey {
            throw OBBSignalSessionTransportError.identityPinMismatch
        }
        let identity = try IdentityKey(publicKey: PublicKey(identityKeyData))
        let signedPublic = try PublicKey(decodeBase64(claimed.signedPreKey.publicKeyB64, field: "signedPreKey.publicKeyB64"))
        let signedSignature = try decodeBase64(claimed.signedPreKey.signatureB64, field: "signedPreKey.signatureB64")
        let kyberPublic = try KEMPublicKey(decodeBase64(claimed.kyberPreKey.publicKeyB64, field: "kyberPreKey.publicKeyB64"))
        let kyberSignature = try decodeBase64(claimed.kyberPreKey.signatureB64, field: "kyberPreKey.signatureB64")

        let bundle: PreKeyBundle
        if let oneTimePreKey = claimed.oneTimePreKey {
            bundle = try PreKeyBundle(
                registrationId: peer.registrationId,
                deviceId: peer.signalDeviceId,
                prekeyId: oneTimePreKey.numericId,
                prekey: PublicKey(decodeBase64(oneTimePreKey.publicKeyB64, field: "oneTimePreKey.publicKeyB64")),
                signedPrekeyId: claimed.signedPreKey.numericId,
                signedPrekey: signedPublic,
                signedPrekeySignature: signedSignature,
                identity: identity,
                kyberPrekeyId: claimed.kyberPreKey.numericId,
                kyberPrekey: kyberPublic,
                kyberPrekeySignature: kyberSignature
            )
        } else {
            bundle = try PreKeyBundle(
                registrationId: peer.registrationId,
                deviceId: peer.signalDeviceId,
                signedPrekeyId: claimed.signedPreKey.numericId,
                signedPrekey: signedPublic,
                signedPrekeySignature: signedSignature,
                identity: identity,
                kyberPrekeyId: claimed.kyberPreKey.numericId,
                kyberPrekey: kyberPublic,
                kyberPrekeySignature: kyberSignature
            )
        }

        return OBBSignalDecodedRemotePreKeyBundle(peer: peer, address: address, bundle: bundle)
    }

    private static func decodeBase64(_ value: String, field: String) throws -> Data {
        guard let decoded = Data(base64Encoded: value) else {
            throw OBBSignalSessionTransportError.invalidBase64(field)
        }
        return decoded
    }
}

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

// AUDIT(@unchecked Sendable): holds libsignal's `OBBSignalProtocolStore` and
// `ProtocolAddress`, both non-Sendable native-handle wrappers. The transport is
// used per-connection (one Double Ratchet session); the libsignal store mediates
// its own state. Converting this to an `actor` to make ratchet serialization
// compiler-enforced is the recommended follow-up, but is deferred to a dedicated
// PR with concurrency tests because it changes the isolation semantics of E2EE
// session code. Tracked in docs/security/UNCHECKED_SENDABLE_REMEDIATION.md.
public final class OBBSignalSessionCipherTransport: @unchecked Sendable {
    public typealias ClaimSignalPreKeyBundle = @Sendable () async throws -> OBBSignalClaimedPreKeyBundle

    private let store: OBBSignalProtocolStore
    private let localAddress: ProtocolAddress

    public init(store: OBBSignalProtocolStore, localAddress: ProtocolAddress) {
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
