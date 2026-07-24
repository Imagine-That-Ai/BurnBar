import Foundation
import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import XCTest

final class BurnBarDaemonProjectCodeMemoryBootstrapTests: XCTestCase {
    func testCodeAndMemoryRPCsBootstrapAfterFreshChatDatabaseCreation() async throws {
        let directory = try makeTemporaryDirectory()
        let projectDirectory = directory.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let databasePath = directory.appendingPathComponent("openburnbar.sqlite").path
        XCTAssertFalse(FileManager.default.fileExists(atPath: databasePath))

        let server = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketAuthToken: "test-token",
                indexDatabasePath: databasePath,
                startsMissionControlBackgroundLoops: false
            )
        )

        // The chat store owns first-use creation. The code-memory store was
        // intentionally not opened during init because the file was absent at
        // the read-service bootstrap point above.
        XCTAssertTrue(FileManager.default.fileExists(atPath: databasePath))
        let chatStore = await server.chatThreadService
        XCTAssertNotNil(chatStore)

        let memoryData = try await server.handleMemoryRPC(
            method: .memoryRecall,
            decoder: JSONDecoder(),
            requestData: Data(
                "{\"id\":\"memory-fresh\",\"method\":\"daemon.memory.recall\",\"params\":{\"query\":\"fresh\",\"projectPath\":\"\(projectDirectory.path)\",\"limit\":5}}".utf8
            )
        )
        let memoryResponse = try JSONDecoder().decode(
            BurnBarRPCResponseEnvelope<BurnBarProjectMemoryRecallResponse>.self,
            from: memoryData
        )
        XCTAssertNil(memoryResponse.error)
        XCTAssertNotNil(memoryResponse.result)

        let codeData = try await server.handleCodeRPC(
            method: .codeIndexStatus,
            decoder: JSONDecoder(),
            requestData: Data(
                "{\"id\":\"code-fresh\",\"method\":\"daemon.code.index_status\",\"params\":{\"projectPath\":\"\(projectDirectory.path)\"}}".utf8
            )
        )
        let codeResponse = try JSONDecoder().decode(
            BurnBarRPCResponseEnvelope<BurnBarProjectCodeIndexStatusResponse>.self,
            from: codeData
        )
        XCTAssertNil(codeResponse.error)
        XCTAssertNotNil(codeResponse.result)
        let projectCodeMemory = await server.projectCodeMemory
        XCTAssertNotNil(projectCodeMemory)
    }

    func testCodeAndMemoryRPCsRemainUnavailableWithoutConfiguredDatabase() async throws {
        let server = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketAuthToken: "test-token",
                startsMissionControlBackgroundLoops: false
            )
        )

        let memoryData = try await server.handleMemoryRPC(
            method: .memoryRecall,
            decoder: JSONDecoder(),
            requestData: Data(
                #"{"id":"memory-no-db","method":"daemon.memory.recall","params":{"query":"test","limit":5}}"#.utf8
            )
        )
        let memoryResponse = try JSONDecoder().decode(
            BurnBarRPCResponseEnvelope<BurnBarProjectMemoryRecallResponse>.self,
            from: memoryData
        )
        XCTAssertNil(memoryResponse.result)
        XCTAssertEqual(memoryResponse.error?.code, BurnBarRPCErrorCode.internalError)

        let codeData = try await server.handleCodeRPC(
            method: .codeIndexStatus,
            decoder: JSONDecoder(),
            requestData: Data(
                #"{"id":"code-no-db","method":"daemon.code.index_status","params":{}}"#.utf8
            )
        )
        let codeResponse = try JSONDecoder().decode(
            BurnBarRPCResponseEnvelope<BurnBarProjectCodeIndexStatusResponse>.self,
            from: codeData
        )
        XCTAssertNil(codeResponse.result)
        XCTAssertEqual(codeResponse.error?.code, BurnBarRPCErrorCode.internalError)
    }

    func testFailedBootstrapIsCachedAndRemainsFailClosed() async throws {
        let directory = try makeTemporaryDirectory()
        let databasePath = directory.appendingPathComponent("database-directory", isDirectory: true).path
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: databasePath),
            withIntermediateDirectories: true
        )
        let server = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketAuthToken: "test-token",
                indexDatabasePath: databasePath,
                startsMissionControlBackgroundLoops: false
            )
        )

        let request = Data(
            #"{"id":"memory-failed","method":"daemon.memory.recall","params":{"query":"test","limit":5}}"#.utf8
        )
        let firstData = try await server.handleMemoryRPC(
            method: .memoryRecall,
            decoder: JSONDecoder(),
            requestData: request
        )
        let secondData = try await server.handleMemoryRPC(
            method: .memoryRecall,
            decoder: JSONDecoder(),
            requestData: request
        )
        let first = try JSONDecoder().decode(
            BurnBarRPCResponseEnvelope<BurnBarProjectMemoryRecallResponse>.self,
            from: firstData
        )
        let second = try JSONDecoder().decode(
            BurnBarRPCResponseEnvelope<BurnBarProjectMemoryRecallResponse>.self,
            from: secondData
        )
        XCTAssertNil(first.result)
        XCTAssertNil(second.result)
        XCTAssertEqual(first.error?.code, BurnBarRPCErrorCode.internalError)
        XCTAssertEqual(second.error?.code, BurnBarRPCErrorCode.internalError)
        XCTAssertEqual(first.error?.message, second.error?.message)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "openburnbar-project-code-memory-bootstrap-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }
}
