import Foundation

// MARK: - Grok CLI Event Shape Validation

/// Strict shape validation for Grok CLI `events.jsonl` event kinds
/// (round-3 scrutiny, issue 2). Extracted from `GrokCLIParser` to keep the
/// parser class within the lint type-body budget (repo precedent:
/// `BurnBarFleetFactoryDroidProbeParsing.swift`).
///
/// The non-usage event allowlist is NAME-AND-SHAPE: an allowlisted NAME
/// with a malformed payload (missing required fields, wrong primitive
/// types) must degrade the typed parse health, never be treated as healthy.
enum GrokCLIParserEventShapes {

    /// Known non-usage event kinds in `events.jsonl` (real sessions verified
    /// 2026-08-12): `mcp_config_resolved`, `turn_started`, `loop_started`,
    /// `first_token`. Any other event kind is unknown input and degrades the
    /// typed parse health instead of being silently accepted (round-2
    /// scrutiny, issue 3). New event kinds must be added here deliberately.
    static let knownNonUsageEventTypes: Set<String> = [
        "mcp_config_resolved", "turn_started", "loop_started", "first_token"
    ]

    /// Strict shape validation for allowlisted non-usage event kinds.
    ///
    /// Required fields and primitive types per kind (real sessions verified
    /// 2026-08-12; pinned in docs/fleet/BURNBAR_FLEET_SIGNALS.md §6):
    /// - `mcp_config_resolved`: `servers` array, `disabled` array.
    /// - `turn_started`: string `session_id`, integer `turn_number`, string
    ///   `model_id`, boolean `yolo_mode`, integer
    ///   `conversation_message_count`, string `session_relationship`,
    ///   `schema_version` (string or integer — real sessions carry both
    ///   `"1.0"` and `1`).
    /// - `loop_started`: integer `loop_index`.
    /// - `first_token`: no required fields.
    ///
    /// Integer fields reject JSON booleans and fractional/non-integral
    /// values (strict primitive validation, mirroring the daemon's
    /// NSNumber-boolean rejection). Absent optional fields are acceptable;
    /// a PRESENT field with the wrong type is malformed.
    static func isValidAllowlistedEventShape(_ json: [String: Any]) -> Bool {
        guard let type = json["type"] as? String else { return false }
        switch type {
        case "mcp_config_resolved":
            guard json["servers"] is [Any], json["disabled"] is [Any] else { return false }
        case "turn_started":
            guard json["session_id"] is String,
                  isStrictIntField(json["turn_number"]),
                  json["model_id"] is String,
                  isStrictBoolField(json["yolo_mode"]),
                  isStrictIntField(json["conversation_message_count"]),
                  json["session_relationship"] is String,
                  isSchemaVersionField(json["schema_version"]) else { return false }
        case "loop_started":
            guard isStrictIntField(json["loop_index"]) else { return false }
        case "first_token":
            break
        default:
            return false
        }
        return true
    }

    /// True when the value is absent/null or a strict non-negative integer
    /// (booleans, fractional values, and non-numeric values are rejected).
    static func isStrictIntField(_ value: Any?) -> Bool {
        guard let value, !(value is NSNull) else { return true }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              let int64 = exactInt64(number),
              int64 >= 0 else { return false }
        return true
    }

    /// True when the value is absent/null or a JSON boolean (numbers and
    /// strings are rejected).
    static func isStrictBoolField(_ value: Any?) -> Bool {
        guard let value, !(value is NSNull) else { return true }
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// `schema_version` is a string or an integer in real sessions
    /// (verified 2026-08-12: both `"1.0"` and `1` occur).
    static func isSchemaVersionField(_ value: Any?) -> Bool {
        guard let value, !(value is NSNull) else { return true }
        if value is String { return true }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              exactInt64(number) != nil else { return false }
        return true
    }

    /// Exact JSON-number → Int64 conversion. Integer-backed NSNumber values
    /// bridge directly; floating-point-backed values convert only when the
    /// value is finite and integral (fractional values are rejected, and
    /// `Int64(exactly:)` returns nil for values beyond the representable
    /// range — including the Double(Int64.max) boundary trap, which rounds
    /// to 2^63).
    static func exactInt64(_ number: NSNumber) -> Int64? {
        let type = String(cString: number.objCType)
        if type == "d" || type == "f" {
            let double = number.doubleValue
            guard double.isFinite else { return nil }
            return Int64(exactly: double)
        }
        return number as? Int64
    }
}
