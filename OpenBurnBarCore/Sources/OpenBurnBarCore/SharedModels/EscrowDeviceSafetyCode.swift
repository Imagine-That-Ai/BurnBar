import CryptoKit
import Foundation

/// Stream 6 — Multi-device trust + safety-number UX.
///
/// Renders the *already-stored* `escrow_devices.publicKeyFingerprint` into a
/// human-comparable, Signal-style safety code so a person approving a device can
/// read the code off one device and confirm it matches the other before granting
/// trust. This is a **display/UX layer only** — it never changes the crypto, the
/// stored fingerprint, or the server-side approve path. Fingerprint *comparison
/// enforcement* server-side is a deliberately separate, later PR.
///
/// The fingerprint stored in Firestore is `base64(SHA-256(publicKeyData))`
/// (see `CloudVaultDeviceKeypair.publicKeyFingerprint` /
/// `DeviceKeypairProtocol.publicKeyFingerprint`). Because that value is
/// deterministic for a given device and identical in every reader's copy of the
/// doc, formatting it with the SAME routine on Mac and iOS/iPad makes both ends
/// display byte-identical codes without either side re-deriving anything.
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

    /// Format a stored `publicKeyFingerprint` (base64 of a SHA-256 digest) as a
    /// grouped, human-comparable safety code, or `nil` when the fingerprint is
    /// missing, not valid base64, or shorter than ``displayedByteCount`` bytes.
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

        let bytes = Array(digest.prefix(displayedByteCount))
        let groups = stride(from: 0, to: displayedByteCount, by: 2).map { offset -> String in
            bytes[offset..<min(offset + 2, bytes.count)]
                .map { String(format: "%02X", $0) }
                .joined()
        }
        return groups.joined(separator: " ")
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
