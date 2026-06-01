import CryptoKit
import Foundation

/// Canonical App Check attestation digest shared by Mac, iOS, and Cloud Functions (WS2/WS4).
/// Wire field `attestationHashBlake3` carries this SHA-256 hex (name is historical).
public enum AppCheckAttestationBinding {
    public static let claimKey = "obb_app_check"
    public static let canonicalPrefix = "openburnbar.appcheck.v1"
    public static let maxAgeMillis: Int64 = 30 * 24 * 60 * 60 * 1000

    public struct Claim: Equatable, Sendable {
        public let appId: String
        public let boundAtMillis: Int64

        public init(appId: String, boundAtMillis: Int64) {
            self.appId = appId
            self.boundAtMillis = boundAtMillis
        }
    }

    public static func digestHex(appId: String, boundAtMillis: Int64) -> String {
        let payload = "\(canonicalPrefix)|\(appId)|\(boundAtMillis)"
        let hash = SHA256.hash(data: Data(payload.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    public static func digestHex(for claim: Claim) -> String {
        digestHex(appId: claim.appId, boundAtMillis: claim.boundAtMillis)
    }

    public static func parseClaim(from token: [String: Any]?) -> Claim? {
        guard let raw = token?[claimKey] as? [String: Any],
              let appId = raw["appId"] as? String,
              !appId.isEmpty,
              let boundAtMillis = raw["boundAtMillis"] as? Int64
              ?? (raw["boundAtMillis"] as? Double).map({ Int64($0) }) else {
            return nil
        }
        return Claim(appId: appId, boundAtMillis: boundAtMillis)
    }

    public static func isFresh(_ claim: Claim, nowMillis: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> Bool {
        nowMillis - claim.boundAtMillis <= maxAgeMillis
    }
}
