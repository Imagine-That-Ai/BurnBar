import OpenBurnBarFirestoreModels
import XCTest

@testable import OpenBurnBarCore

final class TokenUsageGeneratedTests: XCTestCase {
    func testGeneratedInitFailsClosedOnBlankRecordedAt() throws {
        XCTAssertNil(TokenUsage(generated: try decode(#"{"provider":"anthropic","recordedAt":""}"#)))
        XCTAssertNil(TokenUsage(generated: try decode(#"{"provider":"anthropic","recordedAt":"   "}"#)))
    }

    func testGeneratedInitFailsClosedWhenProviderCannotBeResolved() throws {
        XCTAssertNil(
            TokenUsage(generated: try decode(#"{"provider":"","recordedAt":"2026-01-01T00:00:00.000Z"}"#))
        )
        XCTAssertNil(
            TokenUsage(generated: try decode(#"{"provider":"anthropic","recordedAt":"2026-01-01T00:00:00.000Z"}"#))
        )
    }

    func testGeneratedInitMapsProviderIDAndOptionalFields() throws {
        let usage = try XCTUnwrap(
            TokenUsage(
                generated: try decode(
                    """
                    {
                      "provider": "anthropic",
                      "providerID": "openai",
                      "providerAccountID": "acct-1",
                      "providerAccountLabel": "Work",
                      "model": "opus",
                      "sessionId": "sess-1",
                      "deviceId": "dev-1",
                      "sourceDeviceId": "src-1",
                      "executionSourceID": "exec-1",
                      "executionSourceName": "CLI",
                      "executionSourceKind": "cli",
                      "executionSourceConfidence": "exact",
                      "inputTokens": 11,
                      "outputTokens": 7,
                      "cacheReadTokens": 3,
                      "cacheWriteTokens": 2,
                      "costUSD": 1.25,
                      "currency": "USD",
                      "recordedAt": " 2026-01-01T00:00:00.000Z ",
                      "eventKind": "usage",
                      "idempotencyKey": "idem-1"
                    }
                    """
                )
            )
        )
        XCTAssertEqual(usage.provider, .openAI)
        XCTAssertEqual(usage.model, "opus")
        XCTAssertEqual(usage.sessionId, "sess-1")
        XCTAssertEqual(usage.inputTokens, 11)
        XCTAssertEqual(usage.outputTokens, 7)
        XCTAssertEqual(usage.cacheReadTokens, 3)
        XCTAssertEqual(usage.cacheCreationTokens, 2)
        XCTAssertEqual(usage.costUSD, 1.25, accuracy: 0.0001)
        XCTAssertEqual(usage.deviceId, "dev-1")
        XCTAssertEqual(usage.sourceDeviceId, "src-1")
        XCTAssertEqual(usage.providerAccountID, "acct-1")
        XCTAssertEqual(usage.providerAccountLabel, "Work")
        XCTAssertEqual(usage.currency, "USD")
        XCTAssertEqual(usage.recordedAt, "2026-01-01T00:00:00.000Z")
        XCTAssertEqual(usage.eventKind, "usage")
        XCTAssertEqual(usage.idempotencyKey, "idem-1")
        XCTAssertEqual(usage.executionSourceKind, .cli)
        XCTAssertEqual(usage.executionSourceConfidence, .exact)
    }

    func testGeneratedInitFallsBackToPersistedProviderToken() throws {
        let usage = try XCTUnwrap(
            TokenUsage(generated: try decode(#"{"provider":"Claude Code","recordedAt":"2026-08-17T12:00:00.000Z"}"#))
        )
        XCTAssertEqual(usage.provider, .claudeCode)
        XCTAssertEqual(usage.sessionId, "")
        XCTAssertEqual(usage.model, "")
        XCTAssertEqual(usage.inputTokens, 0)
        XCTAssertEqual(usage.outputTokens, 0)
        XCTAssertEqual(usage.costUSD, 0, accuracy: 0.0)
        XCTAssertFalse(usage.recordedAt.isEmpty)
    }

    private func decode(_ json: String) throws -> FirestoreUsageEventDoc {
        try JSONDecoder().decode(FirestoreUsageEventDoc.self, from: Data(json.utf8))
    }
}
