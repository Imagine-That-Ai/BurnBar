import OpenBurnBarEngine
import OpenBurnBarLinuxSecurity
import Foundation
#if canImport(FoundationNetworking)
@preconcurrency import FoundationNetworking
#endif
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif

public actor BurnBarKeychainSecretStore: BurnBarProviderSecretStoring {
    public static let defaultService = "com.openburnbar.daemon.provider-secrets"
    public static let legacyCursorConnectorService = "com.openburnbar.cursor-connector"
    /// All Keychain services the app has used to store provider API keys.
    /// The daemon checks every one so credentials entered through any app
    /// version or code path are resolvable.
    public static let allLegacyServices: [String] = [
        "com.openburnbar.cursor-connector",
        "com.burnbar.cursor-connector",
        "com.agentlens.cursor-connector",
        "com.openburnbar.provider-api-keys",
        "com.burnbar.provider-api-keys"
    ]
    private static let logger = BurnBarDaemonLogger(category: "provider-secret-store")

    private let service: String
    private let legacyServices: [String]
    private let hermesCredentialPoolURL: URL?
    private let claudeCodeCredentialsURL: URL?
    private let claudeOAuthRefreshSession: URLSession
    private let linuxSecretCustodian: LinuxSecretCustodian

    public init(
        service: String = BurnBarKeychainSecretStore.defaultService,
        legacyServices: [String]? = nil,
        hermesCredentialPoolURL: URL? = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".hermes/auth.json", isDirectory: false),
        claudeCodeCredentialsURL: URL? = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json", isDirectory: false),
        fallbackSecretFileURL: URL? = BurnBarDaemonPaths.defaultProviderSecretContinuityURL,
        claudeOAuthRefreshSession: URLSession = .shared,
        linuxSecretCustodian: LinuxSecretCustodian = LinuxSecretStoreFactory.production()
    ) {
        self.service = service
        self.legacyServices = legacyServices ?? (
            service == Self.defaultService ? Self.allLegacyServices : []
        )
        self.hermesCredentialPoolURL = hermesCredentialPoolURL
        self.claudeCodeCredentialsURL = claudeCodeCredentialsURL
        self.claudeOAuthRefreshSession = claudeOAuthRefreshSession
        self.linuxSecretCustodian = linuxSecretCustodian
        if let fallbackSecretFileURL {
            // Legacy continuity vaults were plaintext JSON. They are no longer
            // trusted as a credential source; best-effort scrub stale copies.
            try? FileManager.default.removeItem(at: fallbackSecretFileURL)
        }
    }

    public func secret(for providerID: String) async throws -> String? {
        if let fakeOutputs = ProcessInfo.processInfo.environment["BURNBAR_FAKE_PROVIDER_OUTPUTS_FILE"],
           !fakeOutputs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "openburnbar-fake-provider-key-\(providerID)"
        }

        if Self.isCurrentClaudeCodeCredentialSlot(providerID),
           let ccToken = try await claudeCodeCredentialSecret(
            for: providerID,
            expectedOrganizationUuid: nil,
            enforceOrganizationMatch: false
           ) {
            return ccToken
        }

        let account = "provider.\(providerID).apiKey"
        var storedAnthropicCredentialRefreshFailed = false
        var failedAnthropicOrganizationUuid: String?
        var foundStoredSecret = false
        if let secret = try secret(forService: service, account: account) {
            foundStoredSecret = true
            if let routed = try await routeSecret(from: secret, providerID: providerID) {
                return routed
            }
            storedAnthropicCredentialRefreshFailed = Self.isExpiredClaudeOAuthSecret(secret, providerID: providerID)
            failedAnthropicOrganizationUuid = Self.organizationUuid(fromClaudeOAuthSecret: secret, providerID: providerID)
            // routeSecret returned nil: the stored OAuth token is expired and
            // refresh failed. Fall through to alternative credential sources
            // instead of returning an unusable expired token that would cause
            // a 401 on the live model refresh and block all models for this
            // provider until the next catalog rebuild.
        }
        for legacyService in legacyServices where legacyService != service {
            if let secret = try secret(forService: legacyService, account: account) {
                foundStoredSecret = true
                if let routed = try await routeSecret(from: secret, providerID: providerID) {
                    // Self-heal: promote the credential to the daemon's primary
                    // service so subsequent reads don't depend on the legacy
                    // service being readable. Best-effort — the routed secret is
                    // still returned even if promotion fails.
                    if !Self.isExpiredClaudeOAuthSecret(secret, providerID: providerID) {
                        try? await setSecret(secret, for: providerID)
                    }
                    return routed
                }
                storedAnthropicCredentialRefreshFailed = storedAnthropicCredentialRefreshFailed
                    || Self.isExpiredClaudeOAuthSecret(secret, providerID: providerID)
                if failedAnthropicOrganizationUuid == nil {
                    failedAnthropicOrganizationUuid = Self.organizationUuid(fromClaudeOAuthSecret: secret, providerID: providerID)
                }
            }
        }
        // Try Claude Code's own credential file or Keychain item as a fallback.
        // Claude Code maintains its own OAuth session with a separate refresh
        // token that may still be valid when the daemon's stored refresh token
        // has been revoked or expired, or when the daemon cannot read its own
        // provider Keychain entry (for example after a manual import).
        if Self.normalizedProviderID(providerID) == "anthropic",
           storedAnthropicCredentialRefreshFailed || !foundStoredSecret,
           let ccToken = try await claudeCodeCredentialSecret(
            for: providerID,
            expectedOrganizationUuid: failedAnthropicOrganizationUuid,
            enforceOrganizationMatch: storedAnthropicCredentialRefreshFailed
           ) {
            return ccToken
        }
        return hermesCredentialPoolSecret(for: providerID)
    }

    private func routeSecret(from storedSecret: String, providerID: String) async throws -> String? {
        let trimmed = storedSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard Self.normalizedProviderID(providerID) == "anthropic",
              var claudeCredential = BurnBarClaudeOAuthRouteCredential.decode(trimmed) else {
            return trimmed
        }

        if claudeCredential.isExpired() {
            if let refreshed = await refreshClaudeOAuthCredential(claudeCredential) {
                claudeCredential = refreshed
                try await setSecret(refreshed.encodedStorageSecret(), for: providerID)
            } else {
                // Refresh failed: return nil so callers can fall back to
                // alternative credential sources (Claude Code credentials,
                // Hermes pool, other credential slots). Returning the expired
                // access token would cause a 401 on the live model refresh,
                // which sets blocksRouting=true and blocks ALL models for this
                // provider until the next catalog rebuild.
                return nil
            }
        }

        return claudeCredential.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedProviderID(_ providerID: String) -> String {
        providerID
            .components(separatedBy: ".slot.")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func isCurrentClaudeCodeCredentialSlot(_ providerID: String) -> Bool {
        providerID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "anthropic.slot.current-claude-code-login"
    }

    private static func isExpiredClaudeOAuthSecret(_ storedSecret: String, providerID: String) -> Bool {
        guard normalizedProviderID(providerID) == "anthropic",
              let credential = BurnBarClaudeOAuthRouteCredential.decode(storedSecret) else {
            return false
        }
        return credential.isExpired()
    }

    private static func organizationUuid(fromClaudeOAuthSecret storedSecret: String, providerID: String) -> String? {
        guard normalizedProviderID(providerID) == "anthropic" else { return nil }
        return BurnBarClaudeOAuthRouteCredential.decode(storedSecret)?.organizationUuid
    }

    private func refreshClaudeOAuthCredential(
        _ credential: BurnBarClaudeOAuthRouteCredential
    ) async -> BurnBarClaudeOAuthRouteCredential? {
        guard let refreshToken = credential.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !refreshToken.isEmpty,
              let url = URL(string: "https://platform.claude.com/v1/oauth/token") else {
            return nil
        }

        let formAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        func encode(_ value: String) -> String {
            value.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? value
        }

        let body = [
            "grant_type=refresh_token",
            "refresh_token=\(encode(refreshToken))",
            "client_id=\(encode(BurnBarClaudeOAuthRouteCredential.clientID))"
        ].joined(separator: "&")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Claude-Code/2.1 (OpenBurnBar route refresh)", forHTTPHeaderField: "User-Agent")
        request.httpBody = Data(body.utf8)

        do {
            let (data, response) = try await claudeOAuthRefreshSession.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let newAccessToken = (json["access_token"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !newAccessToken.isEmpty else {
                return nil
            }
            let newRefreshToken = (json["refresh_token"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty ?? refreshToken
            let expiresValue = json["expires_in"]
            let expiresIn: Double
            if let seconds = expiresValue as? Double {
                expiresIn = seconds
            } else if let seconds = expiresValue as? Int {
                expiresIn = Double(seconds)
            } else {
                expiresIn = 8 * 60 * 60
            }
            return credential.refreshed(
                accessToken: newAccessToken,
                refreshToken: newRefreshToken,
                expiresAt: Date().addingTimeInterval(expiresIn)
            )
        } catch {
            return nil
        }
    }

    private func secret(forService service: String, account: String) throws -> String? {
#if canImport(Security) && canImport(LocalAuthentication)
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
            kSecUseAuthenticationContext as String: context
        ]
        var item: CFTypeRef?
        let status = withKeychainUserInteractionDisabled {
            SecItemCopyMatching(query as CFDictionary, &item)
        }
        if status == errSecItemNotFound
            || status == errSecInteractionNotAllowed
            || status == errSecUserCanceled
            || status == errSecAuthFailed {
            return nil
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        guard let data = item as? Data else {
            return nil
        }
        let decoded = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return decoded?.isEmpty == false ? decoded : nil
#elseif os(Linux)
        do {
            return try linuxSecretCustodian.requireHighValueSecret(
                id: "\(service):\(account)",
                secretClass: .providerCredential
            ).secret
        } catch LinuxSecretStoreError.missingSecret(_) {
            return nil
        }
#else
        return nil
#endif
    }

    public func setSecret(_ secret: String?, for providerID: String) async throws {
        if let fakeOutputs = ProcessInfo.processInfo.environment["BURNBAR_FAKE_PROVIDER_OUTPUTS_FILE"],
           !fakeOutputs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }

#if canImport(Security) && canImport(LocalAuthentication)
        let account = "provider.\(providerID).apiKey"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        if let secret, !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let data = Data(secret.utf8)
            let deleteStatus = withKeychainUserInteractionDisabled {
                SecItemDelete(query as CFDictionary)
            }
            guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(deleteStatus))
            }

            var createQuery = query
            createQuery[kSecValueData as String] = data
            createQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = withKeychainUserInteractionDisabled {
                SecItemAdd(createQuery as CFDictionary, nil)
            }
            if addStatus == errSecDuplicateItem {
                let attributes: [String: Any] = [
                    kSecValueData as String: data,
                    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                ]
                let updateStatus = withKeychainUserInteractionDisabled {
                    SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
                }
                guard updateStatus == errSecSuccess else {
                    throw NSError(domain: NSOSStatusErrorDomain, code: Int(updateStatus))
                }
            } else if addStatus != errSecSuccess {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus))
            }
        } else {
            let deleteStatus = withKeychainUserInteractionDisabled {
                SecItemDelete(query as CFDictionary)
            }
            guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(deleteStatus))
            }
        }
