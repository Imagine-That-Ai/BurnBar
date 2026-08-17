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
    private let storage = Locked<[String: [String: Data]]>([:])

    func set(_ value: Data, service: String, account: String) throws {
        storage.withLock { $0[service, default: [:]][account] = value }
    }

    func data(for service: String, account: String, allowUserInteraction _: Bool) throws -> Data? {
        storage.withLock { $0[service]?[account] }
    }

    func delete(service: String, account: String) throws {
        storage.withLock { $0[service]?[account] = nil }
    }
}

final class InteractionLockedWriteTestKeychainBackend: KeychainStoreBackend {
    private struct State: Sendable {
        var storage: [String: [String: Data]] = [:]
        var lockedEntries = Set<String>()
        var writeCounts: [String: Int] = [:]
        var deleteCounts: [String: Int] = [:]
    }

    private let state = Locked(State())

    func set(_ value: Data, service: String, account: String) throws {
        let key = entryKey(service: service, account: account)
        state.withLock { state in
            let nextWriteCount = (state.writeCounts[key] ?? 0) + 1
            state.writeCounts[key] = nextWriteCount
            state.storage[service, default: [:]][account] = value
            if nextWriteCount == 1 {
                state.lockedEntries.insert(key)
            } else {
                state.lockedEntries.remove(key)
            }
        }
    }

    func data(for service: String, account: String, allowUserInteraction: Bool) throws -> Data? {
        let key = entryKey(service: service, account: account)
        return state.withLock { state in
            if !allowUserInteraction && state.lockedEntries.contains(key) {
                return nil
            }
            return state.storage[service]?[account]
        }
    }

    func delete(service: String, account: String) throws {
        let key = entryKey(service: service, account: account)
        state.withLock { state in
            state.storage[service]?[account] = nil
            state.lockedEntries.remove(key)
            state.deleteCounts[key, default: 0] += 1
        }
    }

    func writeCount(for service: String, account: String) -> Int {
        let key = entryKey(service: service, account: account)
        return state.withLock { $0.writeCounts[key] ?? 0 }
    }

    func deleteCount(for service: String, account: String) -> Int {
        let key = entryKey(service: service, account: account)
        return state.withLock { $0.deleteCounts[key] ?? 0 }
    }

    private func entryKey(service: String, account: String) -> String {
        "\(service)|\(account)"
    }
}

final class AlwaysInteractionLockedTestKeychainBackend: KeychainStoreBackend {
    private let storage = Locked<[String: [String: Data]]>([:])

    func set(_ value: Data, service: String, account: String) throws {
        storage.withLock { $0[service, default: [:]][account] = value }
    }

    func data(for service: String, account: String, allowUserInteraction: Bool) throws -> Data? {
        if !allowUserInteraction {
            return nil
        }
        return storage.withLock { $0[service]?[account] }
    }

    func delete(service: String, account: String) throws {
        storage.withLock { $0[service]?[account] = nil }
    }
}

/// A KeychainStore backend that always fails on `set` and `delete`,
/// simulating a locked or inaccessible Keychain.
final class FailingWriteKeychainBackend: KeychainStoreBackend {
    func set(_: Data, service: String, account: String) throws {
        throw KeychainStoreError.unhandled(errSecIO)
    }

    func data(for service: String, account: String, allowUserInteraction _: Bool) throws -> Data? {
        nil
    }

    func delete(service _: String, account _: String) throws {
        throw KeychainStoreError.unhandled(errSecIO)
    }
}

/// A KeychainStore backend that accepts writes but returns a different value on read,
/// simulating a verification mismatch after migration.
final class VerificationMismatchKeychainBackend: KeychainStoreBackend {
    private let storage = Locked<[String: [String: Data]]>([:])

    func set(_ value: Data, service: String, account: String) throws {
        // Store a *different* value to simulate verification mismatch
        storage.withLock {
            $0[service, default: [:]][account] = "mismatched-value".data(using: .utf8) ?? value
        }
    }

    func data(for service: String, account: String, allowUserInteraction _: Bool) throws -> Data? {
        storage.withLock { $0[service]?[account] }
    }

    func delete(service: String, account: String) throws {
        storage.withLock { $0[service]?[account] = nil }
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

/// A `SettingsManager` on isolated defaults and throwaway keychains.
///
/// The usage-memory fleet switches are seeded ALLOWING, i.e. the steady state
/// after a successful Remote Config read. Without a seed the usage lanes are held
/// CLOSED (no `FirebaseApp` in the test host means no fleet value ever resolves —
/// see `MemorySettings.hasResolvedUsageRemoteConfig`), which would make every
/// consent/placement test assert against a permanently shut gate. Tests that are
/// *about* resolution — cached fleet kills, the pre-Remote-Config launch window —
/// construct `SettingsManager` directly with their own
/// `usageMemoryRemoteConfigSeed`; see `UsageMemoryGateTests`.
@MainActor
func makeSettingsManager(
    defaults: UserDefaults? = nil,
    controllerSecrets: KeychainStore? = nil,
    gatewaySecrets: KeychainStore? = nil,
    usageMemoryRemoteConfigSeed: () -> UsageMemoryRemoteConfigSnapshot? = {
        UsageMemoryRemoteConfigSnapshot(extractionEnabled: true, authorityWritesEnabled: true)
    }
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
        ),
        usageMemoryRemoteConfigSeed: usageMemoryRemoteConfigSeed
    )
}
