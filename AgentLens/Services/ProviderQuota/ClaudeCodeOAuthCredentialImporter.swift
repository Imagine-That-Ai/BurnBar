import Foundation

enum ClaudeCodeOAuthCredentialImportError: LocalizedError {
    case missing
    case malformed
    case expired

    var errorDescription: String? {
        switch self {
        case .missing:
            return "No readable Claude Code OAuth token was found. Sign in with Claude Code, then try again."
        case .malformed:
            return "Claude Code returned an OAuth credential shape OpenBurnBar could not read."
        case .expired:
            return "Claude Code's OAuth token is expired. Sign in with Claude Code again, then try again."
        }
    }
}

/// User-initiated importer for the local Claude Code OAuth credential.
///
/// This is intentionally separate from background quota refresh. OpenBurnBar
/// does not scrape Claude Code credentials silently; this path only runs when
/// the user explicitly asks the Accounts wizard to use the already-signed-in
/// Claude Code session as a BurnBar route credential.
struct ClaudeCodeOAuthCredentialImporter {
    static let keychainService = "Claude Code-credentials"

    private let keychain: KeychainStore
    private let accounts: [String]
    private let configDirectory: String?
    private let allowDefaultKeychainFallback: Bool

    init(
        keychain: KeychainStore = KeychainStore(service: keychainService, legacyServices: []),
        accounts: [String] = [NSUserName()],
        configDirectory: String? = nil,
        allowDefaultKeychainFallback: Bool = true
    ) {
        self.keychain = keychain
        self.configDirectory = configDirectory?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        self.allowDefaultKeychainFallback = allowDefaultKeychainFallback
        self.accounts = accounts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func load(allowUserInteraction: Bool = true) throws -> ClaudeOAuthCredentials {
        var sawMalformedPayload = false

        if let configDirectory {
            for url in credentialFileCandidates(configDirectory: configDirectory) {
                guard let data = try? Data(contentsOf: url) else { continue }
                guard let credentials = ClaudeCredentialsReader.decode(data) else {
                    sawMalformedPayload = true
                    continue
                }
                guard credentials.canCallUsageEndpoint() else {
                    throw ClaudeCodeOAuthCredentialImportError.expired
                }
                return credentials
            }
        }

        if configDirectory != nil, !allowDefaultKeychainFallback {
            if sawMalformedPayload {
                throw ClaudeCodeOAuthCredentialImportError.malformed
            }
            throw ClaudeCodeOAuthCredentialImportError.missing
        }

        for account in accounts {
            guard let payload = try keychain.string(for: account, allowUserInteraction: allowUserInteraction) else {
                continue
            }
            guard let data = payload.data(using: .utf8),
                  let credentials = ClaudeCredentialsReader.decode(data) else {
                sawMalformedPayload = true
                continue
            }
            guard credentials.canCallUsageEndpoint() else {
                throw ClaudeCodeOAuthCredentialImportError.expired
            }
            return credentials
        }

        if sawMalformedPayload {
            throw ClaudeCodeOAuthCredentialImportError.malformed
        }
        throw ClaudeCodeOAuthCredentialImportError.missing
    }

    private func credentialFileCandidates(configDirectory: String) -> [URL] {
        let root = URL(fileURLWithPath: configDirectory, isDirectory: true)
        return [
            root.appendingPathComponent(".credentials.json", isDirectory: false),
            root.appendingPathComponent("credentials.json", isDirectory: false),
        ]
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
