import Foundation
import CryptoKit
import Security

/// T-IOS-06 — integrity / authenticity MAC for the keyboard → app text-expansion
/// inbox that crosses the App Group boundary.
///
/// The inbox JSON is written by the keyboard extension and drained by the app,
/// which then auto-syncs the snippets to the encrypted cloud vault. Any process
/// that can write the shared App Group container (or a jailbroken / restored
/// device image) could otherwise inject snippets that the app would happily
/// upload as the user's own. This wraps each inbox payload with an HMAC-SHA256
/// keyed by a secret held in a **shared keychain access group** (readable by the
/// app + keyboard, not by other apps), so the app rejects any inbox blob it
/// cannot authenticate before it ever reaches the cloud-sync path.
///
/// The MAC is written to a sidecar file next to the inbox (`…inbox.json.mac`)
/// rather than mutating the inbox JSON, so the core `TextExpansionInbox`
/// reader/writer contract is untouched and a missing/extra sidecar simply fails
/// closed (treated as unverified).
///
/// The pure pieces (`computeMAC`, `verify`) take the key as a parameter so the
/// authentication decision is unit-testable without the keychain.
enum TextExpansionInboxIntegrity {
    /// Shared keychain access group used to share the HMAC key between the app
    /// and the keyboard extension. The runtime `kSecAttrAccessGroup` value omits
    /// the team prefix (the system prepends `$(AppIdentifierPrefix)` to match the
    /// entitlement). Both targets must carry a matching `keychain-access-groups`
    /// entry — the keyboard's is set in this change; the app-side addition is
    /// portal/cross-file (see the Deferred note). When the group is unavailable
    /// the helper degrades to a per-process item and verification fails closed.
    static let keychainAccessGroup = "com.openburnbar.shared"
    static let keychainService = "com.openburnbar.textexpansion.inbox-mac"
    static let keychainAccount = "inbox-hmac-key-v1"

    static let macFileSuffix = ".mac"

    // MARK: - Pure MAC primitives (testable without keychain)

    /// Computes the lowercase-hex HMAC-SHA256 of `payload` under `key`.
    static func computeMAC(payload: Data, key: Data) -> String {
        let mac = HMAC<SHA256>.authenticationCode(
            for: payload,
            using: SymmetricKey(data: key)
        )
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    /// Constant-time-ish verification that `expectedHex` authenticates `payload`
    /// under `key`. Uses CryptoKit's `isValidAuthenticationCode` so the compare
    /// itself is constant time.
    static func verify(payload: Data, key: Data, expectedHex: String) -> Bool {
        guard let expected = data(fromHex: expectedHex) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(
            expected,
            authenticating: payload,
            using: SymmetricKey(data: key)
        )
    }

    private static func data(fromHex hex: String) -> Data? {
        let chars = Array(hex)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        var index = 0
        while index < chars.count {
            guard let byte = UInt8(String(chars[index ... index + 1]), radix: 16) else { return nil }
            bytes.append(byte)
            index += 2
        }
        return Data(bytes)
    }

    // MARK: - Sidecar file helpers

    static func macURL(for inboxURL: URL) -> URL {
        inboxURL.appendingPathExtension(String(macFileSuffix.dropFirst()))
    }

    /// Signs the current inbox bytes and writes the MAC sidecar. Called by the
    /// keyboard right after it appends to the inbox.
    static func signInbox(at inboxURL: URL) {
        guard let key = loadOrCreateKey(),
              let payload = try? Data(contentsOf: inboxURL) else {
            return
        }
        let mac = computeMAC(payload: payload, key: key)
        try? Data(mac.utf8).write(to: macURL(for: inboxURL), options: [.atomic])
    }

    /// Verifies the inbox against its sidecar MAC. Fails closed: a missing key,
    /// missing/empty sidecar, or mismatch all return `false` so the app skips
    /// auto-syncing an unauthenticated payload.
    static func isInboxAuthentic(at inboxURL: URL) -> Bool {
        guard let key = loadOrCreateKey(),
              let payload = try? Data(contentsOf: inboxURL),
              let macData = try? Data(contentsOf: macURL(for: inboxURL)),
              let expected = String(data: macData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              expected.isEmpty == false else {
            return false
        }
        return verify(payload: payload, key: key, expectedHex: expected)
    }

    // MARK: - Keychain-backed shared key

    /// Loads the shared HMAC key, creating + persisting a fresh 32-byte key on
    /// first use. Best-effort: returns `nil` only if the keychain is entirely
    /// unavailable.
    static func loadOrCreateKey() -> Data? {
        if let existing = readKey(useAccessGroup: true) ?? readKey(useAccessGroup: false) {
            return existing
        }
        var keyBytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, keyBytes.count, &keyBytes) == errSecSuccess else {
            return nil
        }
        let key = Data(keyBytes)
        if !writeKey(key, useAccessGroup: true) {
            _ = writeKey(key, useAccessGroup: false)
        }
        return key
    }

    private static func baseQuery(useAccessGroup: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        if useAccessGroup {
            query[kSecAttrAccessGroup as String] = keychainAccessGroup
        }
        return query
    }

    private static func readKey(useAccessGroup: Bool) -> Data? {
        var query = baseQuery(useAccessGroup: useAccessGroup)
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, data.count == 32 else {
            return nil
        }
        return data
    }

    @discardableResult
    private static func writeKey(_ key: Data, useAccessGroup: Bool) -> Bool {
        var create = baseQuery(useAccessGroup: useAccessGroup)
        create[kSecValueData as String] = key
        // Available to the keyboard extension whenever the device has been
        // unlocked once; never leaves the device.
        create[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(create as CFDictionary, nil)
        return status == errSecSuccess || status == errSecDuplicateItem
    }
}
