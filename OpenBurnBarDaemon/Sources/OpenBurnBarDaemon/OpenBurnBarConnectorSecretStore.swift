import OpenBurnBarCore
import OpenBurnBarLinuxSecurity
import Foundation
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif

public protocol BurnBarConnectorSecretStoring: Sendable {
    func secret(for connector: BurnBarConnectorKind) async throws -> String?
    func setSecret(_ secret: String?, for connector: BurnBarConnectorKind) async throws
}

public actor BurnBarInMemoryConnectorSecretStore: BurnBarConnectorSecretStoring {
    private var secrets: [BurnBarConnectorKind: String]

    public init(secrets: [BurnBarConnectorKind: String] = [:]) {
        self.secrets = secrets
    }

    public func secret(for connector: BurnBarConnectorKind) async throws -> String? {
        secrets[connector]
    }

    public func setSecret(_ secret: String?, for connector: BurnBarConnectorKind) async throws {
        let normalized = secret?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalized, normalized.isEmpty == false {
            secrets[connector] = normalized
        } else {
            secrets.removeValue(forKey: connector)
        }
    }
}

public actor BurnBarConnectorKeychainSecretStore: BurnBarConnectorSecretStoring {
    private let service: String
    private let linuxSecretCustodian: LinuxSecretCustodian

    public init(
        service: String = "com.openburnbar.connector-plane",
        linuxSecretCustodian: LinuxSecretCustodian = LinuxSecretStoreFactory.production()
    ) {
        self.service = service
        self.linuxSecretCustodian = linuxSecretCustodian
    }

    public func secret(for connector: BurnBarConnectorKind) async throws -> String? {
#if canImport(Security) && canImport(LocalAuthentication)
        let context = LAContext()
        context.interactionNotAllowed = true
        let account = "connector.\(connector.rawValue).credential"
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
        guard status == errSecSuccess,
              let data = item as? Data else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return String(data: data, encoding: .utf8)
#elseif os(Linux)
        do {
            return try linuxSecretCustodian.requireHighValueSecret(
                id: "\(service):connector.\(connector.rawValue).credential",
                secretClass: .connectorCredential
            ).secret
        } catch LinuxSecretStoreError.missingSecret(_) {
            return nil
        }
#else
        return nil
#endif
    }

    public func setSecret(_ secret: String?, for connector: BurnBarConnectorKind) async throws {
#if canImport(Security) && canImport(LocalAuthentication)
        let account = "connector.\(connector.rawValue).credential"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        if let secret, secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            let data = Data(secret.utf8)
            let attributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            ]
            let updateStatus = withKeychainUserInteractionDisabled {
                SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            }
            if updateStatus == errSecItemNotFound {
                var createQuery = query
                createQuery[kSecValueData as String] = data
                createQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                let addStatus = withKeychainUserInteractionDisabled {
                    SecItemAdd(createQuery as CFDictionary, nil)
                }
                guard addStatus == errSecSuccess else {
                    throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus))
                }
            } else if updateStatus != errSecSuccess {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(updateStatus))
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
        let id = "\(service):connector.\(connector.rawValue).credential"
        if let secret,
           secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            _ = try linuxSecretCustodian.storeHighValueSecret(
                secret,
                id: id,
                secretClass: .connectorCredential
            )
        } else {
            try linuxSecretCustodian.deleteHighValueSecret(
                id: id,
                secretClass: .connectorCredential
            )
        }
#else
        throw NSError(
            domain: "BurnBarConnectorKeychainSecretStore",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Connector keychain secrets are unavailable on this platform."]
        )
#endif
    }
}
