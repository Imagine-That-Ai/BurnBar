#if canImport(CryptoKit)
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#else
import Crypto
#endif
import Foundation
import OpenBurnBarComputerUseCore
import OpenBurnBarCore
#if canImport(Security)
#if canImport(Security)
#if canImport(Security)
import Security
#endif
#endif
#endif

#if canImport(Security)
private let daemonErrSecSuccessCompat: Int32 = errSecSuccess
private let daemonErrSecDuplicateItemCompat: Int32 = errSecDuplicateItem
#else
private let daemonErrSecSuccessCompat: Int32 = 0
private let daemonErrSecDuplicateItemCompat: Int32 = -25299
#endif

/// T-DMN-04 — daemon-side pinned phone local-auth verifying-key store.
///
/// The daemon independently re-verifies the single-use, op-hash-bound
/// local-auth proof that authorizes high-risk Computer Use RPCs. To do that it
/// owns a local pin for each phone source device instead of trusting a key
/// forwarded with the request.
public struct DaemonPhoneKeyPinRecord: Codable, Equatable, Sendable {
    public let deviceId: String
    public let publicKeyBase64: String
    public let keyKind: PhoneControlSigningKeyKind
    public let pinnedAtEpoch: Double

    public init(
        deviceId: String,
        publicKeyBase64: String,
        keyKind: PhoneControlSigningKeyKind,
        pinnedAtEpoch: Double = Date().timeIntervalSince1970
    ) {
        self.deviceId = deviceId
        self.publicKeyBase64 = publicKeyBase64
        self.keyKind = keyKind
        self.pinnedAtEpoch = pinnedAtEpoch
    }
}

public enum DaemonPhoneKeyPinLoad: Equatable, Sendable {
    case found(DaemonPhoneKeyPinRecord)
    case absent
    case unreadable(Int32)
}

public protocol DaemonPhoneKeyPinBacking: Sendable {
    func load(deviceId: String) -> DaemonPhoneKeyPinLoad
    /// Insert a new pin. Existing rows must not be overwritten; return
    /// `errSecDuplicateItem` semantics when a device is already pinned.
    @discardableResult func save(_ record: DaemonPhoneKeyPinRecord) -> Int32
    func delete(deviceId: String)
}

public struct DaemonPhoneKeyPinStore: Sendable {
    public enum PinResult: Sendable {
        case pinned(PhoneControlVerifyingKey)
        case absent
        case malformed
        case conflict
        case storeError(Int32)
    }

    private let backing: DaemonPhoneKeyPinBacking

    public init(backing: DaemonPhoneKeyPinBacking = DaemonPhoneKeyPinStore.defaultBacking()) {
        self.backing = backing
    }

    @discardableResult
    public func pin(deviceId: String, key: PhoneControlVerifyingKey) -> PinResult {
        let normalizedDeviceId = deviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDeviceId.isEmpty else { return .malformed }

        switch pinnedKey(deviceId: normalizedDeviceId) {
        case .pinned(let existing):
            return Self.keysEqual(existing, key) ? .pinned(existing) : .conflict
        case .absent:
            break
        case .malformed:
            return .malformed
        case .conflict:
            return .conflict
        case .storeError(let status):
            return .storeError(status)
        }

        let record = DaemonPhoneKeyPinRecord(
            deviceId: normalizedDeviceId,
            publicKeyBase64: key.publicKeyRepresentation.base64EncodedString(),
            keyKind: key.kind
        )
        let status = backing.save(record)
        if status == daemonErrSecDuplicateItemCompat {
            switch pinnedKey(deviceId: normalizedDeviceId) {
            case .pinned(let existing):
                return Self.keysEqual(existing, key) ? .pinned(existing) : .conflict
            case .absent:
                return .storeError(status)
            case .malformed:
                return .malformed
            case .conflict:
                return .conflict
            case .storeError(let reloadStatus):
                return .storeError(reloadStatus)
            }
        }
        guard status == daemonErrSecSuccessCompat else {
            return .storeError(status)
        }
        return .pinned(key)
    }

