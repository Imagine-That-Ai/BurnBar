import Foundation
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
import OpenBurnBarCore
#if canImport(Security)
import Security
#endif

public protocol BurnBarNotificationSecretStoring: Sendable {
    func telegramBotToken() throws -> String?
    func setTelegramBotToken(_ token: String?) throws
}

public final class BurnBarInMemoryNotificationSecretStore: BurnBarNotificationSecretStoring {
    private let token: Locked<String?>

    public init(telegramBotToken: String? = nil) {
        token = Locked(Self.normalizedToken(telegramBotToken))
    }

    public func telegramBotToken() throws -> String? {
        token.read()
    }

    public func setTelegramBotToken(_ token: String?) throws {
        self.token.write(Self.normalizedToken(token))
    }

    private static func normalizedToken(_ token: String?) -> String? {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

public struct BurnBarNotificationKeychainSecretStore: BurnBarNotificationSecretStoring {
    public static let defaultService = "com.openburnbar.daemon.notification-secrets"
    private static let telegramBotTokenAccount = "mission-control.telegram.bot-token"

    private let service: String

    public init(service: String = Self.defaultService) {
        self.service = service
    }

    public func telegramBotToken() throws -> String? {
#if canImport(Security) && canImport(LocalAuthentication)
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.telegramBotTokenAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
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
        guard let data = item as? Data else { return nil }
        let decoded = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return decoded?.isEmpty == false ? decoded : nil
#else
        return nil
#endif
    }

    public func setTelegramBotToken(_ token: String?) throws {
#if canImport(Security) && canImport(LocalAuthentication)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.telegramBotTokenAccount
        ]

        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, trimmed.isEmpty == false else {
            let deleteStatus = withKeychainUserInteractionDisabled {
                SecItemDelete(query as CFDictionary)
            }
            guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(deleteStatus))
            }
            return
        }

        let data = Data(trimmed.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let updateStatus = withKeychainUserInteractionDisabled {
            SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        }
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(updateStatus))
        }

        var createQuery = query
        createQuery[kSecValueData as String] = data
        createQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = withKeychainUserInteractionDisabled {
            SecItemAdd(createQuery as CFDictionary, nil)
        }
        guard addStatus == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus))
        }
#else
        throw NSError(
            domain: "BurnBarNotificationKeychainSecretStore",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Notification keychain secrets are unavailable on this platform."]
        )
#endif
    }
}
