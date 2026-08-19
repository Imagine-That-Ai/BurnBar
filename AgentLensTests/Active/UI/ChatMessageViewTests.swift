import XCTest
import SwiftUI
import ViewInspector
@testable import OpenBurnBar

// MARK: - ChatMessageView

@MainActor
final class ChatMessageViewTests: XCTestCase {

    func test_chatMeasurementWidthSanitizerRejectsNonFiniteWidths() {
        XCTAssertEqual(ChatMeasurementWidthSanitizer.frameWidth(.nan), ChatMeasurementWidthSanitizer.fallbackFrameWidth)
        XCTAssertEqual(ChatMeasurementWidthSanitizer.frameWidth(.infinity), ChatMeasurementWidthSanitizer.fallbackFrameWidth)
        XCTAssertNil(ChatMeasurementWidthSanitizer.measurementWidth(.nan))
        XCTAssertNil(ChatMeasurementWidthSanitizer.measurementWidth(.infinity))
        XCTAssertEqual(ChatMeasurementWidthSanitizer.bucketKey(.nan), "invalid")
        XCTAssertEqual(ChatMeasurementWidthSanitizer.logValue(.infinity), "invalid")
    }

    func test_chatMeasurementWidthSanitizerBoundsFrameAndMeasurementWidths() {
        XCTAssertEqual(ChatMeasurementWidthSanitizer.frameWidth(-4), ChatMeasurementWidthSanitizer.fallbackFrameWidth)
        XCTAssertEqual(ChatMeasurementWidthSanitizer.frameWidth(0), ChatMeasurementWidthSanitizer.fallbackFrameWidth)
        XCTAssertEqual(ChatMeasurementWidthSanitizer.frameWidth(512), 512)
        XCTAssertEqual(ChatMeasurementWidthSanitizer.measurementWidth(512), 512)
        XCTAssertEqual(
            ChatMeasurementWidthSanitizer.frameWidth(.greatestFiniteMagnitude),
            ChatMeasurementWidthSanitizer.maximumFrameWidth
        )
        XCTAssertEqual(
            ChatMeasurementWidthSanitizer.measurementWidth(.greatestFiniteMagnitude),
            ChatMeasurementWidthSanitizer.maximumFrameWidth
        )
    }

    func test_rendersUserMessage() throws {
        let message = ViewTestFixtures.makeUserMessage(content: "Hello world")
        let view = ChatMessageView(
            message: message,
            isStreaming: false,
            showViaBadge: false
        )
        XCTAssertNoThrow(try view.agentRowContent.inspect())
    }

    func test_rendersAssistantMessage() throws {
        let message = ViewTestFixtures.makeAssistantMessage(content: "I can help with that.")
        let view = ChatMessageView(
            message: message,
            isStreaming: false,
            showViaBadge: false
        )
        XCTAssertNoThrow(try view.agentRowContent.inspect())
    }

    func test_userMessageShowsContent() throws {
        let message = ViewTestFixtures.makeUserMessage(content: "Test content here")
        let view = ChatMessageView(
            message: message,
            isStreaming: false,
            showViaBadge: false
        )
        let sut = try view.agentRowContent.inspect()
        XCTAssertNoThrow(try sut.find(textWhere: { value, _ in value.contains("Test content here") }))
    }

    func test_assistantMessageShowsContent() throws {
        let message = ViewTestFixtures.makeAssistantMessage(content: "Assistant reply")
        let view = ChatMessageView(
            message: message,
            isStreaming: false,
            showViaBadge: false
        )
        let sut = try view.agentRowContent.inspect()
        XCTAssertNoThrow(try sut.find(textWhere: { value, _ in value.contains("Assistant reply") }))
    }

    func test_streamingAppendsCaret() throws {
        let message = ViewTestFixtures.makeAssistantMessage(content: "Streaming text")
        let view = ChatMessageView(
            message: message,
            isStreaming: true,
            showViaBadge: false
        )
        let sut = try view.agentRowContent.inspect()
        XCTAssertNoThrow(try sut.find(textWhere: { value, _ in value.contains("▍") }))
    }

    func test_nonStreamingNoCaret() throws {
        let message = ViewTestFixtures.makeAssistantMessage(content: "Done text")
        let view = ChatMessageView(
            message: message,
            isStreaming: false,
            showViaBadge: false
        )
        let sut = try view.agentRowContent.inspect()
        XCTAssertThrowsError(try sut.find(textWhere: { value, _ in value.contains("▍") }))
    }

    func test_hermesMode_showsViaBadge() throws {
        let message = ViewTestFixtures.makeHermesAssistantMessage(
            textPieces: ["Response text"],
            cliUsed: "hermes"
        )
        let view = ChatMessageView(
            message: message,
            isStreaming: false,
            showViaBadge: true,
            isHermes: true
        )
        let sut = try view.agentRowContent.inspect()
        XCTAssertNoThrow(try sut.find(textWhere: { value, _ in value.contains("via Hermes") }))
    }

