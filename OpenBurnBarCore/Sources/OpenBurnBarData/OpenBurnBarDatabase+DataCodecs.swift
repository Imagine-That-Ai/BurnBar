import Foundation

extension OpenBurnBarDatabase {

    static func sqlPlaceholders(count: Int) -> String {
        Array(repeating: "?", count: max(0, count)).joined(separator: ", ")
    }

    // MARK: - Date Parsing

    static let sqliteDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    static func sqliteDateString(_ date: Date) -> String {
        sqliteDateFormatter.string(from: date)
    }

    /// Local formatters rather than `static let ISO8601DateFormatter` caches:
    /// those stored properties are not Sendable and fail Linux / Swift
    /// consumer-contract `#MutableGlobalVariable`. The Mac twin uses
    /// `ThreadSafeISO8601DateFormatter` from Kernel; Data stays Foundation+GRDB
    /// so `OpenBurnBarCore/Package.swift` (a control-plane digest artifact)
    /// does not grow a Kernel edge for this fallback path.
    private static func parseISO8601Date(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) {
            return date
        }
        let basic = ISO8601DateFormatter()
        basic.formatOptions = [.withInternetDateTime]
        return basic.date(from: string)
    }

    static func parseDateValue(_ value: Any?) -> Date? {
        if let date = value as? Date { return date }
        if let timeInterval = value as? TimeInterval {
            return Date(timeIntervalSince1970: timeInterval)
        }
        if let intValue = value as? Int {
            return Date(timeIntervalSince1970: TimeInterval(intValue))
        }
        if let int64Value = value as? Int64 {
            return Date(timeIntervalSince1970: TimeInterval(int64Value))
        }
        if let number = value as? NSNumber {
            return Date(timeIntervalSince1970: number.doubleValue)
        }
        if let string = value as? String {
            if let parsed = sqliteDateFormatter.date(from: string) { return parsed }
            return parseISO8601Date(string)
        }
        return nil
    }

    static func parseBoolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? Int { return value != 0 }
        if let value = value as? Int64 { return value != 0 }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String {
            switch value.lowercased() {
            case "1", "true", "yes":
                return true
            case "0", "false", "no":
                return false
            default:
                return nil
            }
        }
        return nil
    }

    // MARK: - JSON Helpers

    static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    static func decodeJSONStringArray(_ string: String?) -> [String] {
        guard let string, !string.isEmpty, let data = string.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { // try?-ok(decode fallback empty)
            return []
        }
        return arr
    }

    /// Encode a `[String]` to a JSON column value.
    ///
    /// This is throwing on purpose: a silent `try?` here would yield `"[]"` on
    /// encode failure, which — when written to a `keyFiles`/`keyCommands`/`keyTools`
    /// column — would overwrite a real array with an empty list (silent data loss).
    /// Callers persist this inside throwing `dbQueue.write` blocks, so propagating
    /// fails the whole insert closed instead of committing a lossy empty value.
    static func encodeJSONStringArray(_ array: [String]) throws -> String {
        try encodeJSON(array)
    }

    static func encodeTranscriptPieces(_ value: [ChatTranscriptPiece]) throws -> String {
        try encodeJSON(value)
    }

    static func decodeTranscriptPieces(_ string: String?) -> [ChatTranscriptPiece]? {
        guard let string, !string.isEmpty, let data = string.data(using: .utf8),
              let arr = try? JSONDecoder().decode([ChatTranscriptPiece].self, from: data) else { // try?-ok(decode fallback nil)
            return nil
        }
        return arr
    }

    static func encodeChatAttachments(_ value: [HermesAttachment]) throws -> String {
        try encodeJSON(value)
    }

    static func decodeChatAttachments(_ string: String?) -> [HermesAttachment]? {
        guard let string, !string.isEmpty, let data = string.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode([HermesAttachment].self, from: data) // try?-ok(decode fallback nil)
    }
}
