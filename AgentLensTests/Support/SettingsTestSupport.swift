import Foundation
import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

// MARK: - Isolated Defaults

func makeIsolatedDefaults() -> UserDefaults {
    let suiteName = "com.openburnbar.tests.settings.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        fatalError("Could not create isolated defaults suite")
    }
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

// MARK: - Temporary Directory

func makeTemporaryDirectory(trackedBy tempDirectories: inout [URL]) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    tempDirectories.append(directory)
    return directory
}

// MARK: - Test Keychain Backends

final class SettingsManagerTestKeychainBackend: KeychainStoreBackend {
    private var storage: [String: [String: Data]] = [:]

    func set(_ value: Data, service: String, account: String) throws {
        storage[service, default: [:]][account] = value
    }

    func data(for service: String, account: String, allowUserInteraction _: Bool) throws -> Data? {
        storage[service]?[account]
    }

    func delete(service: String, account: String) throws {
        storage[service]?[account] = nil
    }
}

final class InteractionLockedWriteTestKeychainBackend: KeychainStoreBackend {
    private var storage: [String: [String: Data]] = [:]
    private var lockedEntries = Set<String>()
    private var writeCounts: [String: Int] = [:]
    private var deleteCounts: [String: Int] = [:]

    func set(_ value: Data, service: String, account: String) throws {
        let key = entryKey(service: service, account: account)
        let nextWriteCount = (writeCounts[key] ?? 0) + 1
        writeCounts[key] = nextWriteCount
        storage[service, default: [:]][account] = value
        if nextWriteCount == 1 {
            lockedEntries.insert(key)
        } else {
            lockedEntries.remove(key)
        }
    }

    func data(for service: String, account: String, allowUserInteraction: Bool) throws -> Data? {
        let key = entryKey(service: service, account: account)
        if !allowUserInteraction && lockedEntries.contains(key) {
            return nil
        }
        return storage[service]?[account]
    }

    func delete(service: String, account: String) throws {
        let key = entryKey(service: service, account: account)
        storage[service]?[account] = nil
        lockedEntries.remove(key)
        deleteCounts[key, default: 0] += 1
    }

    func writeCount(for service: String, account: String) -> Int {
        writeCounts[entryKey(service: service, account: account)] ?? 0
    }

    func deleteCount(for service: String, account: String) -> Int {
        deleteCounts[entryKey(service: service, account: account)] ?? 0
    }

    private func entryKey(service: String, account: String) -> String {
        "\(service)|\(account)"
    }
}

final class AlwaysInteractionLockedTestKeychainBackend: KeychainStoreBackend {
    private var storage: [String: [String: Data]] = [:]

    func set(_ value: Data, service: String, account: String) throws {
        storage[service, default: [:]][account] = value
    }

    func data(for service: String, account: String, allowUserInteraction: Bool) throws -> Data? {
        if !allowUserInteraction {
            return nil
        }
        return storage[service]?[account]
    }

    func delete(service: String, account: String) throws {
        storage[service]?[account] = nil
    }
}

/// A KeychainStore backend that always fails on `set` and `delete`,
/// simulating a locked or inaccessible Keychain.
final class FailingWriteKeychainBackend: KeychainStoreBackend {
    private var storage: [String: [String: Data]] = [:]

    func set(_: Data, service: String, account: String) throws {
        throw KeychainStoreError.unhandled(errSecIO)
    }

    func data(for service: String, account: String, allowUserInteraction _: Bool) throws -> Data? {
        storage[service]?[account]
    }

    func delete(service _: String, account _: String) throws {
        throw KeychainStoreError.unhandled(errSecIO)
    }
}

/// A KeychainStore backend that accepts writes but returns a different value on read,
/// simulating a verification mismatch after migration.
final class VerificationMismatchKeychainBackend: KeychainStoreBackend {
    private var storage: [String: [String: Data]] = [:]

    func set(_ value: Data, service: String, account: String) throws {
        // Store a *different* value to simulate verification mismatch
        storage[service, default: [:]][account] = "mismatched-value".data(using: .utf8) ?? value
    }

    func data(for service: String, account: String, allowUserInteraction _: Bool) throws -> Data? {
        storage[service]?[account]
    }

    func delete(service: String, account: String) throws {
        storage[service]?[account] = nil
    }
}

// MARK: - Factory Helpers

func makeTestKeychainStore() -> KeychainStore {
    KeychainStore(
        service: "tests.\(UUID().uuidString)",
        legacyServices: [],
        backend: SettingsManagerTestKeychainBackend()
    )
}

@MainActor
func makeSettingsManager(
    defaults: UserDefaults? = nil,
    controllerSecrets: KeychainStore? = nil,
    gatewaySecrets: KeychainStore? = nil
) -> SettingsManager {
    SettingsManager(
        defaults: defaults ?? makeIsolatedDefaults(),
        controllerRuntimeSecrets: controllerSecrets ?? KeychainStore(
            service: "tests.controller.\(UUID().uuidString)",
            legacyServices: [],
            backend: SettingsManagerTestKeychainBackend()
        ),
        chatGatewaySecrets: gatewaySecrets ?? KeychainStore(
            service: "tests.gateway.\(UUID().uuidString)",
            legacyServices: [],
            backend: SettingsManagerTestKeychainBackend()
        )
    )
}
