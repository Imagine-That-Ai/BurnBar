import Foundation
import OpenBurnBarEngine

// MARK: - BurnBarBridgeValue

/// Int-preserving JSON value for the provider API bridges.
///
/// The Anthropic / OpenAI-compatible / Responses / Ollama wire shapes are
/// genuinely schemaless in places (tool arguments, input schemas, passthrough
/// vendor fields), so the typed bridge models use this Codable enum for those
/// leaves instead of `Any`. Unlike `BurnBarJSONValue` it keeps integers exact
/// (`4096` re-encodes as `4096`, never `4096.0`), which preserves the wire
/// bytes of proxied passthrough bodies.
enum BurnBarBridgeValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([BurnBarBridgeValue])
    case object([String: BurnBarBridgeValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let object = try? container.decode([String: BurnBarBridgeValue].self) {
            self = .object(object)
        } else if let array = try? container.decode([BurnBarBridgeValue].self) {
            self = .array(array)
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            self = .int(int)
        } else if let double = try? container.decode(Double.self) {
            self = .double(double)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

extension BurnBarBridgeValue {
    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var array: [BurnBarBridgeValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var object: [String: BurnBarBridgeValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    subscript(key: String) -> BurnBarBridgeValue? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    /// Lenient integer read matching `BurnBarOpenAICompatibleProviderExecutor.intValue`:
    /// integers as-is, doubles truncated, JSON booleans as 1/0 (NSNumber
    /// bridging), numeric strings parsed, everything else nil.
    var asInt: Int? {
        switch self {
        case .int(let value):
            return value
        case .double(let value):
            guard value.isFinite,
                  value < Double(Int.max),
                  value > Double(Int.min) else {
                return nil
            }
            return Int(value)
        case .bool(let value):
            return value ? 1 : 0
        case .string(let value):
            return Int(value)
        case .null, .array, .object:
            return nil
        }
    }

    /// Integer read matching a plain `as? Int` Cocoa cast: integers as-is,
    /// whole doubles converted, fractional doubles rejected, JSON booleans as
    /// 1/0 (NSNumber bridging), strings rejected.
    var asIntStrict: Int? {
        switch self {
        case .int(let value):
            return value
        case .double(let value):
            guard value.isFinite,
                  value >= Double(Int.min),
                  value <= Double(Int.max),
                  value == value.rounded(.towardZero) else {
                return nil
            }
            return Int(value)
        case .bool(let value):
            return value ? 1 : 0
        case .null, .array, .object, .string:
            return nil
        }
    }

    /// Lenient integer read matching the Anthropic executor's `max(1, ...)` helper.
    var asPositiveInt: Int? {
        asInt.map { max(1, $0) }
    }

    /// Lenient integer read matching the Anthropic executor's `max(0, ...)` helper.
    var asNonNegativeInt: Int? {
        asInt.map { max(0, $0) }
    }

    /// Decode this value into a concrete Codable model via a JSON round-trip.
    func decoded<T: Decodable>(as type: T.Type) throws -> T {
        let data = try BurnBarBridgeJSON.encode(self, sortedKeys: false)
        return try JSONDecoder().decode(type, from: data)
    }

    /// Best-effort conversion from an untyped Cocoa value (for the two
    /// `Any?`-signature helpers the main executor still calls). Returns nil
    /// for nil/NSNull and for values that are not valid JSON.
    static func from(untyped value: Any?) -> BurnBarBridgeValue? {
        guard let value, value is NSNull == false else { return nil }
        if let string = value as? String { return .string(string) }
        guard JSONSerialization.isValidJSONObject(["v": value]),
              let data = try? JSONSerialization.data(withJSONObject: ["v": value]),
              let wrapped = try? JSONDecoder().decode([String: BurnBarBridgeValue].self, from: data) else {
            return nil
        }
        return wrapped["v"]
    }

}

// MARK: - Catch-all coding support

/// Dynamic key for structs that preserve unknown passthrough fields.
struct BurnBarBridgeCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

extension KeyedDecodingContainer where Key == BurnBarBridgeCodingKey {
    /// Decode every key not in `known` as a generic value (passthrough fields).
    func decodeExtras(excluding known: Set<String>) throws -> [String: BurnBarBridgeValue] {
        var extras: [String: BurnBarBridgeValue] = [:]
        for key in allKeys where known.contains(key.stringValue) == false {
            extras[key.stringValue] = try decode(BurnBarBridgeValue.self, forKey: key)
        }
        return extras
    }
}

extension KeyedEncodingContainer where Key == BurnBarBridgeCodingKey {
    mutating func encodeExtras(_ extras: [String: BurnBarBridgeValue]) throws {
        for (key, value) in extras {
            try encode(value, forKey: BurnBarBridgeCodingKey(stringValue: key))
        }
    }
}

extension KeyedDecodingContainer {
    /// Decode an optional bridge value preserving an explicit JSON null as
    /// `.null` (a missing key stays nil). Passthrough copies must forward
    /// explicit nulls exactly like the old `if let value = object[key]` chains.
    func decodeBridgeValue(forKey key: Key) throws -> BurnBarBridgeValue? {
        guard contains(key) else { return nil }
        return try decodeIfPresent(BurnBarBridgeValue.self, forKey: key) ?? .null
    }
}

// MARK: - Bridge JSON / SSE helpers

/// Shared encode/decode/SSE helpers for the provider bridges. Errors map to
/// `BurnBarProviderExecutorError.invalidResponse` like the untyped code did.
enum BurnBarBridgeJSON {
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw BurnBarProviderExecutorError.invalidResponse
        }
    }

    /// Decode a bridge entry-point document, mirroring the legacy
    /// `guard ... JSONSerialization ... as? [String: Any]` failure modes:
    /// malformed JSON rethrows the parse error, valid-but-not-an-object maps
    /// to `invalidResponse`.
    static func decodeBridgeRequest<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            _ = try JSONSerialization.jsonObject(with: data)
            throw BurnBarProviderExecutorError.invalidResponse
        }
    }

    static func encode(_ value: some Encodable, sortedKeys: Bool) throws -> Data {
        do {
            let encoder = JSONEncoder()
            if sortedKeys {
                encoder.outputFormatting = [.sortedKeys]
            }
            return try encoder.encode(value)
        } catch {
            throw BurnBarProviderExecutorError.invalidResponse
        }
    }

    static func encodeString(_ value: some Encodable, sortedKeys: Bool) throws -> String {
        String(decoding: try encode(value, sortedKeys: sortedKeys), as: UTF8.self)
    }

    /// Convert a typed model back into a generic value (for fields that also
    /// carry malformed client shapes through verbatim).
    static func bridgeValue(_ value: some Encodable) throws -> BurnBarBridgeValue {
        let data = try encode(value, sortedKeys: true)
        do {
            return try JSONDecoder().decode(BurnBarBridgeValue.self, from: data)
        } catch {
            throw BurnBarProviderExecutorError.invalidResponse
        }
    }

    /// Append one `data: <json>` SSE frame.
    static func appendSSEData(_ payload: some Encodable, to output: inout Data) throws {
        output.append(Data("data: \(try encodeString(payload, sortedKeys: false))\n\n".utf8))
    }

    /// Append one `event: <name>` + `data: <json>` SSE frame pair.
    static func appendNamedSSE(event: String, payload: some Encodable, to output: inout Data) throws {
        output.append(Data("event: \(event)\n".utf8))
        output.append(Data("data: \(try encodeString(payload, sortedKeys: false))\n\n".utf8))
    }

    /// Render one `data: <json>` SSE frame.
    static func sseData(_ payload: some Encodable) throws -> Data {
        Data("data: \(try encodeString(payload, sortedKeys: false))\n\n".utf8)
    }

    /// Split a buffered SSE body into its `data:` payloads, skipping `[DONE]`
    /// sentinels. Used by the buffered (non-incremental) stream translators.
    static func eventPayloads(from data: Data) -> [Data] {
        String(decoding: data, as: UTF8.self)
            .components(separatedBy: "\n\n")
            .compactMap { chunk -> Data? in
                var dataLines: [String] = []
                for line in chunk.split(separator: "\n", omittingEmptySubsequences: false) {
                    guard line.hasPrefix("data:") else { continue }
                    let dataLine = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                    if dataLine == "[DONE]" { return nil }
                    dataLines.append(dataLine)
                }
                guard !dataLines.isEmpty else { return nil }
                return dataLines.joined(separator: "\n").data(using: .utf8)
            }
    }
}
