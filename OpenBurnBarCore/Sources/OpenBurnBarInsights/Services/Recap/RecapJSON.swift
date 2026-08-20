import Foundation

/// Fence- and chatter-tolerant extraction of the first balanced JSON object
/// from a model response.
///
/// String-aware: a brace inside a quoted string does not change nesting depth,
/// which a naive depth counter gets wrong the moment a headline contains one.
public enum RecapJSON {

    public static func extractFirstObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false

        for index in text.indices[start...] {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }
            switch character {
            case "\"":
                inString = true
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(text[start...index])
                }
            default:
                break
            }
        }
        return nil
    }

    public static func decode<T: Decodable>(_ type: T.Type, from text: String) -> T? {
        guard let json = extractFirstObject(from: text),
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
