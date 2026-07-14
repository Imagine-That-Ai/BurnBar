import Foundation

/// Profile-scoped Claude Code keychain service naming (lifted from AgentLens importer).
public enum ClaudeProfileScopedKeychain {
    public static let defaultKeychainService = "Claude Code-credentials"

    public static func service(forConfigDirectory configDirectory: String) -> String {
        let normalized = configDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let digest = QuotaSHA256.hexDigest(normalized)
        return "\(defaultKeychainService)-\(digest.prefix(8))"
    }
}
