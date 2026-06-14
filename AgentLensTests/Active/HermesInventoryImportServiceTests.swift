import Foundation
import GRDB
import OpenBurnBarCore
import XCTest
@testable import OpenBurnBar

@MainActor
final class HermesInventoryImportServiceTests: XCTestCase {
    func testImportInventoryChunkedInsertsUsagesAcrossChunkBoundaries() async throws {
        // Regression for the user-reported "SQLite error 10: disk I/O error -
        // while executing INSERT INTO token_usage" crash during Hermes import.
        // The chunked insert path used by the import service must commit every
        // row even when the input crosses the default chunk boundary.
        let queue = try DatabaseQueue()
        let dataStore = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)

        let usageCount = 250
        let usages: [TokenUsage] = (0..<usageCount).map { index in
            TokenUsage(
                provider: .hermes,
                sessionId: "session-\(index)",
                projectName: "Hermes",
                model: "hermes",
                inputTokens: 10,
                outputTokens: 20,
                costUSD: 0.001,
                startTime: Date(timeIntervalSince1970: TimeInterval(1_000 + index)),
                endTime: Date(timeIntervalSince1970: TimeInterval(1_000 + index + 1)),
                provenanceMethod: .providerLog,
                provenanceConfidence: .exact
            )
        }

        let service = HermesInventoryImportService(
            dataStore: dataStore,
            settingsManager: SettingsManager(),
            parseInventory: {
                ParseResult(usages: usages, conversations: [])
            },
            preflight: .alwaysOk
        )

        await service.scan()
        await service.importInventory()

