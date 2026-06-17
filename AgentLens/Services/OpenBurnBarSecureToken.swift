import Foundation
import Security

enum OpenBurnBarSecureTokenError: Error, LocalizedError {
    case randomnessUnavailable(OSStatus)

    var errorDescription: String? {
        switch self {
        case .randomnessUnavailable(let status):
            return "Secure random token generation failed with OSStatus \(status)."
        }
    }
}

enum OpenBurnBarSecureToken {
    static let defaultByteCount = 32

    static func randomBase64URL(byteCount: Int = defaultByteCount) throws -> String {
        precondition(byteCount >= defaultByteCount, "Bearer tokens must carry at least 256 bits of entropy.")
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw OpenBurnBarSecureTokenError.randomnessUnavailable(status)
        }
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func randomBase64URLOrPreconditionFailure(byteCount: Int = defaultByteCount) -> String {
        do {
            return try randomBase64URL(byteCount: byteCount)
        } catch {
            preconditionFailure(error.localizedDescription)
        }
    }
}
