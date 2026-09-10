import FirebaseFunctions
import Foundation
import OpenBurnBarCore

extension SessionLogSyncService {
    static func dictionary<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        guard let dictionary = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudSessionLogUploadError.encodingFailed
        }
        return dictionary
    }

    static func jsonData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    static var iso8601: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    static func isPermissionDeniedFunctionsError(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == FunctionsErrorDomain,
              let code = FunctionsErrorCode(rawValue: nsError.code) else {
            return false
        }
        return code == .permissionDenied || code == .unauthenticated || code == .failedPrecondition
    }

    private static func normalizedTerms(from text: String) -> [String] {
        let stopwords: Set<String> = ["the", "and", "for", "with", "that", "this", "from", "how", "what", "where", "when", "why", "are", "was"]
        let parts = text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 && !stopwords.contains($0) }
        var seen = Set<String>()
        var terms: [String] = []
        for part in parts where seen.insert(part).inserted {
            terms.append(part)
            if terms.count >= 250 { break }
        }
        return terms
    }
}
