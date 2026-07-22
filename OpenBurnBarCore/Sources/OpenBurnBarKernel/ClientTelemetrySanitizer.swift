import Foundation

public enum ClientTelemetrySanitizer {
    public static let redacted = "[REDACTED]"
    public static let truncatedValueSuffix = "...[TRUNCATED]"
    public static let maxSanitizedValueLength = 513

    private static let sensitiveKeys: Set<String> = [
        "token", "apikey", "api_key", "auth", "authorization", "bearer",
        "password", "secret", "cookie", "refreshtoken", "accesstoken", "idtoken",
        "credential", "privatekey", "x-api-key", "x_auth_token", "firebase_auth",
        "uid", "userid", "user_id", "firebaseuid", "firebase_uid",
        "email", "username", "name", "ip", "ipaddress", "ip_address",
        "prompt", "message", "content", "body", "chatbody", "projectname", "model",
        "project_name", "model_name", "model_id", "path", "filepath", "file_path",
        "directory", "url", "home", "ssh_key", "key_path", "private_key",
        "cert", "certificate", "session_log", "log_path", "db_path", "database_path"
    ]

    private static let sensitiveValuePatterns: [String] = [
        "sk-", "bearer ", "token=", "apikey=", "secret=", "password=",
        "/Users/", "/private/var/", "~", ".ssh", ".aws", ".env", "keychain", "BEGIN RSA",
        "BEGIN OPENSSH", "-----BEGIN", "firebase:"
    ]

    private static let sensitiveRegexPatterns: [String] = [
        #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,
        #"(?i)\bbearer\s+[A-Za-z0-9._-]+"#,
        #"\b(?=[A-Za-z0-9._-]{32,}\b)(?=[A-Za-z0-9._-]*[A-Za-z])(?=[A-Za-z0-9._-]*[0-9])[A-Za-z0-9._-]+\b"#
    ]

    public static func sanitizeStringMetadata(_ metadata: [String: String]) -> [String: String] {
        metadata.reduce(into: [String: String]()) { result, entry in
            result[entry.key] = sanitizeString(entry.value, key: entry.key)
        }
    }

    public static func sanitizeJSONObject(_ value: Any) -> Any {
        switch value {
        case let dictionary as [String: Any]:
            return sanitizeJSONDictionary(dictionary)
        case let dictionary as NSDictionary:
            var bridged: [String: Any] = [:]
            for (key, value) in dictionary {
                if let key = key as? String {
                    bridged[key] = value
                }
            }
            return sanitizeJSONDictionary(bridged)
        case let array as [Any]:
            return array.map { sanitizeJSONObject($0) }
        case let array as NSArray:
            return array.map { sanitizeJSONObject($0) }
        case let string as String:
            return sanitizeString(string, key: nil)
        default:
            return value
        }
    }

    public static func sanitizeJSONDictionary(_ dictionary: [String: Any]) -> [String: Any] {
        dictionary.reduce(into: [String: Any]()) { result, entry in
            if keyLooksSensitive(entry.key) {
                result[entry.key] = redacted
            } else {
                result[entry.key] = sanitizeJSONObject(entry.value)
            }
        }
    }

    /// Sanitizes a Sentry-style context map (`[section: [key: value]]`) while
    /// guaranteeing the nested shape is preserved. A blanket
    /// `sanitizeJSONObject(...) as? [String: [String: Any]]` would drop the whole
    /// map if any section name were treated as sensitive (it would collapse that
    /// section to a scalar and fail the cast). Sanitizing per-section never does.
    public static func sanitizeContext(_ context: [String: [String: Any]]) -> [String: [String: Any]] {
        context.mapValues { sanitizeJSONDictionary($0) }
    }

    public static func sanitizeString(_ value: String, key: String?) -> String {
        if let key, keyLooksSensitive(key) {
            return redacted
        }
        let lowerValue = value.lowercased()
        if sensitiveValuePatterns.contains(where: { lowerValue.contains($0.lowercased()) }) {
            return redacted
        }
        if sensitiveRegexPatterns.contains(where: { value.range(of: $0, options: .regularExpression) != nil }) {
            return redacted
        }
        if value.count > maxSanitizedValueLength - truncatedValueSuffix.count {
            let prefixLength = maxSanitizedValueLength - truncatedValueSuffix.count
            return String(value.prefix(prefixLength)) + truncatedValueSuffix
        }
        return value
    }

    public static func stableInstallIdentifier(
        defaults: UserDefaults = .standard,
        key: String
    ) -> String {
        if let existing = defaults.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let identifier = "install:\(UUID().uuidString.lowercased())"
        defaults.set(identifier, forKey: key)
        return identifier
    }

    private static func keyLooksSensitive(_ rawKey: String) -> Bool {
        let key = rawKey
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: ".", with: "_")
        return sensitiveKeys.contains(key)
            || sensitiveKeys.contains(where: { key.contains($0) })
    }
}
