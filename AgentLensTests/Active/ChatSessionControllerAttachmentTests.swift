import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

@MainActor
final class ChatSessionControllerAttachmentTests: XCTestCase {

    func test_addAttachment_fromImageURL_stagesAttachment() throws {
        let harness = try OpenBurnBarSearchIntegrationHarness(name: "chat-attach-add")
        defer { harness.cleanup() }

        let controller = ChatSessionController(
            dataStore: harness.dataStore,
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
        let harness = try OpenBurnBarSearchIntegrationHarness(name: "chat-attach-remove")
        defer { harness.cleanup() }

        let controller = ChatSessionController(
            dataStore: harness.dataStore,
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
        let harness = try OpenBurnBarSearchIntegrationHarness(name: "chat-attach-oversize")
        defer { harness.cleanup() }

        let controller = ChatSessionController(
            dataStore: harness.dataStore,
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

    // MARK: - T-ATT-05: content-sniffing / mime-vs-bytes verification

    /// A blob whose bytes are an HTML document but which is labeled `.png` /
    /// `image/png` must be refused on import — it must not be admitted and then
    /// rendered as an image in the Mercury preview path.
    func test_importFile_rejectsHTMLBlobMislabeledAsPNG() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("att-mislabel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let htmlBytes = Data("<!DOCTYPE html><html><body><script>alert(1)</script></body></html>".utf8)
        let tmpURL = try writeTempFile(named: "totally-an-image.png", data: htmlBytes)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        XCTAssertThrowsError(try HermesAttachmentLoader.importFile(at: tmpURL, intoWorkspace: workspace)) { error in
            guard case HermesAttachmentLoader.LoaderError.unsafeAttachment = error else {
                return XCTFail("Expected unsafeAttachment, got \(error)")
            }
        }
    }

    /// A genuine PNG still imports cleanly (no false positive from the sniff).
    func test_importFile_acceptsGenuinePNG() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("att-genuine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let tmpURL = try writeTempFile(named: "tiny.png", data: makeTinyPNG())
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let attachment = try HermesAttachmentLoader.importFile(at: tmpURL, intoWorkspace: workspace)
        XCTAssertEqual(attachment.kind, .image)
    }

    /// Pure sniff helpers: active markup is detected (even past a BOM /
    /// whitespace) and known image magic numbers are recognized.
    func test_contentSniff_pureHelpers() {
        XCTAssertTrue(HermesAttachmentLoader.bytesSniffAsActiveContent(Data("<svg onload=alert(1)>".utf8)))
        XCTAssertTrue(HermesAttachmentLoader.bytesSniffAsActiveContent(Data("   \n<html>".utf8)))
        XCTAssertTrue(HermesAttachmentLoader.bytesSniffAsActiveContent(Data([0xEF, 0xBB, 0xBF]) + Data("<!doctype html>".utf8)))
        XCTAssertFalse(HermesAttachmentLoader.bytesSniffAsActiveContent(makeTinyPNG()))

        XCTAssertTrue(HermesAttachmentLoader.bytesLookLikeKnownImage(makeTinyPNG()))
        XCTAssertTrue(HermesAttachmentLoader.bytesLookLikeKnownImage(Data([0xFF, 0xD8, 0xFF, 0xE0])))
        XCTAssertFalse(HermesAttachmentLoader.bytesLookLikeKnownImage(Data("not an image at all".utf8)))
    }

    /// An image-typed claim whose magic bytes match no known image format is a
    /// type mismatch and is refused.
    func test_enforceSafe_rejectsImageMimeWithNonImageBytes() {
        XCTAssertThrowsError(
            try HermesAttachmentLoader.enforceSafeAttachmentForAgentImport(
                name: "fake.png",
                mimeType: "image/png",
                byteSize: 24,
                headBytes: Data("this is plainly not image bytes".utf8)
            )
        ) { error in
            guard case HermesAttachmentLoader.LoaderError.unsafeAttachment = error else {
                return XCTFail("Expected unsafeAttachment, got \(error)")
            }
        }
    }

    func test_openOrCreateChatThread_usesMobileThreadIDAndRestoresMessages() throws {
        let harness = try OpenBurnBarSearchIntegrationHarness(name: "mobile-chat-continuity")
        defer { harness.cleanup() }

        let controller = ChatSessionController(
            dataStore: harness.dataStore,
            searchService: ControlledChatSessionSearchProvider(responses: [:])
        )
        let mobileThreadID = "mobile-codex-ios_123"

        controller.openOrCreateChatThread(id: mobileThreadID)

        XCTAssertEqual(controller.activeThreadID, mobileThreadID)
        XCTAssertTrue(try harness.dataStore.chatThreadExists(id: mobileThreadID))

        let userMessage = ChatMessageRecord(
            id: "u1",
            role: .user,
            content: "Keep this context.",
            timestamp: Date(timeIntervalSince1970: 1_800_000_000)
        )
        try harness.dataStore.saveChatMessage(userMessage, threadID: mobileThreadID)

        controller.startNewChatThread()
        XCTAssertNotEqual(controller.activeThreadID, mobileThreadID)

        controller.openOrCreateChatThread(id: mobileThreadID)

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
