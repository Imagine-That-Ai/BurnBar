// SPDX-License-Identifier: AGPL-3.0-only
//
// MIFCanonicalJSON — RFC 8785 (JCS) canonicalisation for the Memory Interchange
// Format.
//
// `MEMORY_MIGRATION_SPEC.md` §2 claims determinism on `content_digest` and on
// the manifest minus its volatile fields, with `canonicalization: "JCS"`. That
// claim is only checkable if one serializer owns every byte the bundle emits,
// so nothing in this target reaches for `JSONSerialization` or `JSONEncoder`:
// both leave number formatting and key order to the platform, and the spec's
// determinism property is exactly a statement about those two things.
//
// The value tree is deliberately a closed enum rather than `Any`. A record type
// therefore cannot accidentally carry a `Date`, an `NSNumber` or a nested
// dictionary whose key order is undefined, and `additionalProperties: false` in
// `contracts/mif-v1.schema.json` stays enforceable from the writing side too.

import Foundation

/// A JSON value restricted to what MIF records may contain.
public enum MIFJSON: Sendable, Equatable {
    case null
    case bool(Bool)
    /// Integers stay integers. JCS serialises them without an exponent or a
    /// fractional part, which is what every `ts_ms` / `row_count` field needs.
    case int(Int)
    /// Doubles are emitted as the shortest round-trip decimal. `confidence` is
    /// the only such field, and it travels beside `confidence_bits` precisely
    /// because a decimal is a lossy way to compare two doubles.
    case double(Double)
    case string(String)
    case array([MIFJSON])
    case object([String: MIFJSON])

    /// Convenience for optionals: `nil` becomes an explicit JSON `null` rather
    /// than an absent key, because most MIF fields are `["string", "null"]` and
    /// dropping the key would change which schema branch applies.
    public static func string(_ value: String?) -> MIFJSON {
        value.map { MIFJSON.string($0) } ?? .null
    }

    public static func int(_ value: Int?) -> MIFJSON {
        value.map { MIFJSON.int($0) } ?? .null
    }

    public static func strings(_ values: [String]) -> MIFJSON {
        .array(values.map { MIFJSON.string($0) })
    }
}

public enum MIFCanonicalJSON {

    /// Serialise `value` per RFC 8785: no insignificant whitespace, object keys
    /// sorted by their UTF-16 code units, shortest round-trip numbers, and the
    /// JSON string escapes RFC 8785 §3.2.2.2 pins.
    public static func serialize(_ value: MIFJSON) -> String {
        var out = ""
        write(value, into: &out)
        return out
    }

    public static func data(_ value: MIFJSON) -> Data {
        Data(serialize(value).utf8)
    }

    // MARK: - Writer

    private static func write(_ value: MIFJSON, into out: inout String) {
        switch value {
        case .null:
            out += "null"
        case .bool(let flag):
            out += flag ? "true" : "false"
        case .int(let number):
            out += String(number)
        case .double(let number):
            out += numberLiteral(number)
        case .string(let text):
            writeString(text, into: &out)
        case .array(let items):
            out += "["
            for (index, item) in items.enumerated() {
                if index > 0 { out += "," }
                write(item, into: &out)
            }
            out += "]"
        case .object(let members):
            out += "{"
            // RFC 8785 §3.2.3: sort on the UTF-16 code units of the key, which
            // is `String`'s own `utf16` view — NOT its default Unicode-aware
            // `<`, and not UTF-8 byte order. They agree on ASCII keys (all of
            // ours today) and diverge above U+FFFF, so encode the rule rather
            // than the coincidence.
            let ordered = members.keys.sorted { lhs, rhs in
                lhs.utf16.lexicographicallyPrecedes(rhs.utf16)
            }
            for (index, key) in ordered.enumerated() {
                if index > 0 { out += "," }
                writeString(key, into: &out)
                out += ":"
                // swiftlint:disable:next force_unwrapping reason: key came from members.keys
                write(members[key]!, into: &out)
            }
            out += "}"
        }
    }

    /// Shortest decimal that round-trips back to the same `Double`. Swift's
    /// `description` is already shortest-round-trip (Errol/Ryu), but it renders
    /// integral values as `1.0` and large ones in exponent form, neither of
    /// which matches ECMAScript `Number.prototype.toString` that JCS defers to.
    static func numberLiteral(_ value: Double) -> String {
        guard value.isFinite else { return "null" }
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(value)
    }

    private static func writeString(_ text: String, into out: inout String) {
        out += "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}
