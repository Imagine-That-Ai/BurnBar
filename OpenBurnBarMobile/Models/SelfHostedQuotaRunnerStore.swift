import Foundation
import OpenBurnBarCore

@MainActor
final class SelfHostedQuotaRunnerStore {
    static let shared = SelfHostedQuotaRunnerStore()

    private let defaults: UserDefaults
    private let functions: FunctionsRepository
    private let secrets: any SelfHostedQuotaRunnerSecretStoring

    init(
        defaults: UserDefaults = .standard,
        functions: FunctionsRepository = .shared,
        secrets: any SelfHostedQuotaRunnerSecretStoring = KeychainSelfHostedQuotaRunnerSecrets()
    ) {
        self.defaults = defaults
        self.functions = functions
        self.secrets = secrets
    }

    func save(accountID: String, runnerURL: String, accessSecret: String?) throws {
        guard let url = Self.validatedRunnerURL(runnerURL) else {
            throw SelfHostedQuotaRunnerError.invalidURL
        }
        let secret = accessSecret?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if secret.isEmpty {
            try secrets.delete(accountID: accountID)
        } else {
            try secrets.save(secret, accountID: accountID)
        }
        defaults.set(url.absoluteString, forKey: urlKey(accountID))
    }

    func delete(accountID: String) {
        defaults.removeObject(forKey: urlKey(accountID))
        try? secrets.delete(accountID: accountID)
    }

    func refresh(account: ProviderAccountDoc) async throws -> ProviderQuotaSnapshot {
        guard let rawURL = defaults.string(forKey: urlKey(account.id)),
              let baseURL = URL(string: rawURL) else {
            throw SelfHostedQuotaRunnerError.missingRunner
        }
        let url = baseURL.appending(path: "v1/quota/refresh")
        var request = URLRequest(url: url, timeoutInterval: 45)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if let secret = try secrets.load(accountID: account.id), secret.isEmpty == false {
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "provider": account.providerID.rawValue,
            "accountID": account.id
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SelfHostedQuotaRunnerError.runnerFailed
        }
        guard var payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SelfHostedQuotaRunnerError.invalidResponse
        }
        if let nested = payload["snapshot"] as? [String: Any] {
            payload = nested
        }
        let now = ISO8601DateFormatter().string(from: Date())
        payload["provider"] = account.providerID.rawValue
        payload["providerID"] = account.providerID.rawValue
        payload["accountID"] = account.id
        payload["accountLabel"] = account.label
        payload["accountStorageScope"] = ProviderAccountStorageScope.localOnly.rawValue
        payload["sourceKind"] = ProviderQuotaSourceKind.provider.rawValue
        payload["sourceId"] = payload["sourceId"] ?? "self-hosted-runner"
        payload["fetchedAt"] = payload["fetchedAt"] ?? now
        payload["source"] = payload["source"] ?? "Self-hosted quota runner"
        payload["confidence"] = payload["confidence"] ?? ProviderQuotaConfidence.high.rawValue
        payload["schemaVersion"] = payload["schemaVersion"] ?? 2
        payload["updatedAt"] = now

        let jsonData = try JSONSerialization.data(withJSONObject: payload)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(ProviderQuotaSnapshot.self, from: jsonData)
        return try await functions.uploadProviderQuotaSnapshot(snapshot)
    }

    private func urlKey(_ accountID: String) -> String {
        "selfHostedQuotaRunnerURL.\(accountID)"
    }

    static func validatedRunnerURL(_ rawValue: String) -> URL? {
        guard let url = URL(string: rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased() else {
            return nil
        }
        if scheme == "https" {
            return url
        }
        if scheme == "http", host == "localhost" || host == "127.0.0.1" {
            return url
        }
        return nil
    }
}

@MainActor
protocol SelfHostedQuotaRunnerSecretStoring: AnyObject {
    func save(_ value: String, accountID: String) throws
    func load(accountID: String) throws -> String?
    func delete(accountID: String) throws
}

@MainActor
private final class KeychainSelfHostedQuotaRunnerSecrets: SelfHostedQuotaRunnerSecretStoring {
    private let keychainService = "com.openburnbar.mobile.self-hosted-quota-runner"

    func save(_ value: String, accountID: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: accountID
        ]
        let attrs: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var create = query
            create[kSecValueData as String] = data
            create[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(create as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw SelfHostedQuotaRunnerError.keychain(addStatus) }
        } else if status != errSecSuccess {
            throw SelfHostedQuotaRunnerError.keychain(status)
        }
    }

    func load(accountID: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: accountID,
            kSecReturnData as String: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data else {
            throw SelfHostedQuotaRunnerError.keychain(status)
        }
        return String(data: data, encoding: .utf8)
    }

    func delete(accountID: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: accountID
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SelfHostedQuotaRunnerError.keychain(status)
        }
    }
}

enum SelfHostedQuotaRunnerError: Error, LocalizedError {
    case invalidURL
    case missingRunner
    case runnerFailed
    case invalidResponse
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Use an HTTPS runner URL, or localhost while testing."
        case .missingRunner: return "Self-hosted runner URL is not configured for this account."
        case .runnerFailed: return "The self-hosted quota runner did not return a successful response."
        case .invalidResponse: return "The self-hosted quota runner returned an unreadable snapshot."
        case .keychain(let status): return "Could not update the runner secret in Keychain (\(status))."
        }
    }
}
