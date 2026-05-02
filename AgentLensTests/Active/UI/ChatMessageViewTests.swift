import XCTest
import SwiftUI
import ViewInspector
@testable import OpenBurnBar

// MARK: - ChatMessageView

@MainActor
final class ChatMessageViewTests: XCTestCase {

    func test_rendersUserMessage() throws {
        let message = ViewTestFixtures.makeUserMessage(content: "Hello world")
        let view = ChatMessageView(
            message: message,
            isStreaming: false,
            showViaBadge: false
        )
        XCTAssertNoThrow(try view.inspect())
    }

    func test_rendersAssistantMessage() throws {
        let message = ViewTestFixtures.makeAssistantMessage(content: "I can help with that.")
        let view = ChatMessageView(
            message: message,
            isStreaming: false,
            showViaBadge: false
        )
        XCTAssertNoThrow(try view.inspect())
    }

    func test_userMessageShowsContent() throws {
        let message = ViewTestFixtures.makeUserMessage(content: "Test content here")
        let view = ChatMessageView(
            message: message,
            isStreaming: false,
            showViaBadge: false
        )
        let sut = try view.inspect()
        XCTAssertNoThrow(try sut.find(textWhere: { value, _ in value.contains("Test content here") }))
    }

    func test_assistantMessageShowsContent() throws {
        let message = ViewTestFixtures.makeAssistantMessage(content: "Assistant reply")
        let view = ChatMessageView(
            message: message,
            isStreaming: false,
            showViaBadge: false
        )
        let sut = try view.inspect()
        XCTAssertNoThrow(try sut.find(textWhere: { value, _ in value.contains("Assistant reply") }))
    }

    func test_streamingAppendsCaret() throws {
        let message = ViewTestFixtures.makeAssistantMessage(content: "Streaming text")
        let view = ChatMessageView(
            message: message,
            isStreaming: true,
            showViaBadge: false
        )
        let sut = try view.inspect()
        XCTAssertNoThrow(try sut.find(textWhere: { value, _ in value.contains("▍") }))
    }

    func test_nonStreamingNoCaret() throws {
        let message = ViewTestFixtures.makeAssistantMessage(content: "Done text")
        let view = ChatMessageView(
            message: message,
            isStreaming: false,
            showViaBadge: false
        )
        let sut = try view.inspect()
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
        let sut = try view.inspect()
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
        let sut = try view.inspect()
        XCTAssertNoThrow(try sut.find(textWhere: { value, _ in value.contains("via claude") }))
    }

    func test_transcriptMessage_showsTextPieces() throws {
        let message = ViewTestFixtures.makeTranscriptMessage(
            pieces: [
                ViewTestFixtures.makeTextPiece(value: "First paragraph"),
                ViewTestFixtures.makeTextPiece(value: "Second paragraph"),
            ]
        )
        let view = ChatMessageView(
            message: message,
            isStreaming: false,
            showViaBadge: false
        )
        let sut = try view.inspect()
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
        XCTAssertNoThrow(try view.inspect())
    }
}