#elseif os(Linux)
        let account = "provider.\(providerID).apiKey"
        let id = "\(service):\(account)"
        if let normalized = secret?.trimmingCharacters(in: .whitespacesAndNewlines),
           normalized.isEmpty == false {
            _ = try linuxSecretCustodian.storeHighValueSecret(
                normalized,
                id: id,
                secretClass: .providerCredential
            )
        } else {
            try linuxSecretCustodian.deleteHighValueSecret(
                id: id,
                secretClass: .providerCredential
            )
        }
#else
        throw NSError(
            domain: "BurnBarProviderKeychainSecretStore",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Provider keychain secrets are unavailable on this platform."]
        )
#endif
    }

    private func hermesCredentialPoolSecret(for providerID: String) -> String? {
        guard let hermesCredentialPoolURL else { return nil }
        let normalizedProviderID = providerID
            .components(separatedBy: ".slot.")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalizedProviderID, !normalizedProviderID.isEmpty else { return nil }
        guard let data = try? Data(contentsOf: hermesCredentialPoolURL),
              let root = BurnBarJSONValue.dictionary(fromJSONData: data),
              let pool = root["credential_pool"] as? [String: Any],
              let entries = pool[normalizedProviderID] as? [[String: Any]] else {
            return nil
        }

        for entry in entries {
            let status = (entry["last_status"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if status == "exhausted" || status == "disabled" {
                continue
            }
            guard let token = entry["access_token"] as? String else { continue }
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    /// Read the Claude Code credential file (`~/.claude/.credentials.json`)
    /// as a fallback when the daemon's own Keychain credential is expired and
    /// refresh failed. Claude Code maintains its own OAuth session; the daemon
    /// only consumes a still-valid access token and never refreshes or rewrites
    /// Claude Code's file.
    ///
    /// The fallback is intentionally read-only: copying Claude Code's refresh
    /// token into BurnBar's Keychain would let two processes rotate the same
    /// OAuth session independently.
    private func claudeCodeCredentialSecret(
        for providerID: String,
        expectedOrganizationUuid: String?,
        enforceOrganizationMatch: Bool
    ) async throws -> String? {
        guard Self.normalizedProviderID(providerID) == "anthropic" else {
            return nil
        }

        let credentialSources = claudeCodeCredentialPayloads()
        for raw in credentialSources {
            guard let credential = BurnBarClaudeOAuthRouteCredential.decode(raw) else {
                continue
            }
            // When a daemon credential failed we may only borrow a Claude Code credential
            // from the same organization. The match is nil-aware: a daemon credential with
            // no organization may only borrow a Claude Code credential that also has none
            // (so org-scoped CC credentials are never used for an org-less daemon slot).
            // When there is no daemon credential to match against, any valid CC credential
            // is acceptable.
            if enforceOrganizationMatch || expectedOrganizationUuid != nil {
                guard credential.organizationUuid == expectedOrganizationUuid else {
                    continue
                }
            }
            guard !credential.isExpired() else {
                continue
            }
            let token = credential.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty {
                return token
            }
        }
        return nil
    }

    private func claudeCodeCredentialPayloads() -> [String] {
        var payloads: [String] = []

        if let claudeCodeCredentialsURL,
           FileManager.default.fileExists(atPath: claudeCodeCredentialsURL.path),
           let data = try? Data(contentsOf: claudeCodeCredentialsURL),
           let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            payloads.append(raw)
        }

        let username = NSUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        // Tests set this so the developer's real "Claude Code-credentials" Keychain item
        // never leaks into fixtures (CI runners have no such item; dev machines do).
        if ProcessInfo.processInfo.environment["BURNBAR_DISABLE_CLAUDE_CODE_KEYCHAIN_FALLBACK"] != "1" {
            for service in [Self.claudeCodeKeychainService] {
                if let raw = Self.readKeychainPassword(service: service, account: username)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !raw.isEmpty {
                    payloads.append(raw)
                }
            }
        }

        return payloads
    }

    private static let claudeCodeKeychainService = "Claude Code-credentials"

    private static func readKeychainPassword(service: String, account: String) -> String? {
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
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        defer {
            try? outputPipe.fileHandleForReading.close()
        }

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
            if process.isRunning {
                process.terminate()
            }
            try? outputPipe.fileHandleForReading.close()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
        #else
        return nil
        #endif
    }

    /// Proactively refresh Anthropic OAuth credentials that will expire within
    /// `refreshWindow` seconds. Called by the daemon's background refresh timer
    /// to prevent tokens from expiring between user requests.
    ///
    /// For each Anthropic credential slot, reads the stored OAuth credential,
    /// checks if it expires within the window, and refreshes it if so. On
    /// successful refresh, the Keychain is updated. On refresh failure, the
    /// next `secret(for:)` call may use a still-valid canonical Claude Code
    /// credential fallback.
    public func proactivelyRefreshExpiringOAuthCredentials(
        for slotKeys: [String],
        refreshWindow: TimeInterval = 3600
    ) async {
        for slotKey in slotKeys {
            guard Self.normalizedProviderID(slotKey) == "anthropic" else { continue }
            let account = "provider.\(slotKey).apiKey"
            guard let secret = try? secret(forService: service, account: account) else { continue }
            guard let credential = BurnBarClaudeOAuthRouteCredential.decode(secret) else { continue }
            guard let expiresAtMs = credential.expiresAtMilliseconds else { continue }
            let expiresAt = Date(timeIntervalSince1970: expiresAtMs / 1000)
            guard expiresAt <= Date().addingTimeInterval(refreshWindow) else { continue }
            // Token expires within the window, refresh it now.
            if let refreshed = await refreshClaudeOAuthCredential(credential) {
                do {
                    try await setSecret(refreshed.encodedStorageSecret(), for: slotKey)
                } catch {
                    Self.logger.error("provider_oauth_proactive_refresh_store_failed", metadata: [
                        "provider": slotKey,
                        "error": String(describing: error)
                    ])
                }
            }
            // If refresh failed, the next secret(for:) call will fall through
            // to the Claude Code credential fallback automatically.
        }
    }
}

private struct BurnBarClaudeOAuthRouteCredential {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    var accessToken: String
    var refreshToken: String?
    var expiresAtMilliseconds: Double?
    var scopes: [String]
    var subscriptionType: String?
    var rateLimitTier: String?
    var organizationUuid: String?

    static func decode(_ storageSecret: String) -> BurnBarClaudeOAuthRouteCredential? {
        guard let data = storageSecret.data(using: .utf8),
              let root = BurnBarJSONValue.dictionary(fromJSONData: data) else {
            return nil
        }
        let oauth = root["claudeAiOauth"] as? [String: Any] ?? root
        guard let accessToken = (oauth["accessToken"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty else {
            return nil
        }

        return BurnBarClaudeOAuthRouteCredential(
            accessToken: accessToken,
            refreshToken: (oauth["refreshToken"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            expiresAtMilliseconds: Self.expiresAtMilliseconds(oauth["expiresAt"]),
            scopes: oauth["scopes"] as? [String] ?? [],
            subscriptionType: (oauth["subscriptionType"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            rateLimitTier: (oauth["rateLimitTier"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            organizationUuid: ((root["organizationUuid"] as? String) ?? (oauth["organizationUuid"] as? String))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
        )
    }

    func isExpired(now: Date = Date()) -> Bool {
        guard let expiresAtMilliseconds else { return false }
        let expiresAt = Date(timeIntervalSince1970: expiresAtMilliseconds / 1000)
        return expiresAt <= now.addingTimeInterval(60)
    }

    func refreshed(accessToken: String, refreshToken: String, expiresAt: Date) -> Self {
        BurnBarClaudeOAuthRouteCredential(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAtMilliseconds: expiresAt.timeIntervalSince1970 * 1000,
            scopes: scopes,
            subscriptionType: subscriptionType,
            rateLimitTier: rateLimitTier,
            organizationUuid: organizationUuid
        )
    }

    func encodedStorageSecret() -> String {
        var oauth: [String: Any] = [
            "accessToken": accessToken
        ]
        if let refreshToken { oauth["refreshToken"] = refreshToken }
        if let expiresAtMilliseconds { oauth["expiresAt"] = expiresAtMilliseconds }
        if !scopes.isEmpty { oauth["scopes"] = scopes }
        if let subscriptionType { oauth["subscriptionType"] = subscriptionType }
        if let rateLimitTier { oauth["rateLimitTier"] = rateLimitTier }

        var root: [String: Any] = ["claudeAiOauth": oauth]
        if let organizationUuid { root["organizationUuid"] = organizationUuid }

        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return accessToken
        }
        return string
    }

    private static func expiresAtMilliseconds(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let string = value as? String { return Double(string) }
        return nil
    }
}

extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

struct ProviderCompletionRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    struct ResponseFormat: Encodable {
        let type: String
    }

    let model: String
    let messages: [Message]
    let responseFormat: ResponseFormat?
    /// Provider-enforced output ceiling. Optional so existing callers keep the
    /// provider default; per-reply budgeted calls (AI Inbox dialogue) pass the
    /// same figure their preflight cost estimate priced, closing the gap
    /// between "estimated" and "enforceable" spend.
    let maxTokens: Int?

    private enum CodingKeys: String, CodingKey {
        case model
        case messages
        case responseFormat = "response_format"
        case maxTokens = "max_tokens"
    }
}

struct ProviderCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String
            let reasoningContent: String

            private struct ContentPart: Decodable {
                let text: String?
                let type: String?
            }

            private enum CodingKeys: String, CodingKey {
                case content
                case reasoning_content
                case reasoningContent
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                reasoningContent = (try? container.decode(String.self, forKey: .reasoning_content))
                    ?? (try? container.decode(String.self, forKey: .reasoningContent))
                    ?? ""
                if let stringContent = try? container.decode(String.self, forKey: .content) {
                    content = stringContent
                    return
                }
                if let contentParts = try? container.decode([ContentPart].self, forKey: .content) {
                    content = contentParts
                        .compactMap { part in
                            if let text = part.text, !text.isEmpty { return text }
                            return nil
                        }
                        .joined(separator: "\n")
                    return
                }
                content = ""
            }
        }

        let message: Message
        let finishReason: String?

        private enum CodingKeys: String, CodingKey {
            case message
            case finish_reason
            case finishReason
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            message = try container.decode(Message.self, forKey: .message)
            finishReason = (try? container.decode(String.self, forKey: .finish_reason))
                ?? (try? container.decode(String.self, forKey: .finishReason))
        }
    }

    struct UsageDetails: Decodable {
        let cached_tokens: Int?
        let cachedTokens: Int?
        let cache_read_tokens: Int?
        let cacheReadTokens: Int?

        private enum CodingKeys: String, CodingKey {
            case cached_tokens
            case cachedTokens
            case cache_read_tokens
            case cacheReadTokens
        }
    }

    struct Usage: Decodable {
        let prompt_tokens: Int?
        let completion_tokens: Int?
        let input_tokens: Int?
        let output_tokens: Int?
        let cache_creation_input_tokens: Int?
        let cache_creation_tokens: Int?
        let promptTokens: Int?
        let completionTokens: Int?
        let inputTokens: Int?
        let outputTokens: Int?
        let cacheCreationTokens: Int?
        let total_tokens: Int?
        let totalTokens: Int?
        let cache_read_tokens: Int?
        let cache_read_input_tokens: Int?
        let cacheReadTokens: Int?
        let cached_tokens: Int?
        let cachedTokens: Int?
        let input_cached_tokens: Int?
        let inputCachedTokens: Int?
        let cached_input_tokens: Int?
        let cachedInputTokens: Int?
        let prompt_tokens_details: UsageDetails?
        let promptTokensDetails: UsageDetails?
        let input_tokens_details: UsageDetails?
        let inputTokensDetails: UsageDetails?
        let thinking_tokens: Int?
        let reasoning_tokens: Int?
        let thinkingTokens: Int?
        let reasoningTokens: Int?

        private enum CodingKeys: String, CodingKey {
            case prompt_tokens
            case completion_tokens
            case input_tokens
            case output_tokens
            case cache_creation_input_tokens
            case cache_creation_tokens
            case promptTokens
            case completionTokens
            case inputTokens
            case outputTokens
            case cacheCreationTokens
            case total_tokens
            case totalTokens
            case cache_read_tokens
            case cache_read_input_tokens
            case cacheReadTokens
            case cached_tokens
            case cachedTokens
            case input_cached_tokens
            case inputCachedTokens
            case cached_input_tokens
            case cachedInputTokens
            case prompt_tokens_details
            case promptTokensDetails
            case input_tokens_details
            case inputTokensDetails
            case thinking_tokens
            case reasoning_tokens
            case thinkingTokens
            case reasoningTokens
        }

        struct NormalizedUsage {
            let promptTokens: Int
            let completionTokens: Int
            let cacheCreationTokens: Int
            let cacheReadTokens: Int
            let reasoningTokens: Int
        }

        private func firstValue(_ values: Int?...) -> Int {
            for value in values {
                if let value {
                    return value
                }
            }
            return 0
        }

        func normalized(inputHint: Int, outputHint: Int) -> NormalizedUsage {
            var prompt = prompt_tokens
                ?? input_tokens
                ?? promptTokens
                ?? inputTokens
                ?? 0

            var completion = completion_tokens
                ?? output_tokens
                ?? completionTokens
                ?? outputTokens
                ?? 0

            let exclusiveCacheRead = firstValue(
                cache_read_tokens,
                cache_read_input_tokens,
                cacheReadTokens
            )
            let inclusiveCacheRead = firstValue(
                input_cached_tokens,
                inputCachedTokens,
                cached_input_tokens,
                cachedInputTokens,
                cached_tokens,
                cachedTokens,
                prompt_tokens_details?.cached_tokens,
                prompt_tokens_details?.cachedTokens,
                prompt_tokens_details?.cache_read_tokens,
                prompt_tokens_details?.cacheReadTokens,
                input_tokens_details?.cached_tokens,
                input_tokens_details?.cachedTokens,
                input_tokens_details?.cache_read_tokens,
                input_tokens_details?.cacheReadTokens,
                promptTokensDetails?.cached_tokens,
                promptTokensDetails?.cachedTokens,
                promptTokensDetails?.cache_read_tokens,
                promptTokensDetails?.cacheReadTokens,
                inputTokensDetails?.cached_tokens,
                inputTokensDetails?.cachedTokens,
                inputTokensDetails?.cache_read_tokens,
                inputTokensDetails?.cacheReadTokens
            )
            let cacheRead = exclusiveCacheRead > 0 ? exclusiveCacheRead : inclusiveCacheRead
            if inclusiveCacheRead > 0 && exclusiveCacheRead == 0 {
                prompt = max(prompt - inclusiveCacheRead, 0)
            }

            let cacheCreation = firstValue(
                cache_creation_input_tokens,
                cache_creation_tokens,
                cacheCreationTokens
            )

            let thinking = firstValue(
                thinking_tokens,
                reasoning_tokens,
                thinkingTokens,
                reasoningTokens
            )

            let total = total_tokens ?? totalTokens ?? 0
            let explicitTotal = prompt + completion + cacheCreation + cacheRead
            let normalizedTotal = max(total, explicitTotal)
            let availableForInOut = max(normalizedTotal - cacheCreation - cacheRead, 0)

            if prompt == 0 && completion == 0 && availableForInOut > 0 {
                let safeInputHint = max(inputHint, 1)
                let safeOutputHint = max(outputHint, 1)
                let ratio = Double(safeInputHint) / Double(safeInputHint + safeOutputHint)
                prompt = Int((Double(availableForInOut) * ratio).rounded())
                completion = max(availableForInOut - prompt, 0)
            } else if prompt == 0 && completion > 0 && availableForInOut > completion {
                prompt = availableForInOut - completion
            } else if completion == 0 && prompt > 0 && availableForInOut > prompt {
                completion = availableForInOut - prompt
            } else if prompt + completion < availableForInOut {
                completion += availableForInOut - (prompt + completion)
            }

            if thinking > 0 && total == 0 {
                completion += thinking
            }

            return NormalizedUsage(
                promptTokens: max(prompt, 0),
                completionTokens: max(completion, 0),
                cacheCreationTokens: max(cacheCreation, 0),
                cacheReadTokens: max(cacheRead, 0),
                reasoningTokens: max(thinking, 0)
            )
        }
    }

    let choices: [Choice]
    let usage: Usage?
}
