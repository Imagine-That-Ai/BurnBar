import XCTest
import GRDB
@testable import OpenBurnBar
import OpenBurnBarCore

@MainActor
final class ProviderAccountPersistenceTests: XCTestCase {
    func test_migration_v35_createsProviderAccountAndUsageAttributionSchema() throws {
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)

        let tables = try queue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        XCTAssertTrue(tables.contains("provider_accounts"))

        let usageColumns = try queue.read { db -> [String] in
            let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(token_usage)")
            return rows.compactMap { $0["name"] as? String }
        }
        XCTAssertTrue(usageColumns.contains("providerID"))
        XCTAssertTrue(usageColumns.contains("providerAccountID"))
        XCTAssertTrue(usageColumns.contains("providerAccountLabel"))
        XCTAssertTrue(usageColumns.contains("providerAccountSource"))

        let indexes = try queue.read { db -> [String] in
            let rows = try Row.fetchAll(db, sql: "PRAGMA index_list(token_usage)")
            return rows.compactMap { $0["name"] as? String }
        }
        XCTAssertTrue(indexes.contains("token_usage_unique_session_model_device_account_idx"))
    }

    func test_usageStore_preservesProviderAccountAttributionOnInsertAndFetch() throws {
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let store = UsageStore(dbQueue: queue)

        let usage = makeUsage(
            accountID: "openai_work",
            label: "Work",
            source: .cloudRefreshable
        )
        try store.insert(usage)

        let fetched = try XCTUnwrap(store.fetchAllUsage().first)
        XCTAssertEqual(fetched.providerID, .openAI)
        XCTAssertEqual(fetched.providerAccountID, "openai_work")
        XCTAssertEqual(fetched.providerAccountLabel, "Work")
        XCTAssertEqual(fetched.providerAccountSource, .cloudRefreshable)
    }

    func test_usageStore_keepsSameProviderSessionSeparateByAccountID() throws {
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let store = UsageStore(dbQueue: queue)

        try store.insert(makeUsage(accountID: "openai_work", label: "Work", inputTokens: 100))
        try store.insert(makeUsage(accountID: "openai_personal", label: "Personal", inputTokens: 200))

        let rows = try queue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT providerAccountID, inputTokens
                    FROM token_usage
                    WHERE sessionId = 'shared-session'
                    ORDER BY providerAccountID ASC
                    """
            )
        }

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.compactMap { $0["providerAccountID"] as? String }, ["openai_personal", "openai_work"])
    }

    func test_insertRemoteUsage_preservesAccountFields() throws {
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let store = UsageStore(dbQueue: queue)

        let usage = makeUsage(
            accountID: "openai_client",
            label: "Client",
            source: .serverPrivate,
            isRemote: true
        )
        try store.insertRemoteUsage(usage)

        let fetched = try XCTUnwrap(store.fetchAllUsage().first)
        XCTAssertEqual(fetched.providerAccountID, "openai_client")
        XCTAssertEqual(fetched.providerAccountLabel, "Client")
        XCTAssertEqual(fetched.providerAccountSource, .serverPrivate)
    }

    func test_providerAccountStore_roundTripsMultipleAccountsForSameProvider() throws {
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let store = ProviderAccountStore(dbQueue: queue)

        let work = makeAccount(id: "openai_work", label: "Work", sortKey: 2)
        let personal = makeAccount(id: "openai_personal", label: "Personal", sortKey: 1)

        try store.upsert(work)
        try store.upsert(personal)

        let fetched = try store.fetchAll(providerID: .openAI)
        XCTAssertEqual(fetched.map(\.id), ["openai_personal", "openai_work"])
        XCTAssertEqual(try store.fetch(id: "openai_work")?.label, "Work")
        XCTAssertEqual(try store.fetchAll(providerID: .claudeCode), [])
    }

    func test_providerAccountStore_setDefaultIsScopedToProvider() throws {
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let store = ProviderAccountStore(dbQueue: queue)

        try store.upsert(makeAccount(id: "openai_work", label: "Work", providerID: .openAI, isDefault: true))
        try store.upsert(makeAccount(id: "openai_personal", label: "Personal", providerID: .openAI))
        try store.upsert(makeAccount(id: "claude_default", label: "Claude", providerID: .claudeCode, isDefault: true))

        try store.setDefault(accountID: "openai_personal", providerID: .openAI)

        XCTAssertEqual(try store.fetchDefault(providerID: .openAI)?.id, "openai_personal")
        XCTAssertEqual(try store.fetchDefault(providerID: .claudeCode)?.id, "claude_default")
        XCTAssertFalse(try XCTUnwrap(store.fetch(id: "openai_work")).isDefault)
    }

    func test_providerAccountStore_deleteRemovesOnlySelectedAccount() throws {
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let store = ProviderAccountStore(dbQueue: queue)

        try store.upsert(makeAccount(id: "openai_work", label: "Work"))
        try store.upsert(makeAccount(id: "openai_personal", label: "Personal"))

        try store.delete(id: "openai_work")

        XCTAssertNil(try store.fetch(id: "openai_work"))
        XCTAssertEqual(try store.fetchAll(providerID: .openAI).map(\.id), ["openai_personal"])
    }

    private func makeUsage(
        accountID: String,
        label: String,
        source: ProviderAccountStorageScope = .cloudRefreshable,
        inputTokens: Int = 100,
        usageSource: UsageSource = .providerLog,
        isRemote: Bool = false
    ) -> TokenUsage {
        TokenUsage(
            provider: .codex,
            sessionId: "shared-session",
            projectName: "BurnBar",
            model: "codex-pro",
            inputTokens: inputTokens,
            outputTokens: 50,
            costUSD: 0.01,
            startTime: Date(timeIntervalSinceReferenceDate: 800_000_000),
            endTime: Date(timeIntervalSinceReferenceDate: 800_000_060),
            usageSource: usageSource,
            sourceDeviceId: "mac-1",
            isRemote: isRemote,
            providerID: .openAI,
            providerAccountID: accountID,
            providerAccountLabel: label,
            providerAccountSource: source,
            provenanceMethod: .providerLog,
            provenanceConfidence: .exact
        )
    }

    private func makeAccount(
        id: String,
        label: String,
        providerID: ProviderID = .openAI,
        isDefault: Bool = false,
        sortKey: Double = 0
    ) -> ProviderAccountDoc {
        let createdAt = Date(timeIntervalSinceReferenceDate: 800_100_000 + sortKey)
        return ProviderAccountDoc(
            id: id,
            providerID: providerID,
            label: label,
            identityHint: "\(label.lowercased())@example.com",
            status: .connected,
            credentialKind: .bearer,
            storageScope: .serverPrivate,
            redactedLabel: "sk-...\(id.suffix(4))",
            sourceDeviceID: "mac-1",
            isDefault: isDefault,
            sortKey: sortKey,
            lastValidatedAt: createdAt,
            lastRefreshAt: createdAt,
            schemaVersion: 1,
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }
}
