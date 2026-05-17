import OpenBurnBarCore
import Foundation
import LocalAuthentication
import Security

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

    public init(service: String = "com.openburnbar.connector-plane") {
        self.service = service
    }

    public func secret(for connector: BurnBarConnectorKind) async throws -> String? {
        let context = LAContext()
        context.interactionNotAllowed = true
        let account = "connector.\(connector.rawValue).credential"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail
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
    }

    public func setSecret(_ secret: String?, for connector: BurnBarConnectorKind) async throws {
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
    }
}