    func test_nonHermesMode_showsGenericViaBadge() throws {
        let message = ViewTestFixtures.makeAssistantMessage(
            content: "Response",
            cliUsed: "claude"
        )
        let view = ChatMessageView(
            message: message,
            isStreaming: false,
            showViaBadge: true,
            isHermes: false
        )
        let sut = try view.agentRowContent.inspect()
        XCTAssertNoThrow(try sut.find(textWhere: { value, _ in value.contains("via claude") }))
    }

    func test_transcriptMessage_showsTextPieces() throws {
        let message = ViewTestFixtures.makeTranscriptMessage(
            pieces: [
                ViewTestFixtures.makeTextPiece(value: "First paragraph"),
                ViewTestFixtures.makeTextPiece(value: "Second paragraph")
            ]
        )
        let view = ChatMessageView(
            message: message,
            isStreaming: false,
            showViaBadge: false
        )
        let sut = try view.agentRowContent.inspect()
        XCTAssertNoThrow(try sut.find(textWhere: { value, _ in value.contains("First paragraph") }))
        XCTAssertNoThrow(try sut.find(textWhere: { value, _ in value.contains("Second paragraph") }))
    }

    func test_hermesToolCard_shownForHermesToolUse() throws {
        let message = ViewTestFixtures.makeHermesAssistantMessage(
            textPieces: ["Before"],
            toolPieces: [(name: "Read", detail: "file.swift")],
            cliUsed: "hermes"
        )
        let view = ChatMessageView(
            message: message,
            isStreaming: false,
            showViaBadge: false,
            isHermes: true
        )
        XCTAssertNoThrow(try view.agentRowContent.inspect())
    }

    func test_oversizedUserMessageRendersCollapsedExcerpt() throws {
        let content = String(repeating: "A", count: ChatMessageTextLimiter.defaultVisibleCharacterLimit + 37)
        let message = ViewTestFixtures.makeUserMessage(content: content)
        let view = ChatMessageView(
            message: message,
            isStreaming: false,
            showViaBadge: false
        )

        let sut = try view.agentRowContent.inspect()

        XCTAssertNoThrow(try sut.find(textWhere: { value, _ in value.count == ChatMessageTextLimiter.defaultVisibleCharacterLimit }))
        XCTAssertNoThrow(try sut.find(textWhere: { value, _ in value.contains("37 more characters") }))
    }

    func test_textLimiterReturnsFullTextWhenExpanded() {
        let content = String(repeating: "B", count: ChatMessageTextLimiter.defaultVisibleCharacterLimit + 5)

        let collapsed = ChatMessageTextLimiter.presentation(for: content, expanded: false)
        let expanded = ChatMessageTextLimiter.presentation(for: content, expanded: true)

        XCTAssertEqual(collapsed.visibleText.count, ChatMessageTextLimiter.defaultVisibleCharacterLimit)
        XCTAssertEqual(collapsed.hiddenCharacterCount, 5)
        XCTAssertEqual(expanded.visibleText, content)
        XCTAssertEqual(expanded.hiddenCharacterCount, 0)
    }

    func test_geometryWrapperRendersAtRepresentativeChatWidth() throws {
        let message = ViewTestFixtures.makeAssistantMessage(content: "Rendered reply")
        let view = ChatMessageView(
            message: message,
            isStreaming: false,
            showViaBadge: false
        )
        .frame(width: 420)

        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(width: 420, height: 160)

        let image = try XCTUnwrap(renderer.nsImage)
        XCTAssertEqual(image.size.width, 420, accuracy: 1)
        XCTAssertGreaterThan(image.size.height, 0)
    }

    func test_chatMessageViewEquatable_usesSemanticInputs_notClosureIdentity() {
        let message = ViewTestFixtures.makeAssistantMessage(content: "Stable")
        let first = ChatMessageView(
            message: message,
            isStreaming: false,
            showViaBadge: true,
            isHermes: true,
            assistantModelKey: "hermes",
            onJumpToLocal: { _ in }
        )
        let second = ChatMessageView(
            message: message,
            isStreaming: false,
            showViaBadge: true,
            isHermes: true,
            assistantModelKey: "hermes",
            onJumpToLocal: { _ in }
        )

        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, ChatMessageView(
            message: message,
            isStreaming: true,
            showViaBadge: true,
            isHermes: true,
            assistantModelKey: "hermes",
            onJumpToLocal: { _ in }
        ))
        XCTAssertNotEqual(first, ChatMessageView(
            message: message,
            isStreaming: false,
            showViaBadge: true,
            isHermes: true,
            assistantModelKey: "hermes"
        ))
    }

    func test_hermesRichBubble_andStreamingBubble_buildStreamingBodies() throws {
        let rich = HermesRichBubble(
            text: String(repeating: "é", count: 120),
            isStreaming: true
        )
        XCTAssertNoThrow(try rich.inspect())

        let streaming = StreamingBubble(
            text: "**streaming**",
            isStreaming: true,
            isError: false,
            baseSize: 14,
            lineHeight: 20
        ) {
            Text("streaming")
        }
        XCTAssertNoThrow(try streaming.inspect())
    }
}
