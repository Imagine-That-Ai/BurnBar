import Foundation
import XCTest
@testable import BurnBar

final class BurnBarMigrationTests: XCTestCase {

    func test_filesystemMigration_movesLegacySupportDirectoryAndRenamesDatabase() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let paths = BurnBarAppPaths(applicationSupportRoot: root)
        let legacyDirectory = root.appendingPathComponent("AgentLens", isDirectory: true)
        try fileManager.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)

        let legacyDatabase = legacyDirectory.appendingPathComponent("agentlens.sqlite")
        try Data("legacy-db".utf8).write(to: legacyDatabase)

        let legacyUsageLog = legacyDirectory.appendingPathComponent("cursor_connector_usage.jsonl")
        try Data("{}".utf8).write(to: legacyUsageLog)

        let migration = BurnBarFilesystemMigration(fileManager: fileManager, paths: paths)
        let migratedDirectory = try migration.prepareSupportDirectory()

        XCTAssertEqual(migratedDirectory.standardizedFileURL, paths.supportDirectory.standardizedFileURL)
        XCTAssertTrue(fileManager.fileExists(atPath: paths.supportDirectory.path))
        XCTAssertTrue(fileManager.fileExists(atPath: paths.databaseURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: legacyDatabase.path))
        XCTAssertTrue(
            fileManager.fileExists(
                atPath: paths.supportDirectory.appendingPathComponent("cursor_connector_usage.jsonl").path
            )
        )

        let databaseContents = try Data(contentsOf: paths.databaseURL)
        XCTAssertEqual(String(decoding: databaseContents, as: UTF8.self), "legacy-db")

        _ = try migration.prepareSupportDirectory()
        XCTAssertTrue(fileManager.fileExists(atPath: paths.databaseURL.path))
    }

    func test_defaultsMigration_preservesLegacyDomainWithoutOverwritingCurrentValues() {
        let currentDomain = "com.burnbar.tests.\(UUID().uuidString)"
        let legacyDomain = "com.agentlens.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: currentDomain) else {
            XCTFail("Could not create isolated defaults suite")
            return
        }
        defaults.removePersistentDomain(forName: currentDomain)
        defaults.removePersistentDomain(forName: legacyDomain)
        defer {
            defaults.removePersistentDomain(forName: currentDomain)
            defaults.removePersistentDomain(forName: legacyDomain)
        }

        defaults.setPersistentDomain(
            [
                "showInMenuBar": false,
                CursorConnectorConfig.defaultsKey: Data("legacy-config".utf8)
            ],
            forName: legacyDomain
        )
        defaults.set(true, forKey: "hasLaunchedBefore")
        defaults.set(true, forKey: "showInMenuBar")

        BurnBarDefaultsMigration(defaults: defaults, legacyDomains: [legacyDomain]).migrateIfNeeded()

        XCTAssertEqual(defaults.bool(forKey: "showInMenuBar"), true)
        XCTAssertEqual(defaults.bool(forKey: "hasLaunchedBefore"), true)
        XCTAssertEqual(
            defaults.data(forKey: CursorConnectorConfig.defaultsKey),
            Data("legacy-config".utf8)
        )
    }

    func test_keychainStore_readsLegacyServiceAndPromotesValue() throws {
        let backend = InMemoryKeychainBackend()
        let account = "provider.zai.apiKey"
        let legacyService = "com.agentlens.cursor-connector"
        let currentService = "com.burnbar.cursor-connector"
        try backend.set(Data("secret-value".utf8), service: legacyService, account: account)

        let store = KeychainStore(
            service: currentService,
            legacyServices: [legacyService],
            backend: backend
        )

        XCTAssertEqual(try store.string(for: account), "secret-value")
        XCTAssertEqual(
            try backend.data(for: currentService, account: account),
            Data("secret-value".utf8)
        )
    }
}

private final class InMemoryKeychainBackend: KeychainStoreBackend {
    private var storage: [String: [String: Data]] = [:]

    func set(_ value: Data, service: String, account: String) throws {
        storage[service, default: [:]][account] = value
    }

    func data(for service: String, account: String) throws -> Data? {
        storage[service]?[account]
    }

    func delete(service: String, account: String) throws {
        storage[service]?[account] = nil
    }
}
