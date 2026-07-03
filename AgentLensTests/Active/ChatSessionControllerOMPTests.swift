import XCTest
@testable import OpenBurnBar

@MainActor
final class ChatSessionControllerOMPTests: XCTestCase {

    func test_chatBackendID_omp_mapsToOmpProvider() {
        XCTAssertEqual(ChatBackendID.omp.agentProvider, .omp)
    }

    func test_chatBackendID_omp_requiresCLIAssistantConsent() {
        XCTAssertTrue(ChatBackendID.omp.requiresCLIAssistantConsent)
    }

    func test_chatBackendID_allCases_includeOmp() {
        XCTAssertTrue(ChatBackendID.allCases.contains(.omp))
    }
}