import CryptoKit
import Foundation

/// Signal-style safety number for the phone-control trust binding (F1).
///
/// Renders a human-comparable code from the **controller's Ed25519 signing key**
/// and the **Mac host's pairing key**, so the operator can read the code off the
/// Mac and confirm it matches the phone before the Mac pins the key (see
/// ``ControllerKeyPinStore``). Both keys are folded in and the raw bytes are
/// sorted lexicographically, so the Mac and the phone derive the **same** code
/// without agreeing on roles — and a relay that swaps *either* key changes the
/// displayed code. This mirrors `HermesGatewayAgentKeyPinStore.safetyCode` and
/// the display convention of `EscrowDeviceSafetyCode`: the first 16 SHA-256
/// digest bytes (≥128 bits) shown as eight uppercase hex groups of four,
/// space-separated.
///
/// Fail-closed: returns `nil` for a missing / non-base64 / wrong-length key
/// rather than a plausible-looking code derived from raw string bytes — never
/// invent trust.
public enum ControllerKeySafetyCode {
    /// Number of leading SHA-256 digest bytes folded into the displayed code
    /// (16 bytes == 128 bits == eight 2-byte groups), matching
    /// ``EscrowDeviceSafetyCode/displayedByteCount`` and the Hermes gateway code.
    public static let displayedByteCount = 16

    /// Raw byte length of an Ed25519 (Curve25519 signing) public key.
    public static let ed25519PublicKeyByteCount = 32

    /// Safety code binding the controller signing key to the Mac host pairing
    /// key. Returns `nil` if either key is absent / not base64 / not a 32-byte
    /// Ed25519 public key.
    public static func format(controllerKeyBase64: String, hostKeyBase64: String) -> String? {
        format(publicKeysBase64: [controllerKeyBase64, hostKeyBase64])
    }

    /// Safety code over an arbitrary set of Ed25519 public keys (≥1). Keys are
    /// validated through CryptoKit (rejecting wrong-length / off-curve keys),
    /// then sorted by raw bytes so the order the caller passes them does not
    /// matter, SHA-256'd, and grouped. Returns `nil` if any key is invalid.
    public static func format(publicKeysBase64: [String]) -> String? {
        guard !publicKeysBase64.isEmpty else { return nil }
        let decoded = publicKeysBase64.compactMap(validatedEd25519KeyBytes)
        guard decoded.count == publicKeysBase64.count else { return nil }
        let ordered = decoded.sorted { $0.lexicographicallyPrecedes($1) }
        let digest = SHA256.hash(data: ordered.reduce(into: Data()) { $0.append($1) })
        return formatDigest(Data(digest))
    }

    /// A spaced-out, screen-reader-friendly rendering so VoiceOver speaks
    /// "A 1 B 2" rather than swallowing the hex run. Pass the output of ``format``.
    public static func spelledOut(_ formatted: String) -> String {
        formatted
            .replacingOccurrences(of: " ", with: ", ")
            .map { String($0) }
            .joined(separator: " ")
    }

    private static func validatedEd25519KeyBytes(_ base64: String) -> Data? {
        let trimmed = base64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let raw = Data(base64Encoded: trimmed),
              raw.count == ed25519PublicKeyByteCount,
              (try? Curve25519.Signing.PublicKey(rawRepresentation: raw)) != nil else {
            return nil
        }
        return raw
    }

    private static func formatDigest(_ digest: Data) -> String {
        let bytes = Array(digest.prefix(displayedByteCount))
        let groups = stride(from: 0, to: min(displayedByteCount, bytes.count), by: 2).map { offset -> String in
            bytes[offset..<min(offset + 2, bytes.count)]
                .map { String(format: "%02X", $0) }
                .joined()
        }
        return groups.joined(separator: " ")
    }
}
