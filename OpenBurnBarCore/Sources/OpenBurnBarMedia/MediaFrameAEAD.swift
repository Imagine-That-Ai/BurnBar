import Foundation
import CryptoKit

/// F7 — per-frame AEAD for media/screen frames (defense-in-depth beyond the iroh
/// QUIC transport seal).
///
/// Today screen-share / agent-watch frames rely solely on iroh's transport
/// encryption between paired peers. That is confidential on the wire, but unlike
/// the chat lane there is no second, app-layer seal — so a future non-iroh
/// fallback (or a transport bug) could carry frame plaintext. F7 derives a media
/// session key from the paired identities and AEAD-seals every encoded
/// `MediaFrame` payload, binding the frame's position (stream class, kind,
/// GOP/frame index) into the AAD so a sealed frame cannot be replayed in another
/// position or on another stream.
///
/// Sealing is gated by `MediaFrameAeadNegotiation`: both peers must advertise
/// support (mirroring the MediaFrame v2 capability gate) before either side
/// emits sealed frames, so paired clients that predate F7 keep interoperating.
public struct MediaFrameAEAD: Sendable {
    public enum SealError: Error, Equatable, Sendable {
        case envelopeTooShort
        case invalidMagic
        case unsupportedVersion(UInt8)
        case openFailed
    }

    /// `OBMFA1` — OpenBurnBar Media Frame AEAD v1. Distinct from the MediaFrame
    /// v2 codec magic so receivers can sniff a sealed envelope unambiguously.
    public static let magic = Data([0x4F, 0x42, 0x4D, 0x46, 0x41, 0x31]) // OBMFA1
    public static let version: UInt8 = 1
    private static let nonceByteCount = 12
    private static let tagByteCount = 16
    /// magic(6) + version(1) + AES-GCM combined(nonce 12 + tag 16 + ciphertext).
    private static let headerByteCount = 7

    public init() {}

    /// Derive the 32-byte media session key from the paired peers' shared secret.
    ///
    /// `sharedSecret` is the ECDH output between the two pinned relay identity
    /// keys (the same identities the HPKE chat lane authenticates), so the key is
    /// bound to *these* two devices and rotates when either re-pairs. `salt`
    /// should be a per-session value (e.g. the mirror/session id bytes) so two
    /// sessions between the same peers derive distinct keys.
    public func deriveSessionKey(
        sharedSecret: Data,
        salt: Data,
        info: String = "OpenBurnBar-MediaFrameAEAD-v1"
    ) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: sharedSecret),
            salt: salt,
            info: Data(info.utf8),
            outputByteCount: 32
        )
    }

    /// Domain-separated AAD binding the frame's identity so a sealed frame is
    /// valid only in its original stream and position.
    public static func aad(
        streamClass: String,
        kind: UInt8,
        gopID: UInt32,
        frameIndex: UInt32
    ) -> Data {
        var data = Data("OpenBurnBar-MediaFrameAEAD-v1|".utf8)
        data.append(contentsOf: streamClass.utf8)
        data.append(0x7C) // '|'
        data.append(kind)
        var beGop = gopID.bigEndian
        withUnsafeBytes(of: &beGop) { data.append(contentsOf: $0) }
        var beIdx = frameIndex.bigEndian
        withUnsafeBytes(of: &beIdx) { data.append(contentsOf: $0) }
        return data
    }

    public static func isSealedEnvelope(_ envelope: Data) -> Bool {
        // No defensive copy: at 30-60fps with multi-hundred-KB keyframes a
        // full-envelope copy per frame is pure waste. All indexing below is
        // startIndex-relative, so Data slices are handled correctly as-is.
        guard envelope.count >= magic.count else { return false }
        return envelope.prefix(magic.count).elementsEqual(magic)
    }

    /// Seal an encoded media frame payload. Returns
    /// `magic ‖ version ‖ AES-GCM combined(nonce ‖ ciphertext ‖ tag)`.
    public func seal(
        plaintext: Data,
        key: SymmetricKey,
        streamClass: String,
        kind: UInt8,
        gopID: UInt32,
        frameIndex: UInt32
    ) throws -> Data {
        let authenticatedData = Self.aad(streamClass: streamClass, kind: kind, gopID: gopID, frameIndex: frameIndex)
        let sealedBox = try AES.GCM.seal(plaintext, using: key, authenticating: authenticatedData)
        guard let combined = sealedBox.combined else { throw SealError.openFailed }
        var envelope = Data()
        envelope.append(contentsOf: Self.magic)
        envelope.append(Self.version)
        envelope.append(combined)
        return envelope
    }

    /// Open a sealed media frame, verifying it belongs to this exact stream and
    /// position. Any AAD mismatch (wrong stream class, kind, or index) or a
    /// tampered ciphertext throws.
    public func open(
        envelope: Data,
        key: SymmetricKey,
        streamClass: String,
        kind: UInt8,
        gopID: UInt32,
        frameIndex: UInt32
    ) throws -> Data {
        // No defensive copy (see isSealedEnvelope) — indexing is
        // startIndex-relative throughout, so slices open correctly.
        guard envelope.count > Self.headerByteCount + Self.nonceByteCount + Self.tagByteCount else {
            throw SealError.envelopeTooShort
        }
        guard envelope.prefix(Self.magic.count).elementsEqual(Self.magic) else { throw SealError.invalidMagic }
        let version = envelope[envelope.startIndex + Self.magic.count]
        guard version == Self.version else { throw SealError.unsupportedVersion(version) }
        let combined = envelope.suffix(from: envelope.startIndex + Self.headerByteCount)
        let authenticatedData = Self.aad(streamClass: streamClass, kind: kind, gopID: gopID, frameIndex: frameIndex)
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(box, using: key, authenticating: authenticatedData)
        } catch {
            throw SealError.openFailed
        }
    }
}

/// F7 capability gate. Both peers must advertise media-frame AEAD support before
/// either seals, exactly like the MediaFrame v2 wire-version gate. Carried as a
/// presence/mirror capability bit so old peers (absent ⇒ false) keep getting
/// unsealed frames over the iroh transport seal until both sides upgrade.
public enum MediaFrameAeadNegotiation {
    public static let capability = "media_frame_aead_v1"

    /// F7 rollout gate (default-off). Phones consult this before wrapping a
    /// media-seal key into their mirror requests; the Mac seal path arms only
    /// when a request carries a wrap it can open.
    public static let remoteConfigKey = "computer_use_media_frame_aead_enabled"

    /// Seal only when BOTH peers support it.
    public static func resolveSealingEnabled(localSupports: Bool, remoteSupports: Bool) -> Bool {
        localSupports && remoteSupports
    }
}