    public func pinnedKey(deviceId: String) -> PinResult {
        let normalizedDeviceId = deviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDeviceId.isEmpty else { return .malformed }
        switch backing.load(deviceId: normalizedDeviceId) {
        case .found(let record):
            guard let data = Data(base64Encoded: record.publicKeyBase64),
                  let key = try? PhoneControlVerifyingKey(
                    kind: record.keyKind,
                    publicKeyRepresentation: data
                  ) else {
                return .malformed
            }
            return .pinned(key)
        case .absent:
            return .absent
        case .unreadable(let status):
            return .storeError(status)
        }
    }

    public func clearPin(deviceId: String) {
        backing.delete(deviceId: deviceId.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func keysEqual(_ lhs: PhoneControlVerifyingKey, _ rhs: PhoneControlVerifyingKey) -> Bool {
        lhs.kind == rhs.kind && lhs.publicKeyRepresentation == rhs.publicKeyRepresentation
    }
}

#if canImport(Security)
public struct DaemonPhoneKeyKeychainPinBacking: DaemonPhoneKeyPinBacking {
    public static let service = "com.openburnbar.daemon.phone-control-pin"

    public init() {}

    public func load(deviceId: String) -> DaemonPhoneKeyPinLoad {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: deviceId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecItemNotFound:
            return .absent
        case errSecSuccess:
            guard let data = item as? Data,
                  let record = try? JSONDecoder().decode(DaemonPhoneKeyPinRecord.self, from: data) else {
                return .unreadable(errSecDecode)
            }
            return .found(record)
        default:
            return .unreadable(status)
        }
    }

    @discardableResult
    public func save(_ record: DaemonPhoneKeyPinRecord) -> Int32 {
        guard let data = try? JSONEncoder().encode(record) else { return errSecParam }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: record.deviceId
        ]
        var create = query
        create[kSecValueData as String] = data
        create[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(create as CFDictionary, nil)
    }

    public func delete(deviceId: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: deviceId
        ]
        SecItemDelete(query as CFDictionary)
    }
}

extension DaemonPhoneKeyPinStore {
    public static func defaultBacking() -> DaemonPhoneKeyPinBacking {
        DaemonPhoneKeyKeychainPinBacking()
    }
}
#else
extension DaemonPhoneKeyPinStore {
    public static func defaultBacking() -> DaemonPhoneKeyPinBacking {
        DaemonPhoneKeyInMemoryPinBacking()
    }
}
#endif

public final class DaemonPhoneKeyInMemoryPinBacking: DaemonPhoneKeyPinBacking, Sendable {
    private struct State {
        var store: [String: DaemonPhoneKeyPinRecord] = [:]
        var forcedReadError: Int32?
        var forcedWriteError: Int32?
    }

    private let state = Locked(State())

    public init() {}

    public func failReads(with status: Int32) {
        state.withLock { $0.forcedReadError = status }
    }

    public func failWrites(with status: Int32) {
        state.withLock { $0.forcedWriteError = status }
    }

    public func load(deviceId: String) -> DaemonPhoneKeyPinLoad {
        state.withLock { state in
            if let forcedReadError = state.forcedReadError { return .unreadable(forcedReadError) }
            if let record = state.store[deviceId] { return .found(record) }
            return .absent
        }
    }

    @discardableResult
    public func save(_ record: DaemonPhoneKeyPinRecord) -> Int32 {
        state.withLock { state in
            if let forcedWriteError = state.forcedWriteError { return forcedWriteError }
            guard state.store[record.deviceId] == nil else { return daemonErrSecDuplicateItemCompat }
            state.store[record.deviceId] = record
            return daemonErrSecSuccessCompat
        }
    }

    public func delete(deviceId: String) {
        _ = state.withLock { $0.store.removeValue(forKey: deviceId) }
    }
}