        XCTAssertEqual(service.phase, .complete, "Import should complete; got \(service.phase)")
        let stored = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM token_usage") ?? 0
        }
        XCTAssertEqual(stored, usageCount)
    }

    func testImportInventorySurfacesPreflightFailureAsActionableMessage() async throws {
        let queue = try DatabaseQueue()
        let dataStore = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)

        let blockingPreflight = HermesInventoryImportPreflight { _ in
            throw HermesInventoryImportPreflightError.insufficientDiskSpace(
                availableBytes: 1_000_000,
                neededBytes: 50_000_000,
                path: "/tmp/openburnbar-test"
            )
        }

        let service = HermesInventoryImportService(
            dataStore: dataStore,
            settingsManager: SettingsManager(),
            parseInventory: {
                ParseResult(usages: [], conversations: [])
            },
            preflight: blockingPreflight
        )

        await service.scan()
        await service.importInventory()

        guard case let .failed(message) = service.phase else {
            XCTFail("Expected .failed phase, got \(service.phase)")
            return
        }
        XCTAssertTrue(message.contains("Not enough free space"), "Message should be actionable; got: \(message)")
        XCTAssertFalse(message.contains("SQLite"), "Preflight failure should not leak raw GRDB text; got: \(message)")
    }

    func testDescribeMapsSQLiteIOErrorToActionableGuidance() {
        let dbError = DatabaseError(
            resultCode: .SQLITE_IOERR,
            message: "disk I/O error",
            sql: "INSERT INTO token_usage (...)"
        )
        let message = HermesInventoryImportService.describe(dbError)
        XCTAssertFalse(
            message.hasPrefix("SQLite error 10"),
            "Raw GRDB text should not be the entire user-facing message; got: \(message)"
        )
        XCTAssertTrue(message.contains("disk space") || message.contains("permissions"))
    }

    func testDescribeMapsSQLiteFullToDiskFullGuidance() {
        let dbError = DatabaseError(
            resultCode: .SQLITE_FULL,
            message: "database or disk is full",
            sql: "INSERT INTO token_usage (...)"
        )
        let message = HermesInventoryImportService.describe(dbError)
        XCTAssertTrue(message.lowercased().contains("disk is full"))
    }

    func testPreflightFailsClosedWhenCapacityProbeThrows() {
        // A failed volume-capacity read (volume ejected, directory vanished,
        // transient I/O error) must NOT be treated as "enough free space".
        // Before the fix, a `try?` swallowed the error, `availableBytes` was nil,
        // the disk-space gate was skipped, and the import proceeded fail-open.
        // Now the probe failure surfaces as a fail-closed preflight error.
        struct ProbeFailure: Error {}
        let preflight = HermesInventoryImportPreflight.make(
            availableCapacityProbe: { _ in throw ProbeFailure() }
        )

        var thrown: Error?
        XCTAssertThrowsError(try preflight.check(0)) { thrown = $0 }

        guard case .capacityUnverifiable = thrown as? HermesInventoryImportPreflightError else {
            XCTFail("Expected capacityUnverifiable, got \(String(describing: thrown))")
            return
        }
    }

    func testPreflightTreatsSuccessfulNilCapacityReadAsEnough() throws {
        // A *successful* read that simply has no capacity value (key unavailable
        // on this volume kind) is not a failure — it must preserve the prior
        // lenient behavior and not block the import.
        let preflight = HermesInventoryImportPreflight.make(
            availableCapacityProbe: { _ in nil }
        )
        XCTAssertNoThrow(try preflight.check(0))
    }

    func testPreflightStillBlocksOnInsufficientReadableCapacity() {
        // The fail-closed change must not regress the original insufficient-space
        // gate: a successful read that reports less than the needed bytes still
        // throws insufficientDiskSpace (not capacityUnverifiable).
        let preflight = HermesInventoryImportPreflight.make(
            availableCapacityProbe: { _ in 1 }
        )

        var thrown: Error?
        XCTAssertThrowsError(try preflight.check(0)) { thrown = $0 }

        guard case .insufficientDiskSpace = thrown as? HermesInventoryImportPreflightError else {
            XCTFail("Expected insufficientDiskSpace, got \(String(describing: thrown))")
            return
        }
    }

    func testCapacityUnverifiableMessageIsActionableAndLeaksNoRawSQLite() {
        let error = HermesInventoryImportPreflightError.capacityUnverifiable(
            path: "/tmp/openburnbar-test"
        )
        let message = HermesInventoryImportService.describe(error)
        XCTAssertTrue(
            message.contains("free space") || message.contains("reachable"),
            "Message should be actionable; got: \(message)"
        )
        XCTAssertFalse(message.contains("SQLite"), "Should not leak raw GRDB text; got: \(message)")
    }

    func testImportInventoryFailsClosedWithoutPartialWriteWhenCapacityUnverifiable() async throws {
        // End-to-end: when capacity is unverifiable the import must fail closed
        // and write NOTHING — no usage rows, no conversations — so we never leave
        // a half-applied chunked transaction behind.
        let queue = try DatabaseQueue()
        let dataStore = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)

        let usages: [TokenUsage] = (0..<10).map { index in
            TokenUsage(
                provider: .hermes,
                sessionId: "session-\(index)",
                projectName: "Hermes",
                model: "hermes",
                inputTokens: 10,
                outputTokens: 20,
                costUSD: 0.001,
                startTime: Date(timeIntervalSince1970: TimeInterval(1_000 + index)),
                endTime: Date(timeIntervalSince1970: TimeInterval(1_000 + index + 1)),
                provenanceMethod: .providerLog,
                provenanceConfidence: .exact
            )
        }

        let failClosedPreflight = HermesInventoryImportPreflight { _ in
            throw HermesInventoryImportPreflightError.capacityUnverifiable(
                path: "/tmp/openburnbar-test"
            )
        }

        let service = HermesInventoryImportService(
            dataStore: dataStore,
            settingsManager: SettingsManager(),
            parseInventory: {
                ParseResult(usages: usages, conversations: [])
            },
            preflight: failClosedPreflight
        )

        await service.scan()
        await service.importInventory()

        guard case let .failed(message) = service.phase else {
            XCTFail("Expected .failed phase, got \(service.phase)")
            return
        }
        XCTAssertTrue(
            message.contains("free space") || message.contains("reachable"),
            "Message should be actionable; got: \(message)"
        )

        let storedUsages = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM token_usage") ?? 0
        }
        XCTAssertEqual(storedUsages, 0, "Fail-closed import must not write any usage rows")
        XCTAssertEqual(try dataStore.countConversations(), 0, "Fail-closed import must not index any conversations")
    }

    func testImportInventoryIsIdempotentForExistingHermesConversations() async throws {
        let queue = try DatabaseQueue()
        let dataStore = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let record = ConversationRecord(
            id: ConversationRecord.stableId(provider: .hermes, sessionId: "session-1"),
            provider: .hermes,
            sessionId: "session-1",
            projectName: "Hermes",
            startTime: Date(timeIntervalSince1970: 100),
            endTime: Date(timeIntervalSince1970: 120),
            messageCount: 2,
            userWordCount: 3,
            assistantWordCount: 4,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: "Import Hermes chats",
            lastAssistantMessage: "Done",
            fullText: "User: import\n\nAssistant: Done",
            indexedAt: Date(timeIntervalSince1970: 130),
            fileModifiedAt: Date(timeIntervalSince1970: 130),
            summary: nil
        )
        let service = HermesInventoryImportService(
            dataStore: dataStore,
            settingsManager: SettingsManager(),
            parseInventory: {
                ParseResult(usages: [], conversations: [record])
            },
            preflight: .alwaysOk
        )

        await service.scan()
        await service.importInventory()
        await service.importInventory()

        XCTAssertEqual(service.summary.conversationCount, 1)
        XCTAssertEqual(try dataStore.countConversations(), 1)
        XCTAssertEqual(service.progress.skippedConversationCount, 1)
    }
}
