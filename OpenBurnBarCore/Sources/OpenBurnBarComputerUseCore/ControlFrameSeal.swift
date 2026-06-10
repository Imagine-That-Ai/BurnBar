import Foundation
import CryptoKit

/// F10 — confidentiality seal for `control.*` iroh frames.
///
/// Mutating control intents are Ed25519-signed and monotonic-counter
/// replay-protected, but the control JSON itself rides the iroh stream
/// unencrypted at the app layer (unlike chat/CLI `request.start`, which is
/// HPKE-wrapped). The signature proves authenticity; it does not provide
/// confidentiality. So clipboard text, remote-unlock credential descriptors,
/// and input coordinates are protected only by the iroh transport seal — a
/// future non-iroh fallback would expose them.
///
/// F10 closes this by AES-256-GCM-sealing the control JSON under the session key
/// already established by the HPKE authenticated-request opener
/// (`HermesRelayAuthenticatedRequest`), binding the controller `peerNodeId` and
/// the control frame type into the AAD so a sealed frame cannot be replayed
/// across peers or re-typed. Sealing is gated by `ControlFrameSealNegotiation`
/// so paired clients that predate F10 keep exchanging signed-but-unsealed
/// control frames over the iroh transport until both sides advertise support.
public struct ControlFrameSeal: Sendable {
    public enum SealError: Error, Equatable, Sendable {
        case envelopeTooShort
        case invalidMagic
        case unsupportedVersion(UInt8)
        case openFailed
    }

    /// `OBCFS1` — OpenBurnBar Control Frame Seal v1.
    public static let magic = Data([0x4F, 0x42, 0x43, 0x46, 0x53, 0x31]) // OBCFS1
    public static let version: UInt8 = 1
    private static let nonceByteCount = 12
    private static let tagByteCount = 16
    private static let headerByteCount = 7 // magic(6) + version(1)

    public init() {}

    /// Derive the control-seal key from the HPKE session key (the per-request
    /// `keyData` the authenticated-request opener returns), domain-separated from
    /// any other use of that key.
    public func deriveSessionKey(
        hpkeSessionKey: Data,
        salt: Data,
        info: String = "OpenBurnBar-ControlFrameSeal-v1"
    ) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: hpkeSessionKey),
            salt: salt,
            info: Data(info.utf8),
            outputByteCount: 32
        )
    }

    /// Domain-separated AAD binding the frame to its controller and type.
    public static func aad(peerNodeId: String, frameType: String) -> Data {
        var data = Data("OpenBurnBar-ControlFrameSeal-v1|".utf8)
        data.append(contentsOf: peerNodeId.utf8)
        data.append(0x7C) // '|'
        data.append(contentsOf: frameType.utf8)
        return data
    }

    public static func isSealedEnvelope(_ envelope: Data) -> Bool {
        guard envelope.count >= magic.count else { return false }
        let normalized: Data = envelope.withUnsafeBytes { Data($0) }
        return normalized.prefix(magic.count) == magic
    }

    /// Seal control JSON. Returns `magic ‖ version ‖ AES-GCM combined`.
    public func seal(
        plaintext: Data,
        key: SymmetricKey,
        peerNodeId: String,
        frameType: String
    ) throws -> Data {
        let authenticatedData = Self.aad(peerNodeId: peerNodeId, frameType: frameType)
        let box = try AES.GCM.seal(plaintext, using: key, authenticating: authenticatedData)
        guard let combined = box.combined else { throw SealError.openFailed }
        var envelope = Data()
        envelope.append(contentsOf: Self.magic)
        envelope.append(Self.version)
        envelope.append(combined)
        return envelope
    }

    public func open(
        envelope: Data,
        key: SymmetricKey,
        peerNodeId: String,
        frameType: String
    ) throws -> Data {
        let normalized: Data = envelope.withUnsafeBytes { Data($0) }
        guard normalized.count > Self.headerByteCount + Self.nonceByteCount + Self.tagByteCount else {
            throw SealError.envelopeTooShort
        }
        guard normalized.prefix(Self.magic.count) == Self.magic else { throw SealError.invalidMagic }
        let version = normalized[normalized.startIndex + Self.magic.count]
        guard version == Self.version else { throw SealError.unsupportedVersion(version) }
        let combined = normalized.suffix(from: normalized.startIndex + Self.headerByteCount)
        let authenticatedData = Self.aad(peerNodeId: peerNodeId, frameType: frameType)
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(box, using: key, authenticating: authenticatedData)
        } catch {
            throw SealError.openFailed
        }
    }
}

/// F10 capability gate. Both peers must advertise control-seal support before
/// either seals; absent ⇒ false ⇒ signed-but-unsealed control frames continue
/// over the iroh transport seal.
public enum ControlFrameSealNegotiation {
    public static let capability = "control_seal_v1"

    public static func resolveSealingEnabled(localSupports: Bool, remoteSupports: Bool) -> Bool {
        localSupports && remoteSupports
    }
}
