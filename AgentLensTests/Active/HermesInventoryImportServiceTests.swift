import Foundation
import GRDB
import XCTest
@testable import OpenBurnBar

@MainActor
final class HermesInventoryImportServiceTests: XCTestCase {
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
            }
        )

        await service.scan()
        await service.importInventory()
        await service.importInventory()

        XCTAssertEqual(service.summary.conversationCount, 1)
        XCTAssertEqual(try dataStore.countConversations(), 1)
        XCTAssertEqual(service.progress.skippedConversationCount, 1)
    }
}
