import Foundation

enum OpenBurnBarProviderCredentialNormalizer {
    static func routingAPIKey(providerID: String, rawSecret: String?) -> String? {
        guard let rawSecret else { return nil }
        let trimmed = rawSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard providerID.caseInsensitiveCompare("opencode") == .orderedSame else {
            return trimmed
        }

        guard trimmed.first == "{" || trimmed.first == "[" else {
            return trimmed
        }

        return openCodeAPIKey(from: trimmed)
    }

    private static func openCodeAPIKey(from rawSecret: String) -> String? {
        guard let data = rawSecret.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return findOpenCodeAPIKey(in: json)
    }

    private static func findOpenCodeAPIKey(in value: Any) -> String? {
        if let dictionary = value as? [String: Any] {
            if let openCodeGo = dictionary["opencode-go"],
               let key = findOpenCodeAPIKey(in: openCodeGo) {
                return key
            }

            if let key = dictionary["key"] as? String {
                let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }

        if let array = value as? [Any] {
            for item in array {
                guard let dictionary = item as? [String: Any],
                      let openCodeGo = dictionary["opencode-go"],
                      let key = findOpenCodeAPIKey(in: openCodeGo) else {
                    continue
                }
                return key
            }
        }

        if let dictionary = value as? [String: Any] {
            for keyName in ["opencodeGo", "opencode_go", "opencode"] {
                if let candidate = dictionary[keyName],
                   let key = findOpenCodeAPIKey(in: candidate) {
                    return key
                }
            }
        }

        return nil
    }
}
