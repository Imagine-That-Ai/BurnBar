import XCTest
@testable import OpenBurnBarCore

final class HermesAttachmentEncoderTests: XCTestCase {

    // MARK: - Helpers

    private func makeImageAttachment(
        bytes: Data = Data(repeating: 0xAB, count: 16),
        name: String = "screenshot.png",
        mime: String = "image/png"
    ) -> (HermesAttachment, Data) {
        let attachment = HermesAttachment(
            kind: .image,
            displayName: name,
            mimeType: mime,
            byteSize: bytes.count,
            workspaceRelativePath: "attachments/\(UUID().uuidString)-\(name)"
        )
        return (attachment, bytes)
    }

    // MARK: - Tests

    func testTextOnlyMessagesUseLegacyShape() {
        let messages = [
            HermesAttachmentEncoder.Message(role: .user, text: "hello"),
            HermesAttachmentEncoder.Message(role: .assistant, text: "hi there")
        ]
        let encoded = HermesAttachmentEncoder.encodeMessages(
            systemPrompt: "be terse",
            messages: messages
        )
        XCTAssertEqual(encoded.count, 3)
        XCTAssertEqual(encoded[0]["role"] as? String, "system")
        XCTAssertEqual(encoded[0]["content"] as? String, "be terse")
        XCTAssertEqual(encoded[1]["content"] as? String, "hello")
        XCTAssertEqual(encoded[2]["content"] as? String, "hi there")
    }

    func testImageAttachmentEncodesAsImageURL() {
        let (attachment, bytes) = makeImageAttachment()
        let userMessage = HermesAttachmentEncoder.Message(
            role: .user,
            text: "Describe this",
            attachments: [attachment],
            attachmentBytes: [attachment.id: bytes]
        )
        let encoded = HermesAttachmentEncoder.encodeMessages(
            systemPrompt: "",
            messages: [userMessage],
            capabilities: HermesBackendCapabilities(vision: true)
        )
        XCTAssertEqual(encoded.count, 1)
        let parts = encoded[0]["content"] as? [[String: Any]]
        XCTAssertNotNil(parts)
        XCTAssertEqual(parts?.count, 2)
        XCTAssertEqual(parts?[0]["type"] as? String, "text")
        XCTAssertEqual(parts?[0]["text"] as? String, "Describe this")
        XCTAssertEqual(parts?[1]["type"] as? String, "image_url")
        let urlPayload = parts?[1]["image_url"] as? [String: Any]
        XCTAssertTrue((urlPayload?["url"] as? String)?.hasPrefix("data:image/png;base64,") ?? false)
    }

    func testImageWithoutVisionFallsBackToWorkspaceReference() {
        let (attachment, bytes) = makeImageAttachment()
        let userMessage = HermesAttachmentEncoder.Message(
            role: .user,
            text: "what's this?",
            attachments: [attachment],
            attachmentBytes: [attachment.id: bytes]
        )
        let encoded = HermesAttachmentEncoder.encodeMessages(
            systemPrompt: "",
            messages: [userMessage],
            capabilities: HermesBackendCapabilities(vision: false)
        )
        let parts = encoded[0]["content"] as? [[String: Any]]
        XCTAssertEqual(parts?.count, 1)
        let text = parts?[0]["text"] as? String ?? ""
        XCTAssertTrue(text.contains("--- attached file ---"))
        XCTAssertTrue(text.contains("type: image"))
    }

    func testTextDocumentInlinesContents() {
        let body = "fn main() { println!(\"hi\") }".data(using: .utf8)!
        let attachment = HermesAttachment(
            kind: .textDocument,
            displayName: "main.rs",
            mimeType: "text/plain",
            byteSize: body.count,
            workspaceRelativePath: "attachments/x-main.rs",
            extractedTextPreview: String(data: body, encoding: .utf8)
        )
        let userMessage = HermesAttachmentEncoder.Message(
            role: .user,
            text: "Review this",
            attachments: [attachment],
            attachmentBytes: [attachment.id: body]
        )
        let encoded = HermesAttachmentEncoder.encodeMessages(
            systemPrompt: "",
            messages: [userMessage]
        )
        let parts = encoded[0]["content"] as? [[String: Any]]
        let text = parts?[0]["text"] as? String ?? ""
        XCTAssertTrue(text.contains("--- attachment: main.rs ---"))
        XCTAssertTrue(text.contains("println!"))
    }

