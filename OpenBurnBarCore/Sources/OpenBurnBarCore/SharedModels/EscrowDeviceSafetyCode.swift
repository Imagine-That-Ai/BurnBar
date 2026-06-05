import CryptoKit
import Foundation

/// Stream 6 — Multi-device trust + safety-number UX.
///
/// Renders a human-comparable, Signal-style safety code so a person approving a
/// device can read the code off one device and confirm it matches the other
/// before granting trust. This is a **display/UX layer plus a local key-binding
/// check** — it never changes the crypto, the stored fingerprint, or the
/// server-side approve path. Fingerprint *comparison enforcement* server-side is
/// gated behind the Stream 6 capability and stays inert until activation.
///
/// **Load-bearing binding (Stream 6 enablement).** The fingerprint stored in
/// Firestore is `base64(SHA-256(publicKeyData))` (see
/// `CloudVaultDeviceKeypair.publicKeyFingerprint` /
/// `DeviceKeypairProtocol.publicKeyFingerprint`). A server (or a Firestore
/// tamper) could advertise an *arbitrary* fingerprint string that has no
/// relationship to the key bytes actually used to seal escrow envelopes. Reading
/// that string straight into a "safety code" would let an attacker substitute
/// the escrow encryption key while showing the operator a code that still
/// matches. To close that gap, ``format(publicKeyData:)`` re-derives the
/// fingerprint **locally from the escrow device's actual public-key bytes**
/// (the same bytes wrapped to during escrow encryption — `EscrowPublicKey
/// .publicKeyData`) and fails closed (`nil`) when the key is absent, not base64,
/// or not a genuine P-256 x9.63 public key. This mirrors
/// `HermesGatewayAgentKeyPinStore.pinnedSafetyCode`, which hashes the real
/// pinned key bytes rather than any server-supplied string.
///
/// ``format(fingerprint:)`` is retained for the read-only display of a value
/// already stored, but the trusted, key-bound path is ``format(publicKeyData:)``
/// / ``recomputeFingerprint(fromPublicKeyData:)`` and the
/// ``isFingerprint(_:boundTo:)`` verifier.
///
/// The grouping convention deliberately mirrors
/// `HermesGatewayAgentKeyPinStore.safetyCode`: the first 16 fingerprint bytes
/// (>= 128 bits) shown as eight uppercase hex groups of four characters,
/// space-separated. Returns `nil` for a missing / non-base64 / too-short
/// fingerprint rather than a plausible-looking code derived from raw string
/// bytes — never invent trust.
public enum EscrowDeviceSafetyCode {
    /// Number of leading fingerprint bytes folded into the displayed code.
    /// 16 bytes == 128 bits == eight 2-byte groups, matching the Hermes
    /// gateway safety-code formatter so the two surfaces look the same.
    public static let displayedByteCount = 16

    /// Byte length of a P-256 (secp256r1) public key in uncompressed x9.63
    /// form: a `0x04` prefix followed by the 32-byte X and Y coordinates. The
    /// escrow keypair advertises exactly this (`DeviceKeypairProtocol
    /// .publicKeyData` — "65 bytes: 0x04 || x || y").
    public static let p256X963PublicKeyByteCount = 65

    /// Format a stored `publicKeyFingerprint` (base64 of a SHA-256 digest) as a
    /// grouped, human-comparable safety code, or `nil` when the fingerprint is
    /// missing, not valid base64, or shorter than ``displayedByteCount`` bytes.
    ///
    /// - Important: This formats a value the *server* stored and is advisory.
    ///   For the trust decision use ``format(publicKeyData:)``, which re-derives
    ///   the fingerprint from the escrow device's real public key bytes and so
    ///   cannot be spoofed by a server-supplied fingerprint string.
    ///
    /// - Parameter fingerprint: the raw `escrow_devices.publicKeyFingerprint`
    ///   string exactly as stored in Firestore. Surrounding whitespace is
    ///   tolerated; everything else must be genuine base64.
    public static func format(fingerprint: String?) -> String? {
        guard let fingerprint else { return nil }
        let trimmed = fingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let digest = Data(base64Encoded: trimmed),
              digest.count >= displayedByteCount else { return nil }

        return formatDigest(digest)
    }

    /// Re-derive the canonical escrow fingerprint — `base64(SHA-256(publicKeyData))`
    /// — **locally from the device's actual public-key bytes**, or `nil` when the
    /// supplied bytes are not a genuine P-256 x9.63 public key.
    ///
    /// This is the trust anchor for the Stream 6 enablement: the fingerprint a
    /// reader computes here is bound to the bytes that escrow encryption wraps
    /// to, so a server cannot advertise a mismatched fingerprint and have it
    /// pass. Validation imports the bytes through CryptoKit (mirroring how the
    /// Hermes ratchet/pin paths validate `x963Representation`) so structurally
    /// invalid or wrong-curve keys fail closed rather than producing a
    /// plausible-looking code.
    ///
    /// - Parameter base64PublicKey: base64 of the uncompressed x9.63 P-256
    ///   public key (`EscrowPublicKey.publicKeyData`). Surrounding whitespace is
    ///   tolerated.
    /// - Returns: the base64 SHA-256 fingerprint string, or `nil` if the key is
    ///   absent / not base64 / not a 65-byte x9.63 P-256 public key.
    public static func recomputeFingerprint(fromPublicKeyData base64PublicKey: String?) -> String? {
        guard let keyData = validatedPublicKeyData(base64PublicKey) else { return nil }
        return Data(SHA256.hash(data: keyData)).base64EncodedString()
    }

