import XCTest
@testable import OpenBurnBarMobile

@MainActor
final class HermesServiceTests: XCTestCase {

    func testInitialState() {
        let service = HermesService()
        XCTAssertTrue(service.messages.isEmpty)
        XCTAssertFalse(service.isStreaming)
        XCTAssertNil(service.lastError)
        XCTAssertFalse(service.isReachable)
    }

    func testSendMessageAppendsUserMessage() {
        let service = HermesService()
        service.sendMessage("Hello Hermes")
        XCTAssertEqual(service.messages.count, 1)
        XCTAssertEqual(service.messages.first?.role, .user)
        XCTAssertEqual(service.messages.first?.text, "Hello Hermes")
        XCTAssertTrue(service.isStreaming)
    }

    func testSendEmptyMessageIsNoOp() {
        let service = HermesService()
        service.sendMessage("   ")
        XCTAssertTrue(service.messages.isEmpty)
    }

    func testClearChatRemovesMessages() {
        let service = HermesService()
        service.sendMessage("Test")
        service.clearChat()
        XCTAssertTrue(service.messages.isEmpty)
        XCTAssertNil(service.lastError)
    }

    func testHermesChatMessageFields() {
        let msg = HermesChatMessage(role: .user, text: "Hi")
        XCTAssertEqual(msg.role, .user)
        XCTAssertEqual(msg.text, "Hi")
        XCTAssertFalse(msg.isStreaming)
        XCTAssertFalse(msg.isError)
    }

    func testHermesChatMessageErrorFlag() {
        let msg = HermesChatMessage(role: .assistant, text: "Oops", isError: true)
        XCTAssertTrue(msg.isError)
        XCTAssertFalse(msg.isStreaming)
    }

    func testHermesServiceErrorDescriptions() {
        XCTAssertNotNil(HermesServiceError.invalidResponse.errorDescription)
        XCTAssertNotNil(HermesServiceError.httpStatus(code: 500).errorDescription)
        XCTAssertNotNil(HermesServiceError.decodingFailed.errorDescription)
    }
}
