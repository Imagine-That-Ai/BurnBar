import XCTest
@testable import OpenBurnBarCore

final class HermesRelayContractTests: XCTestCase {
    func testRelayRequestRecordCodableRoundTrip() throws {
        let now = Date(timeIntervalSince1970: 1_714_200_000)
        let record = HermesRelayRequestRecord(
            id: "relay-request-1",
            connectionId: "relay-mac",
            operation: .chatCompletions,
            status: .streaming,
            method: "POST",
            path: "/v1/chat/completions",
            sessionId: "session-1",
            body: #"{"stream":true}"#,
            chunkCount: 2,
            createdAt: now,
            updatedAt: now,
            expiresAt: now.addingTimeInterval(90)
        )

        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(HermesRelayRequestRecord.self, from: data)

        XCTAssertEqual(decoded, record)
        XCTAssertEqual(decoded.operation.rawValue, "chatCompletions")
        XCTAssertEqual(decoded.status.rawValue, "streaming")
    }

    func testRelayChunkRecordCodableRoundTrip() throws {
        let record = HermesRelayChunkRecord(
            id: "00000001",
            requestId: "relay-request-1",
            sequence: 1,
            kind: .sse,
            data: #"data: {"choices":[{"delta":{"content":"hi"}}]}"#
        )

        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(HermesRelayChunkRecord.self, from: data)

        XCTAssertEqual(decoded, record)
        XCTAssertEqual(decoded.kind.rawValue, "sse")
    }
}
