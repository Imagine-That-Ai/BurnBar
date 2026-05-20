import CryptoKit
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
    private let profileKeychainStore: (String) -> KeychainStore
    private let externalKeychainPasswordReader: (String, String) -> String?
    private let accounts: [String]
    private let configDirectory: String?
    private let allowDefaultKeychainFallback: Bool

    init(
        keychain: KeychainStore = KeychainStore(service: keychainService, legacyServices: []),
        profileKeychainStore: @escaping (String) -> KeychainStore = {
            KeychainStore(service: $0, legacyServices: [])
        },
        externalKeychainPasswordReader: @escaping (String, String) -> String? = Self.readPasswordWithSecurityTool,
        accounts: [String] = [NSUserName()],
        configDirectory: String? = nil,
        allowDefaultKeychainFallback: Bool = true
    ) {
        self.keychain = keychain
        self.profileKeychainStore = profileKeychainStore
        self.externalKeychainPasswordReader = externalKeychainPasswordReader
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

        if let configDirectory {
            let service = Self.profileScopedKeychainService(configDirectory: configDirectory)
            if let credentials = try loadKeychainCredentials(
                from: profileKeychainStore(service),
                service: service,
                allowUserInteraction: allowUserInteraction,
                sawMalformedPayload: &sawMalformedPayload
            ) {
                return credentials
            }
        }

        if configDirectory != nil, !allowDefaultKeychainFallback {
            if sawMalformedPayload {
                throw ClaudeCodeOAuthCredentialImportError.malformed
            }
            throw ClaudeCodeOAuthCredentialImportError.missing
        }

        if let credentials = try loadKeychainCredentials(
            from: keychain,
            service: Self.keychainService,
            allowUserInteraction: allowUserInteraction,
            sawMalformedPayload: &sawMalformedPayload
        ) {
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

    static func profileScopedKeychainService(configDirectory: String) -> String {
        let normalizedDirectory = configDirectory
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let digest = SHA256.hash(data: Data(normalizedDirectory.utf8))
        let suffix = digest
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(8)
        return "\(keychainService)-\(suffix)"
    }

    private func loadKeychainCredentials(
        from keychain: KeychainStore,
        service: String,
        allowUserInteraction: Bool,
        sawMalformedPayload: inout Bool
    ) throws -> ClaudeOAuthCredentials? {
        for account in accounts {
            var payload: String?
            do {
                payload = try keychain.string(for: account, allowUserInteraction: allowUserInteraction)
            } catch {
                payload = nil
            }

            if allowUserInteraction,
               payload?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                payload = externalKeychainPasswordReader(service, account)
            }

            guard let payload = payload?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !payload.isEmpty else {
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
        return nil
    }

    private static func readPasswordWithSecurityTool(service: String, account: String) -> String? {
        #if os(macOS)
        let securityURL = URL(fileURLWithPath: "/usr/bin/security")
        guard FileManager.default.isExecutableFile(atPath: securityURL.path) else { return nil }

        let process = Process()
        process.executableURL = securityURL
        process.arguments = [
            "find-generic-password",
            "-w",
            "-s", service,
            "-a", account
        ]
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"
        ]

        let output = Pipe()
        let errorOutput = Pipe()
        process.standardOutput = output
        process.standardError = errorOutput

        do {
            try process.run()
        } catch {
            return nil
        }

        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            group.leave()
        }

        guard group.wait(timeout: .now() + 2) == .success else {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        #else
        return nil
        #endif
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
