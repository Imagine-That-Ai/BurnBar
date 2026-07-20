import Foundation
import OpenBurnBarComputerUseCore
import OpenBurnBarEngine
#if canImport(Security)
import Security
#endif
#if os(Linux)
import Glibc
#endif

#if canImport(Security)
private let daemonErrSecSuccessCompat: Int32 = errSecSuccess
private let daemonErrSecDuplicateItemCompat: Int32 = errSecDuplicateItem
private let daemonErrSecDecodeCompat: Int32 = errSecDecode
private let daemonErrSecParamCompat: Int32 = errSecParam
#else
private let daemonErrSecSuccessCompat: Int32 = 0
private let daemonErrSecDuplicateItemCompat: Int32 = -25299
private let daemonErrSecDecodeCompat: Int32 = -26275
private let daemonErrSecParamCompat: Int32 = -50
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

/// Backings that can persist a set of aliases with one atomic commit. Linux's
/// file store and the in-memory test store implement this so an I/O failure can
/// never expose only a subset of a newly paired phone's identities.
public protocol DaemonPhoneKeyAtomicAliasPinBacking: DaemonPhoneKeyPinBacking {
    @discardableResult func saveAliasesAtomically(_ records: [DaemonPhoneKeyPinRecord]) -> Int32
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

    /// Pins every identity alias as one fail-closed provisioning operation.
    /// Existing aliases are preflighted before the first write. Backings that
    /// cannot commit every missing alias atomically reject multi-alias writes
    /// before mutating trust.
    @discardableResult
    public func pinAliases(deviceIds: [String], key: PhoneControlVerifyingKey) -> PinResult {
        let normalizedDeviceIds = deviceIds
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .reduce(into: [String]()) { identifiers, candidate in
                if identifiers.contains(candidate) == false { identifiers.append(candidate) }
            }
        guard normalizedDeviceIds.isEmpty == false,
              normalizedDeviceIds.allSatisfy({ $0.isEmpty == false }) else {
            return .malformed
        }

        var absentDeviceIds: [String] = []
        for deviceId in normalizedDeviceIds {
            switch pinnedKey(deviceId: deviceId) {
            case .pinned(let existing):
                guard Self.keysEqual(existing, key) else { return .conflict }
            case .absent:
                absentDeviceIds.append(deviceId)
            case .malformed:
                return .malformed
            case .conflict:
                return .conflict
            case .storeError(let status):
                return .storeError(status)
            }
        }
        guard absentDeviceIds.isEmpty == false else { return .pinned(key) }

        let records = absentDeviceIds.map {
            DaemonPhoneKeyPinRecord(
                deviceId: $0,
                publicKeyBase64: key.publicKeyRepresentation.base64EncodedString(),
                keyKind: key.kind
            )
        }
        if let atomicBacking = backing as? DaemonPhoneKeyAtomicAliasPinBacking {
            let status = atomicBacking.saveAliasesAtomically(records)
            guard status != daemonErrSecDuplicateItemCompat else {
                return normalizedDeviceIds.allSatisfy {
                    guard case .pinned(let storedKey) = pinnedKey(deviceId: $0) else { return false }
                    return Self.keysEqual(storedKey, key)
                } ? .pinned(key) : .conflict
            }
            return status == daemonErrSecSuccessCompat ? .pinned(key) : .storeError(status)
        }

        guard records.count == 1 else { return .storeError(daemonErrSecParamCompat) }
        return pin(deviceId: records[0].deviceId, key: key)
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
protocol DaemonPhoneKeyKeychainDataStore: Sendable {
    func load(service: String, account: String) -> (status: Int32, data: Data?)
    func add(service: String, account: String, data: Data) -> Int32
    func update(service: String, account: String, data: Data) -> Int32
    func delete(service: String, account: String) -> Int32
}

private struct DaemonPhoneKeySecurityDataStore: DaemonPhoneKeyKeychainDataStore {
    func load(service: String, account: String) -> (status: Int32, data: Data?) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return (status, item as? Data)
    }

    func add(service: String, account: String, data: Data) -> Int32 {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        return SecItemAdd(query as CFDictionary, nil)
    }

    func update(service: String, account: String, data: Data) -> Int32 {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        return SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
    }

    func delete(service: String, account: String) -> Int32 {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        return SecItemDelete(query as CFDictionary)
    }
}

public struct DaemonPhoneKeyKeychainPinBacking: DaemonPhoneKeyAtomicAliasPinBacking {
    public static let service = "com.openburnbar.daemon.phone-control-pin"
    private static let aliasStoreAccount = "phone-control-alias-store-v1"
    private static let mutationState = Locked(())

    private struct AliasStore: Codable {
        static let currentVersion = 1

