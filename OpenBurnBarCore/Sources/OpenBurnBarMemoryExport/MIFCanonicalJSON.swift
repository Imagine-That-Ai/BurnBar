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
                // reason: key came from members.keys
                // swiftlint:disable:next force_unwrapping
                write(members[key]!, into: &out)
            }
            out += "}"
        }
    }

    /// Shortest decimal that round-trips back to the same `Double`. Swift's
    /// `description` is already shortest-round-trip (Errol/Ryu), but it renders
    /// integral values as `1.0` and uses a different scientific notation than
    /// ECMAScript `Number.prototype.toString`, which JCS defers to: Swift
    /// `1e-06` where ECMAScript prints `0.000001` (the plain-decimal window
    /// reaches an exponent of −5), Swift `1e-07` where ECMAScript prints
    /// `1e-7` (its exponents are never zero-padded), and Swift `1e+21` where
    /// ECMAScript switches only at 1e21 — one order later than a guesser
    /// assumes (review #2564).
    ///
    /// The rewrite keeps Swift's shortest-round-trip DIGITS — computing those
    /// is the hard half and Swift already does it — and re-renders the
    /// exponent under ECMAScript's rules: with `s` the digit string of length
    /// `k` and `n` the exponent such that `value = s × 10^(n−k)`, print plain
    /// decimal while `−6 < n ≤ 21` and `d[.ddd]e±(n−1)` outside it.
    static func numberLiteral(_ value: Double) -> String {
        guard value.isFinite else { return "null" }
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        var text = String(value)
        var negative = false
        if text.hasPrefix("-") {
            negative = true
            text.removeFirst()
        }
        // `mantissa e exp`: split the two, then walk the mantissa counting
        // the digits left of its point into `n`.
        let halves = text.split(separator: "e", omittingEmptySubsequences: false)
        var n = halves.count > 1 ? Int(halves[1]) ?? 0 : 0
        var digits = ""
        var leftOfPoint = true
        for character in halves[0] {
            if character == "." {
                leftOfPoint = false
                continue
            }
            digits.append(character)
            if leftOfPoint { n += 1 }
        }
        // Leading zeros are padding, not digits: "0.75" scans as s="075" and
        // every stripped zero moves the decimal point one place left.
        let stripped = digits.drop(while: { $0 == "0" })
        n -= digits.count - stripped.count
        digits = String(stripped)
        // Trailing zeros are padding too — Swift renders integral doubles
        // below 1e16 as "NNN.0", whose ".0" would otherwise inflate k — and
        // ECMAScript's k is as small as possible: "1000000000000000.0" is s=1,
        // not s=10000000000000000.
        digits = String(digits.reversed().drop(while: { $0 == "0" }).reversed())
        if digits.isEmpty { digits = "0" }
        let k = digits.count
        let sign = negative ? "-" : ""
        if k <= n, n <= 21 {
            return sign + digits + String(repeating: "0", count: n - k)
        }
        if n > 0, n <= 21 {
            let point = digits.index(digits.startIndex, offsetBy: n)
            return sign + String(digits[..<point]) + "." + String(digits[point...])
        }
        if n > -6, n <= 0 {
            return sign + "0." + String(repeating: "0", count: -n) + digits
        }
        let exponent = n - 1
        let head = String(digits.prefix(1))
        let rest = String(digits.dropFirst())
        return sign + head
            + (rest.isEmpty ? "" : "." + rest)
            + "e" + (exponent < 0 ? "-" : "+") + String(abs(exponent))
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

// MARK: - Reader

/// The inverse of `serialize`, for the one job that needs it: recomputing
/// `content_digest` from a `manifest.json` **on disk** rather than from the
/// exporter's memory of it (review F-1). A verifier that re-canonicalises has
/// to parse into the same closed value tree the writer emits from — via
/// `JSONSerialization` a JSON `true` and a JSON `1` both arrive as `NSNumber`
/// and the round trip is platform-dependent, which is exactly the property JCS
/// exists to remove.
///
/// Strict on purpose: trailing bytes, a bare fragment's stray comma, a
/// truncated escape and a non-finite literal are all `nil` rather than a
/// best-effort value, because the caller's next act is to hash the result.
extension MIFCanonicalJSON {

    public static func parse(_ data: Data) -> MIFJSON? {
        var reader = Reader(bytes: [UInt8](data))
        guard let value = reader.parseValue() else { return nil }
        reader.skipWhitespace()
        guard reader.isAtEnd else { return nil }
        return value
    }

    struct Reader {
        let bytes: [UInt8]
        var index = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        var isAtEnd: Bool { index >= bytes.count }

        mutating func skipWhitespace() {
            while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x09
                || bytes[index] == 0x0A || bytes[index] == 0x0D {
                index += 1
            }
        }

        mutating func parseValue() -> MIFJSON? {
            skipWhitespace()
            guard index < bytes.count else { return nil }
            switch bytes[index] {
            case UInt8(ascii: "{"): return parseObject()
            case UInt8(ascii: "["): return parseArray()
            case UInt8(ascii: "\""): return parseString().map(MIFJSON.string)
            case UInt8(ascii: "t"): return literal("true").map { _ in .bool(true) }
            case UInt8(ascii: "f"): return literal("false").map { _ in .bool(false) }
            case UInt8(ascii: "n"): return literal("null").map { _ in .null }
            default: return parseNumber()
            }
        }

        private mutating func literal(_ text: String) -> Bool? {
            let expected = [UInt8](text.utf8)
            guard index + expected.count <= bytes.count,
                  Array(bytes[index..<(index + expected.count)]) == expected else { return nil }
            index += expected.count
            return true
        }

        private mutating func parseObject() -> MIFJSON? {
            index += 1
            var members: [String: MIFJSON] = [:]
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
                index += 1
                return .object(members)
            }
            while true {
                skipWhitespace()
                guard let key = parseString() else { return nil }
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { return nil }
                index += 1
                guard let value = parseValue() else { return nil }
                // A duplicate key has no canonical reading, so it is a refusal
                // rather than a last-one-wins guess.
                guard members.updateValue(value, forKey: key) == nil else { return nil }
                skipWhitespace()
                guard index < bytes.count else { return nil }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(members) }
                return nil
            }
        }

        private mutating func parseArray() -> MIFJSON? {
            index += 1
            var items: [MIFJSON] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
                index += 1
                return .array(items)
            }
            while true {
                guard let value = parseValue() else { return nil }
                items.append(value)
                skipWhitespace()
                guard index < bytes.count else { return nil }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
                return nil
            }
        }

        private mutating func parseString() -> String? {
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { return nil }
            index += 1
            var scalars = String.UnicodeScalarView()
            var pendingHighSurrogate: UInt32?
            while index < bytes.count {
                let byte = bytes[index]
                if byte == UInt8(ascii: "\"") {
                    index += 1
                    guard pendingHighSurrogate == nil else { return nil }
                    return String(scalars)
                }
                if byte == UInt8(ascii: "\\") {
                    index += 1
                    guard index < bytes.count else { return nil }
                    let escape = bytes[index]
                    index += 1
                    if escape == UInt8(ascii: "u") {
                        guard let code = hex4() else { return nil }
                        if let high = pendingHighSurrogate {
                            guard code >= 0xDC00, code <= 0xDFFF else { return nil }
                            let combined = 0x10000 + ((high - 0xD800) << 10) + (code - 0xDC00)
                            guard let scalar = Unicode.Scalar(combined) else { return nil }
                            scalars.append(scalar)
                            pendingHighSurrogate = nil
                        } else if code >= 0xD800, code <= 0xDBFF {
                            pendingHighSurrogate = code
                        } else {
                            guard code < 0xD800 || code > 0xDFFF,
                                  let scalar = Unicode.Scalar(code) else { return nil }
                            scalars.append(scalar)
                        }
                        continue
                    }
                    guard pendingHighSurrogate == nil else { return nil }
                    switch escape {
                    case UInt8(ascii: "\""): scalars.append("\"")
                    case UInt8(ascii: "\\"): scalars.append("\\")
                    case UInt8(ascii: "/"): scalars.append("/")
                    case UInt8(ascii: "b"): scalars.append(Unicode.Scalar(0x08))
                    case UInt8(ascii: "f"): scalars.append(Unicode.Scalar(0x0C))
                    case UInt8(ascii: "n"): scalars.append("\n")
                    case UInt8(ascii: "r"): scalars.append("\r")
                    case UInt8(ascii: "t"): scalars.append("\t")
                    default: return nil
                    }
                    continue
                }
                guard pendingHighSurrogate == nil, byte >= 0x20 else { return nil }
                // Copy the whole UTF-8 sequence, so a multi-byte scalar is not
                // split into replacement characters one byte at a time.
                let width = byte < 0x80 ? 1 : (byte >= 0xF0 ? 4 : (byte >= 0xE0 ? 3 : 2))
                guard index + width <= bytes.count,
                      let text = String(bytes: bytes[index..<(index + width)], encoding: .utf8) else { return nil }
                scalars.append(contentsOf: text.unicodeScalars)
                index += width
            }
            return nil
        }

        private mutating func hex4() -> UInt32? {
            guard index + 4 <= bytes.count,
                  let text = String(bytes: bytes[index..<(index + 4)], encoding: .utf8),
                  let value = UInt32(text, radix: 16) else { return nil }
            index += 4
            return value
        }

        private mutating func parseNumber() -> MIFJSON? {
            let start = index
            var isInteger = true
            while index < bytes.count {
                let byte = bytes[index]
                if byte == UInt8(ascii: ".") || byte == UInt8(ascii: "e") || byte == UInt8(ascii: "E") {
                    isInteger = false
                } else if (byte < UInt8(ascii: "0") || byte > UInt8(ascii: "9"))
                    && byte != UInt8(ascii: "-") && byte != UInt8(ascii: "+") {
                    break
                }
                index += 1
            }
            guard index > start,
                  let text = String(bytes: bytes[start..<index], encoding: .utf8) else { return nil }
            if isInteger, let value = Int(text) { return .int(value) }
            guard let value = Double(text), value.isFinite else { return nil }
            return .double(value)
        }
    }
}
