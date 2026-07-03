#if !canImport(LibSignalClient)
import Foundation
import OpenBurnBarCore

public enum OpenBurnBarSignalCoreAvailability: Sendable {
    public static let isLibSignalBacked = false
    public static let unavailableReason = "Vendor/libsignal/swift is not present; Linux imports expose Signal envelope contracts but not libsignal-backed sealing."
}

public enum OpenBurnBarSignalCoreError: LocalizedError, Sendable, Equatable {
    case libSignalUnavailable

    public var errorDescription: String? {
        switch self {
        case .libSignalUnavailable:
            return OpenBurnBarSignalCoreAvailability.unavailableReason
        }
    }
}

public struct OpenBurnBarSignalAtRestRecipient: Sendable, Hashable {
    public let recipientKind: String
    public let recipientIdentityKeyId: String
    public let publicKeyData: Data

    public init(recipientKind: String, recipientIdentityKeyId: String, publicKeyData: Data) {
        self.recipientKind = recipientKind
        self.recipientIdentityKeyId = recipientIdentityKeyId
        self.publicKeyData = publicKeyData
    }
}

public enum OpenBurnBarSignalAtRest {
    public static let atRestInfoPrefix = "OpenBurnBar-Signal-AtRest-v1|"
    public static let payloadCiphertextSchemaVersion = 1
    public static let maximumRecipientWraps = 32

    public static func senderAuthSignedMessage(
        info: String,
        payloadCiphertextB64: String,
        wraps: [CloudVaultSignalAtRestWrap]
    ) -> Data {
        func normalizedBytes(_ s: String) -> [UInt8] {
            Array(s.precomposedStringWithCanonicalMapping.utf8)
        }
        func frame(_ s: String, into out: inout Data) {
            let bytes = normalizedBytes(s)
            var len = UInt32(bytes.count).bigEndian
            withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
            out.append(contentsOf: bytes)
        }
        var message = Data()
        frame(CloudVaultCrypto.signalAtRestSenderAuthDomain, into: &message)
        frame(info, into: &message)
        frame(payloadCiphertextB64, into: &message)
        let sorted = wraps.sorted {
            normalizedBytes($0.recipientIdentityKeyId)
                .lexicographicallyPrecedes(normalizedBytes($1.recipientIdentityKeyId))
        }
        var count = UInt32(sorted.count).bigEndian
        withUnsafeBytes(of: &count) { message.append(contentsOf: $0) }
        for wrap in sorted {
            frame(wrap.recipientIdentityKeyId, into: &message)
            frame(wrap.sealedContentKeyB64, into: &message)
        }
        return message
    }

    public static func atRestSeal(
        _ plaintext: Data,
        recipientIdentityPublicKey: Data,
        binding: SignalEnvelopeAAD.Binding
    ) throws -> Data {
        throw OpenBurnBarSignalCoreError.libSignalUnavailable
    }

    public static func atRestOpen(
        _ ciphertext: Data,
        recipientIdentityPrivateKey: Data,
        binding: SignalEnvelopeAAD.Binding
    ) throws -> Data {
        throw OpenBurnBarSignalCoreError.libSignalUnavailable
    }
}
#endif