        let version: Int
        var records: [String: DaemonPhoneKeyPinRecord]
    }

    private enum AliasStoreLoad {
        case found(AliasStore)
        case absent
        case unreadable(Int32)
    }

    private let serviceName: String
    private let dataStore: any DaemonPhoneKeyKeychainDataStore

    public init() {
        serviceName = Self.service
        dataStore = DaemonPhoneKeySecurityDataStore()
    }

    init(serviceName: String, dataStore: any DaemonPhoneKeyKeychainDataStore) {
        self.serviceName = serviceName
        self.dataStore = dataStore
    }

    public func load(deviceId: String) -> DaemonPhoneKeyPinLoad {
        switch loadAliasStore() {
        case .found(let aliasStore):
            if let record = aliasStore.records[deviceId] { return .found(record) }
        case .absent:
            break
        case .unreadable(let status):
            return .unreadable(status)
        }
        return loadLegacyRecord(deviceId: deviceId)
    }

    @discardableResult
    public func save(_ record: DaemonPhoneKeyPinRecord) -> Int32 {
        saveAliasesAtomically([record])
    }

    @discardableResult
    public func saveAliasesAtomically(_ records: [DaemonPhoneKeyPinRecord]) -> Int32 {
        Self.mutationState.withLock { _ in
            let identifiers = records.map(\.deviceId)
            guard records.isEmpty == false,
                  Set(identifiers).count == identifiers.count else {
                return errSecParam
            }

            for identifier in identifiers {
                switch loadLegacyRecord(deviceId: identifier) {
                case .found:
                    return errSecDuplicateItem
                case .absent:
                    break
                case .unreadable(let status):
                    return status
                }
            }

            let existing: AliasStore?
            switch loadAliasStore() {
            case .found(let aliasStore):
                existing = aliasStore
            case .absent:
                existing = nil
            case .unreadable(let status):
                return status
            }

            var updated = existing ?? AliasStore(version: AliasStore.currentVersion, records: [:])
            guard records.allSatisfy({ updated.records[$0.deviceId] == nil }) else {
                return errSecDuplicateItem
            }
            records.forEach { updated.records[$0.deviceId] = $0 }
            guard let data = try? JSONEncoder().encode(updated) else { return errSecParam }

            if existing == nil {
                return dataStore.add(
                    service: serviceName,
                    account: Self.aliasStoreAccount,
                    data: data
                )
            }
            return dataStore.update(
                service: serviceName,
                account: Self.aliasStoreAccount,
                data: data
            )
        }
    }

    public func delete(deviceId: String) {
        Self.mutationState.withLock { _ in
            if case .found(var aliasStore) = loadAliasStore(),
               aliasStore.records.removeValue(forKey: deviceId) != nil,
               let data = try? JSONEncoder().encode(aliasStore) {
                _ = dataStore.update(
                    service: serviceName,
                    account: Self.aliasStoreAccount,
                    data: data
                )
            }
            _ = dataStore.delete(service: serviceName, account: deviceId)
        }
    }

    private func loadAliasStore() -> AliasStoreLoad {
        let result = dataStore.load(service: serviceName, account: Self.aliasStoreAccount)
        switch result.status {
        case errSecItemNotFound:
            return .absent
        case errSecSuccess:
            guard let data = result.data,
                  let aliasStore = try? JSONDecoder().decode(AliasStore.self, from: data),
                  aliasStore.version == AliasStore.currentVersion else {
                return .unreadable(errSecDecode)
            }
            return .found(aliasStore)
        default:
            return .unreadable(result.status)
        }
    }

    private func loadLegacyRecord(deviceId: String) -> DaemonPhoneKeyPinLoad {
        let result = dataStore.load(service: serviceName, account: deviceId)
        switch result.status {
        case errSecItemNotFound:
            return .absent
        case errSecSuccess:
            guard let data = result.data,
                  let record = try? JSONDecoder().decode(DaemonPhoneKeyPinRecord.self, from: data) else {
                return .unreadable(errSecDecode)
            }
            return .found(record)
        default:
            return .unreadable(result.status)
        }
    }
}

extension DaemonPhoneKeyPinStore {
    public static func defaultBacking() -> DaemonPhoneKeyPinBacking {
        DaemonPhoneKeyKeychainPinBacking()
    }
}
#elseif os(Linux)
public final class DaemonPhoneKeyFilePinBacking: DaemonPhoneKeyAtomicAliasPinBacking, Sendable {
    public static let relativeStorePath = "openburnbar/daemon-phone-control-pins.json"

    private let fileURL: URL
    private let state = Locked(())

    public init(fileURL: URL = DaemonPhoneKeyFilePinBacking.defaultFileURL()) {
        self.fileURL = fileURL
    }