    /// Format a grouped, human-comparable safety code derived from the escrow
    /// device's **actual public-key bytes** (the load-bearing, key-bound path),
    /// or `nil` when the key is absent / invalid.
    ///
    /// Unlike ``format(fingerprint:)``, the code returned here is computed from
    /// the key itself, so a server that swaps the escrow encryption key — or
    /// advertises a fingerprint unrelated to the key — changes (or cannot
    /// produce) this code. Fail-closed: a missing or malformed key yields `nil`,
    /// never a plausible code.
    ///
    /// - Parameter base64PublicKey: base64 of the uncompressed x9.63 P-256
    ///   public key (`EscrowPublicKey.publicKeyData`).
    public static func format(publicKeyData base64PublicKey: String?) -> String? {
        guard let fingerprint = recomputeFingerprint(fromPublicKeyData: base64PublicKey) else { return nil }
        return format(fingerprint: fingerprint)
    }

    /// Whether a server-advertised `publicKeyFingerprint` actually matches the
    /// fingerprint re-derived from the escrow device's real public-key bytes.
    ///
    /// The display path may show a stored fingerprint, but trust must only be
    /// extended when that stored value is provably the SHA-256 of the key the
    /// device will use. This is the client-side mirror of the server-side
    /// enforcement added (gated) in `approveEscrowDeviceTrust`. Comparison is
    /// constant-time over the fixed-length digests and fails closed on any
    /// absent / malformed input.
    ///
    /// - Parameters:
    ///   - storedFingerprint: the `escrow_devices.publicKeyFingerprint` string.
    ///   - base64PublicKey: base64 of the escrow device's x9.63 P-256 public key.
    /// - Returns: `true` only when both are present, valid, and the stored
    ///   fingerprint equals the locally recomputed one.
    public static func isFingerprint(_ storedFingerprint: String?, boundTo base64PublicKey: String?) -> Bool {
        guard let storedFingerprint else { return false }
        let trimmedStored = storedFingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedStored.isEmpty,
              let storedDigest = Data(base64Encoded: trimmedStored),
              let keyData = validatedPublicKeyData(base64PublicKey) else { return false }
        let recomputed = Data(SHA256.hash(data: keyData))
        // Fixed-length digests; constant-time compare avoids leaking how many
        // leading bytes matched to a tamper probe.
        return constantTimeEquals(storedDigest, recomputed)
    }

    /// Validate that `base64PublicKey` decodes to a genuine 65-byte x9.63 P-256
    /// public key and return its raw bytes, or `nil`. Importing through
    /// CryptoKit rejects wrong-length, wrong-prefix, off-curve, or otherwise
    /// malformed keys — matching how the Hermes ratchet path validates keys.
    private static func validatedPublicKeyData(_ base64PublicKey: String?) -> Data? {
        guard let base64PublicKey else { return nil }
        let trimmed = base64PublicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let raw = Data(base64Encoded: trimmed),
              raw.count == p256X963PublicKeyByteCount,
              (try? P256.KeyAgreement.PublicKey(x963Representation: raw)) != nil else { return nil }
        return raw
    }

    /// Group a >= 16-byte digest into the displayed eight-group hex code.
    private static func formatDigest(_ digest: Data) -> String {
        let bytes = Array(digest.prefix(displayedByteCount))
        let groups = stride(from: 0, to: displayedByteCount, by: 2).map { offset -> String in
            bytes[offset..<min(offset + 2, bytes.count)]
                .map { String(format: "%02X", $0) }
                .joined()
        }
        return groups.joined(separator: " ")
    }

    /// Length-checked, constant-time byte comparison. Returns `false` for any
    /// length mismatch and never short-circuits on the first differing byte.
    private static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (l, r) in zip(lhs, rhs) {
            difference |= l ^ r
        }
        return difference == 0
    }

    /// A spaced-out, screen-reader-friendly rendering of a formatted code so
    /// VoiceOver speaks "A 1 B 2" rather than swallowing the hex run. Pass the
    /// already-formatted code (the output of ``format(fingerprint:)``).
    public static func spelledOut(_ formatted: String) -> String {
        formatted
            .replacingOccurrences(of: " ", with: ", ")
            .map { String($0) }
            .joined(separator: " ")
    }
}

/// Stream 6 feature flag. Default **OFF** so no existing approval flow changes
/// until the safety-code compare step is deliberately enabled. When off, the
/// approve UX behaves exactly as before; when on, the approver must confirm the
/// displayed safety code matches the other device before approval proceeds.
///
/// Kept intentionally tiny and dependency-free (a process-wide toggle plus an
/// optional `UserDefaults` override) so both the macOS app and the iOS/iPad app
/// can read the same flag from shared code. No remote-config wiring yet — this
/// is the additive, flag-OFF scaffold the later enablement PR flips on.
public enum EscrowDeviceTrustSafetyCheckFlag {
    /// UserDefaults key an internal build / UI test can flip to opt in early.
    public static let userDefaultsKey = "openburnbar.escrowDeviceTrust.safetyCodeCompare.enabled"

    /// Process-wide default. Stays `false` for production until the comparison
    /// step is deliberately rolled out.
    public nonisolated(unsafe) static var defaultEnabled = false

    /// Whether the safety-code compare step is enabled. A `UserDefaults`
    /// override (when present) wins so QA / UI tests can exercise the gated path
    /// without shipping it on by default.
    public static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: userDefaultsKey) != nil {
            return defaults.bool(forKey: userDefaultsKey)
        }
        return defaultEnabled
    }
}
