import CryptoKit
import Foundation

extension SessionLogSyncService {
    static func cloudDocumentID(deviceId: String, record: ConversationRecord) -> String {
        let safeDevice = cloudDocumentComponent(deviceId, fallback: "device", maxLength: 48)
        let safeProvider = cloudDocumentComponent(record.provider.rawValue, fallback: "provider", maxLength: 32)
        let digest = sha256Hex("\(record.provider.rawValue)\n\(record.sessionId)\n\(record.id)")
        return "\(safeDevice)_\(safeProvider)_\(digest.prefix(32))"
    }

    private static func cloudDocumentComponent(_ raw: String, fallback: String, maxLength: Int) -> String {
        var result = ""
        result.reserveCapacity(min(raw.count, maxLength))
        for scalar in raw.unicodeScalars {
            switch scalar.value {
            case 48...57, 65...90, 97...122, 45, 95:
                result.unicodeScalars.append(scalar)
            default:
                result.append("_")
            }
        }
        while result.contains("__") {
            result = result.replacingOccurrences(of: "__", with: "_")
        }
        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
        let safe = trimmed.isEmpty ? fallback : trimmed
        return String(safe.prefix(maxLength))
    }

    private static func sha256Hex(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
