import Foundation

/// Tolerant JSON value coercion shared by the Hermes wire decoders.
///
/// `HermesService` (session / session-message / profile / job parsing) and
/// `HermesStreamingEngine` (SSE event handling) both consume loosely-shaped
/// JSON from Hermes runtimes that disagree on field naming and value types.
/// These helpers were moved verbatim from `HermesService` so both sides keep
/// byte-identical coercion behavior.
@MainActor
enum HermesWireValueParsing {
    static func stringValue(_ value: Any?) -> String? {
        if let value = value as? String,
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value
        }
        return nil
    }

    static func modelNameValue(item: [String: Any]) -> String? {
        stringValue(item["model"])
            ?? stringValue(item["model_id"])
            ?? stringValue(item["modelId"])
            ?? stringValue(item["model_name"])
            ?? stringValue(item["modelName"])
            ?? stringValue(item["selected_model"])
            ?? stringValue(item["selectedModel"])
    }

    static func tokenCountSourceValue(_ value: Any?) -> HermesTokenCountSource? {
        guard let rawValue = stringValue(value) else { return nil }
        if let source = HermesTokenCountSource(rawValue: rawValue) {
            return source
        }
        switch rawValue.lowercased() {
        case "provider", "provider_usage", "exact":
            return .providerUsage
        case "estimated", "estimated_text", "approximate":
            return .estimatedText
        default:
            return nil
        }
    }

    static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double { return Int(value) }
        if let value = value as? String { return Int(value) }
        return nil
    }

    static func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String {
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        }
        return nil
    }

    static func dateValue(_ value: Any?) -> Date? {
        if let value = value as? Date { return value }
        if let value = value as? TimeInterval { return Date(timeIntervalSince1970: value) }
        guard let value = value as? String else { return nil }
        return Self.iso8601WithFractionalSeconds.date(from: value) ?? Self.iso8601.date(from: value)
    }

    private static let iso8601WithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601 = ISO8601DateFormatter()
}
