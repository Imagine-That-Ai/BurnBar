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

    /// What the negotiator decided for a lane once it weighed the lane's
    /// sealing expectation against what both peers advertised.
    public enum SealingDecision: Equatable, Sendable {
        /// Both peers advertised support — emit sealed frames.
        case seal
        /// Sealing is not expected for this lane (or this lane cannot carry a
        /// sealed envelope), so unsealed-over-QUIC is the negotiated outcome.
        case allowUnsealed
        /// Sealing was expected for this lane but could not be established —
        /// fail CLOSED by refusing the lane rather than silently downgrading
        /// to plaintext-over-QUIC.
        case refuseLane(reason: RefusalReason)

        public enum RefusalReason: String, Equatable, Sendable {
            case remoteDoesNotSupportSealing
            case localDoesNotSupportSealing
            case sessionKeyUnavailable
        }

        public var isRefusal: Bool {
            if case .refuseLane = self { return true }
            return false
        }
    }

    /// Whether a lane is *expected* to seal once F7 is rolled out. Screen-video
    /// shipped first and degrades to unsealed-over-QUIC for pre-F7 viewers, so
    /// it stays soft (`allowUnsealed` when a peer is too old). Every other lane
    /// that can carry a sealed envelope — audio, camera/call video, and file
    /// blobs — defaults to expecting a seal so a de-negotiated peer fails
    /// CLOSED instead of leaking that lane's bytes in cleartext to a transport
    /// fallback. Pure-control/classify lanes carry no frame payload and never
    /// seal.
    public static func sealingExpected(for streamClass: MediaStreamClass) -> Bool {
        switch streamClass.feature {
        case .videoCall, .fileTransfer:
            return true
        case .screenShare, .computerUse:
            // Screen-video / agent-watch keep interoperating with pre-F7
            // viewers over the iroh transport seal; they negotiate up to a
            // seal but never refuse the lane for lack of one.
            return false
        case nil:
            return false
        }
    }

    /// Lane-aware negotiation outcome. Seals when both peers support F7; for a
    /// lane whose `sealingExpected` is true, refuses the lane (fail CLOSED)
    /// when sealing cannot be established; otherwise degrades to
    /// unsealed-over-QUIC. `sessionKeyAvailable` reflects whether a derived
    /// media-seal key actually exists on this side (a peer can advertise the
    /// capability yet fail to wrap/open a session key) — when sealing is
    /// expected and the key is missing, the lane is refused.
    public static func resolveSealingDecision(
        streamClass: MediaStreamClass,
        localSupports: Bool,
        remoteSupports: Bool,
        sessionKeyAvailable: Bool
    ) -> SealingDecision {
        let expected = sealingExpected(for: streamClass)
        guard localSupports else {
            return expected
                ? .refuseLane(reason: .localDoesNotSupportSealing)
                : .allowUnsealed
        }
        guard remoteSupports else {
            return expected
                ? .refuseLane(reason: .remoteDoesNotSupportSealing)
                : .allowUnsealed
        }
        guard sessionKeyAvailable else {
            return expected
                ? .refuseLane(reason: .sessionKeyUnavailable)
                : .allowUnsealed
        }
        return .seal
    }
}
