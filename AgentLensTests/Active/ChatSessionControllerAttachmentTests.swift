import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

@MainActor
final class ChatSessionControllerAttachmentTests: XCTestCase {

    func test_addAttachment_fromImageURL_stagesAttachment() throws {
        let dataStore = try makeDiscoveryInMemoryStore()

        let controller = ChatSessionController(
            dataStore: dataStore,
            searchService: ControlledChatSessionSearchProvider(responses: [:])
        )

        let pngBytes = makeTinyPNG()
        let tmpURL = try writeTempFile(named: "tiny.png", data: pngBytes)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        XCTAssertTrue(controller.pendingAttachments.isEmpty)
        controller.addAttachment(from: tmpURL)

        XCTAssertEqual(controller.pendingAttachments.count, 1)
        let attachment = try XCTUnwrap(controller.pendingAttachments.first)
        XCTAssertEqual(attachment.kind, .image)
        XCTAssertEqual(attachment.displayName, "tiny.png")
        XCTAssertNil(controller.attachmentError)
    }

    func test_removeAttachment_dropsFromPending() throws {
        let dataStore = try makeDiscoveryInMemoryStore()

        let controller = ChatSessionController(
            dataStore: dataStore,
            searchService: ControlledChatSessionSearchProvider(responses: [:])
        )

        let textURL = try writeTempFile(named: "notes.md", data: "# Hello".data(using: .utf8)!)
        defer { try? FileManager.default.removeItem(at: textURL) }

        controller.addAttachment(from: textURL)
        XCTAssertEqual(controller.pendingAttachments.count, 1)

        let id = try XCTUnwrap(controller.pendingAttachments.first?.id)
        controller.removeAttachment(id)
        XCTAssertTrue(controller.pendingAttachments.isEmpty)
    }

    func test_addAttachment_oversizedFile_setsErrorAndKeepsListEmpty() throws {
        let dataStore = try makeDiscoveryInMemoryStore()

        let controller = ChatSessionController(
            dataStore: dataStore,
            searchService: ControlledChatSessionSearchProvider(responses: [:])
        )

        // 21 MB synthetic PNG-ish bytes (header just gives us .image kind, the
        // 20 MB cap should reject it on import).
        var blob = Data(repeating: 0xFF, count: 21 * 1024 * 1024)
        let pngHeader: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        blob.replaceSubrange(0..<pngHeader.count, with: pngHeader)
        let tmpURL = try writeTempFile(named: "huge.png", data: blob)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        controller.addAttachment(from: tmpURL)
        XCTAssertTrue(controller.pendingAttachments.isEmpty)
        XCTAssertNotNil(controller.attachmentError)
    }

    func test_openOrCreateChatThread_usesMobileThreadIDAndRestoresMessages() async throws {
        let dataStore = try makeDiscoveryInMemoryStore()

        let controller = ChatSessionController(
            dataStore: dataStore,
            searchService: ControlledChatSessionSearchProvider(responses: [:])
        )
        let mobileThreadID = "mobile-codex-ios_123"

        await controller.openOrCreateChatThreadAsync(id: mobileThreadID)

        XCTAssertEqual(controller.activeThreadID, mobileThreadID)
        let threadExists = try await dataStore.chatThreadExists(id: mobileThreadID)
        XCTAssertTrue(threadExists)

        let userMessage = ChatMessageRecord(
            id: "u1",
            role: .user,
            content: "Keep this context.",
            timestamp: Date(timeIntervalSince1970: 1_800_000_000)
        )
        try await dataStore.saveChatMessage(userMessage, threadID: mobileThreadID)

        await controller.startNewChatThreadAsync()
        XCTAssertNotEqual(controller.activeThreadID, mobileThreadID)

        await controller.openOrCreateChatThreadAsync(id: mobileThreadID)

        XCTAssertEqual(controller.activeThreadID, mobileThreadID)
        XCTAssertEqual(controller.messages.map(\.content), ["Keep this context."])
    }

    // MARK: - Helpers

    private func writeTempFile(named name: String, data: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-attach-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// 1×1 transparent PNG.
    private func makeTinyPNG() -> Data {
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=")!
    }
}