    func testAudioRequiresAudioCapability() {
        let bytes = Data(repeating: 0x01, count: 64)
        let attachment = HermesAttachment(
            kind: .audio,
            displayName: "voice-note.m4a",
            mimeType: "audio/mp4",
            byteSize: bytes.count,
            workspaceRelativePath: "attachments/x-voice.m4a"
        )
        let userMessage = HermesAttachmentEncoder.Message(
            role: .user,
            text: "transcribe",
            attachments: [attachment],
            attachmentBytes: [attachment.id: bytes]
        )
        let withAudio = HermesAttachmentEncoder.encodeMessages(
            systemPrompt: "",
            messages: [userMessage],
            capabilities: HermesBackendCapabilities(vision: true, audio: true)
        )
        let withoutAudio = HermesAttachmentEncoder.encodeMessages(
            systemPrompt: "",
            messages: [userMessage],
            capabilities: HermesBackendCapabilities(vision: true, audio: false)
        )
        let withParts = withAudio[0]["content"] as? [[String: Any]]
        XCTAssertEqual(withParts?.last?["type"] as? String, "input_audio")
        let withoutParts = withoutAudio[0]["content"] as? [[String: Any]]
        let fallback = withoutParts?[0]["text"] as? String ?? ""
        XCTAssertTrue(fallback.contains("voice-note.m4a"))
    }

    func testGenericAttachmentPostsAsWorkspaceReference() {
        let attachment = HermesAttachment(
            kind: .generic,
            displayName: "session.zip",
            mimeType: "application/zip",
            byteSize: 12_000_000,
            workspaceRelativePath: "attachments/x-session.zip"
        )
        let userMessage = HermesAttachmentEncoder.Message(
            role: .user,
            text: "look at this archive",
            attachments: [attachment]
        )
        let encoded = HermesAttachmentEncoder.encodeMessages(
            systemPrompt: "",
            messages: [userMessage],
            workspaceAbsolutePath: { _ in "/Users/me/Library/Group/HermesChats/default/attachments/x-session.zip" }
        )
        let parts = encoded[0]["content"] as? [[String: Any]]
        let text = parts?[0]["text"] as? String ?? ""
        XCTAssertTrue(text.contains("--- attached file ---"))
        XCTAssertTrue(text.contains("name: session.zip"))
        XCTAssertTrue(text.contains("/Users/me/Library/Group/HermesChats/default/attachments/x-session.zip"))
    }

    func testMissingTextWithImageStillEmitsTextPart() {
        let (attachment, bytes) = makeImageAttachment()
        let userMessage = HermesAttachmentEncoder.Message(
            role: .user,
            text: "",
            attachments: [attachment],
            attachmentBytes: [attachment.id: bytes]
        )
        let encoded = HermesAttachmentEncoder.encodeMessages(
            systemPrompt: "",
            messages: [userMessage]
        )
        let parts = encoded[0]["content"] as? [[String: Any]]
        XCTAssertEqual(parts?.first?["text"] as? String, "(see attachments)")
    }

    func testKindInferenceMatchesExpectations() {
        XCTAssertEqual(HermesAttachmentKind.infer(mimeType: "image/png", fileName: "x.png"), .image)
        XCTAssertEqual(HermesAttachmentKind.infer(mimeType: "application/pdf", fileName: "x.pdf"), .pdf)
        XCTAssertEqual(HermesAttachmentKind.infer(mimeType: "audio/mp4", fileName: "x.m4a"), .audio)
        XCTAssertEqual(HermesAttachmentKind.infer(mimeType: "video/mp4", fileName: "x.mp4"), .video)
        XCTAssertEqual(HermesAttachmentKind.infer(mimeType: "text/plain", fileName: "main.swift"), .textDocument)
        XCTAssertEqual(HermesAttachmentKind.infer(mimeType: "application/octet-stream", fileName: "x.zip"), .generic)
    }
}
