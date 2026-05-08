import Foundation

// MARK: - Webhook ID generator
//
// HA webhook IDs are public-ish strings (anyone with the ID can fire
// the webhook on the LAN), so they must be high-entropy. We follow
// HA's own approach: 32 random URL-safe characters drawn from the
// system CSPRNG. We prefix with `openburnbar_cast_recover_` so that a
// glance at HA's automations.yaml makes the source obvious.

enum HomeAssistantWebhookID {

    static let prefix = "openburnbar_cast_recover_"
    static let secretLength = 32

    /// Cryptographically random URL-safe webhook id.
    /// Deterministic in tests via `randomBytes`.
    static func generate(randomBytes: () -> [UInt8] = defaultRandomBytes) -> String {
        let bytes = randomBytes()
        // Base32-ish alphabet (lowercase a-z + 0-9), no padding, URL safe.
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        var output = ""
        output.reserveCapacity(secretLength)
        for byte in bytes.prefix(secretLength) {
            output.append(alphabet[Int(byte) % alphabet.count])
        }
        return prefix + output
    }

    /// Returns true if the supplied id was minted by us.
    static func isOurs(_ id: String) -> Bool {
        id.hasPrefix(prefix) && id.count == prefix.count + secretLength
    }

    /// Default RNG path — `SystemRandomNumberGenerator`.
    static func defaultRandomBytes() -> [UInt8] {
        var rng = SystemRandomNumberGenerator()
        var output: [UInt8] = []
        output.reserveCapacity(secretLength)
        for _ in 0..<secretLength {
            output.append(UInt8(rng.next() % 256))
        }
        return output
    }
}