    public static func defaultFileURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let base: String
        if let xdgState = environment["XDG_STATE_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           xdgState.isEmpty == false {
            base = xdgState
        } else if let home = environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  home.isEmpty == false {
            base = URL(fileURLWithPath: home).appendingPathComponent(".local/state").path
        } else {
            base = "/var/lib"
        }
        return URL(fileURLWithPath: base)
            .appendingPathComponent(Self.relativeStorePath)
    }

    public func load(deviceId: String) -> DaemonPhoneKeyPinLoad {
        state.withLock { _ in
            do {
                let records = try readStore()
                return records[deviceId].map(DaemonPhoneKeyPinLoad.found) ?? .absent
            } catch let error as FileStoreError {
                return error.loadResult
            } catch {
                return .unreadable(daemonErrSecDecodeCompat)
            }
        }
    }

    @discardableResult
    public func save(_ record: DaemonPhoneKeyPinRecord) -> Int32 {
        saveAliasesAtomically([record])
    }

    @discardableResult
    public func saveAliasesAtomically(_ newRecords: [DaemonPhoneKeyPinRecord]) -> Int32 {
        state.withLock { _ in
            do {
                var records = try readStore()
                guard newRecords.allSatisfy({ records[$0.deviceId] == nil }) else {
                    return daemonErrSecDuplicateItemCompat
                }
                for record in newRecords {
                    records[record.deviceId] = record
                }
                try writeStore(records)
                return daemonErrSecSuccessCompat
            } catch let error as FileStoreError {
                return error.status
            } catch {
                return daemonErrSecParamCompat
            }
        }
    }

    public func delete(deviceId: String) {
        state.withLock { _ in
            do {
                var records = try readStore()
                records.removeValue(forKey: deviceId)
                try writeStore(records)
            } catch {
                return
            }
        }
    }

    private func readStore() throws -> [String: DaemonPhoneKeyPinRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        do {
            let data = try Data(contentsOf: fileURL)
            guard data.isEmpty == false else { return [:] }
            return try JSONDecoder().decode([String: DaemonPhoneKeyPinRecord].self, from: data)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return [:]
        } catch {
            throw FileStoreError(status: daemonErrSecDecodeCompat)
        }
    }

    private func writeStore(_ records: [String: DaemonPhoneKeyPinRecord]) throws {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            chmodPath(directory.path, mode: 0o700)
            let data = try JSONEncoder().encode(records)
            let tempURL = directory
                .appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
            try data.write(to: tempURL, options: [])
            chmodPath(tempURL.path, mode: 0o600)
            try renamePath(tempURL.path, to: fileURL.path)
            chmodPath(fileURL.path, mode: 0o600)
        } catch let error as FileStoreError {
            throw error
        } catch {
            throw FileStoreError(status: Int32(errno == 0 ? daemonErrSecParamCompat : errno))
        }
    }

    private func chmodPath(_ path: String, mode: mode_t) {
        path.withCString { _ = Glibc.chmod($0, mode) }
    }

    private func renamePath(_ source: String, to destination: String) throws {
        let status = source.withCString { sourcePointer in
            destination.withCString { destinationPointer in
                Glibc.rename(sourcePointer, destinationPointer)
            }
        }
        guard status == 0 else {
            throw FileStoreError(status: Int32(errno == 0 ? daemonErrSecParamCompat : errno))
        }
    }

    private struct FileStoreError: Error {
        let status: Int32

        var loadResult: DaemonPhoneKeyPinLoad {
            .unreadable(status)
        }
    }
}

extension DaemonPhoneKeyPinStore {
    public static func defaultBacking() -> DaemonPhoneKeyPinBacking {
        DaemonPhoneKeyFilePinBacking()
    }
}
#else
extension DaemonPhoneKeyPinStore {
    public static func defaultBacking() -> DaemonPhoneKeyPinBacking {
        DaemonPhoneKeyInMemoryPinBacking()
    }
}
#endif

public final class DaemonPhoneKeyInMemoryPinBacking: DaemonPhoneKeyAtomicAliasPinBacking, Sendable {
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
        saveAliasesAtomically([record])
    }

    @discardableResult
    public func saveAliasesAtomically(_ records: [DaemonPhoneKeyPinRecord]) -> Int32 {
        state.withLock { state in
            if let forcedWriteError = state.forcedWriteError { return forcedWriteError }
            guard records.allSatisfy({ state.store[$0.deviceId] == nil }) else {
                return daemonErrSecDuplicateItemCompat
            }
            for record in records {
                state.store[record.deviceId] = record
            }
            return daemonErrSecSuccessCompat
        }
    }

    public func delete(deviceId: String) {
        _ = state.withLock { $0.store.removeValue(forKey: deviceId) }
    }
}
