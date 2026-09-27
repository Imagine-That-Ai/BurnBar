import Foundation

// Lenient typed decoding for schemaless vendor JSON: a field of an unexpected
// type reads as absent instead of failing the whole document, matching the
// tolerance of `as?` reads without an untyped dictionary.

struct QuotaJSONKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(_ stringValue: String) { self.stringValue = stringValue }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// First non-empty string among `keys` in the decoder's object, if any.
func quotaLenientString(_ decoder: Decoder, keys: String...) -> String? {
    let container = try? decoder.container(keyedBy: QuotaJSONKey.self)
    for key in keys {
        if let value = (try? container?.decodeIfPresent(String.self, forKey: QuotaJSONKey(key))) ?? nil,
           !value.isEmpty {
            return value
        }
    }
    return nil
}

func quotaLenientString(_ decoder: Decoder, key: String) -> String? {
    quotaLenientString(decoder, keys: key)
}

/// A number, or a numeric string, at `key`.
func quotaLenientNumber(_ decoder: Decoder, key: String) -> Double? {
    let container = try? decoder.container(keyedBy: QuotaJSONKey.self)
    if let number = (try? container?.decodeIfPresent(Double.self, forKey: QuotaJSONKey(key))) ?? nil {
        return number
    }
    return quotaLenientString(decoder, key: key)
        .flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
}

/// A nested `T` at `key`, or nil when absent or of another shape.
func quotaLenientValue<T: Decodable>(_ type: T.Type, _ decoder: Decoder, key: String) -> T? {
    let container = try? decoder.container(keyedBy: QuotaJSONKey.self)
    return (try? container?.decodeIfPresent(T.self, forKey: QuotaJSONKey(key))) ?? nil
}
