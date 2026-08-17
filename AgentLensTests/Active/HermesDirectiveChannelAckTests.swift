import XCTest

@testable import OpenBurnBar

final class HermesDirectiveChannelAckTests: XCTestCase {
    func test_validAckIsDelivered() {
        let data = Data(#"{"burnbar_delivery":{"directive_id":"d1","status":"delivered"}}"#.utf8)
        XCTAssertEqual(
            HermesDirectiveChannel.validateAck(data: data, directiveID: "d1"),
            .delivered
        )
    }

    func test_invalidJSONFailsClosed() {
        let outcome = HermesDirectiveChannel.validateAck(data: Data("not-json".utf8), directiveID: "d1")
        guard case .failed(let reason) = outcome else {
            XCTFail("expected failed, got \(outcome)")
            return
        }
        XCTAssertTrue(reason.contains("malformedAck"))
    }

    func test_mismatchedDirectiveIdFailsClosed() {
        let data = Data(#"{"burnbar_delivery":{"directive_id":"other","status":"delivered"}}"#.utf8)
        let outcome = HermesDirectiveChannel.validateAck(data: data, directiveID: "d1")
        guard case .failed(let reason) = outcome else {
            XCTFail("expected failed, got \(outcome)")
            return
        }
        XCTAssertTrue(reason.contains("mismatch"))
    }

    func test_missingDeliveryObjectFailsClosed() {
        let outcome = HermesDirectiveChannel.validateAck(data: Data(#"{"ok":true}"#.utf8), directiveID: "d1")
        guard case .failed(let reason) = outcome else {
            XCTFail("expected failed, got \(outcome)")
            return
        }
        XCTAssertTrue(reason.contains("missing burnbar_delivery"))
    }

    func test_openAIShaped200IsSubmittedNotDelivered() {
        let data = Data(#"{"id":"chatcmpl-1","choices":[{"index":0,"message":{"role":"assistant","content":"ok"}}]}"#.utf8)
        XCTAssertEqual(
            HermesDirectiveChannel.validateAck(data: data, directiveID: "d1"),
            .submitted
        )
    }
}
