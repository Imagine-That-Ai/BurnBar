import FirebaseFunctions
import XCTest
@testable import OpenBurnBar

/// U5: typed `curateUsageMemoryBatch` invoker — payload building, response
/// parsing, and `FunctionsErrorCode` mapping, all exercised through the static
/// pure helpers and an injected fake. NO network, NO Firebase app.
final class UsageCurationCloudClientTests: XCTestCase {

    // MARK: - Fixtures

    private func functionsError(
        _ code: FunctionsErrorCode,
        details: [String: Any]? = nil
    ) -> NSError {
        var userInfo: [String: Any] = [NSLocalizedDescriptionKey: "server message"]
        if let details {
            userInfo[FunctionsErrorDetailsKey] = details
        }
        return NSError(domain: FunctionsErrorDomain, code: code.rawValue, userInfo: userInfo)
    }

    private func wellFormedResponseDict() -> [String: Any] {
        [
            "results": [
                [
                    "text": "Prefers dark roast coffee",
                    "kind": "preference",
                    "confidence": 0.9,
                    "keywords": ["coffee", "dark roast"],
                    "tags": ["food"],
                    "context": "Recurring Safari asks about coffee beans",
                    "candidateId": "cand-1"
                ]
            ],
            "promptVersion": "usage-curation-v1",
            "usage": [
                "promptTokens": 1200,
                "outputTokens": 240,
                "cachedTokens": 300,
                "lane": "text"
            ],
            "allowance": [
                "textRemainingMonth": 98_800,
                "multimodalRemainingMonth": 50_000,
                "resetsAt": "2026-09-01T00:00:00.000Z"
            ]
        ]
    }

    // MARK: - Error mapping

    func testResourceExhaustedMapsToBudgetExhaustedWithLaneAndResetsAt() throws {
        let mapped = UsageCurationCloudClient.mapCallableError(
            functionsError(.resourceExhausted, details: [
                "lane": "multimodal",
                "resetsAt": "2026-08-16T00:00:00.000Z",
                "reason": "daily_exhausted"
            ])
        )
        let typed = try XCTUnwrap(mapped as? UsageCurationCloudError)
        XCTAssertEqual(
            typed,
            .budgetExhausted(lane: .multimodal, resetsAt: "2026-08-16T00:00:00.000Z")
        )
    }

    func testResourceExhaustedWithoutDetailsStillMapsToBudgetExhausted() throws {
        let mapped = UsageCurationCloudClient.mapCallableError(functionsError(.resourceExhausted))
        let typed = try XCTUnwrap(mapped as? UsageCurationCloudError)
        XCTAssertEqual(typed, .budgetExhausted(lane: nil, resetsAt: nil))
    }

    func testResourceExhaustedWithUnknownLaneDropsTheLane() throws {
        let mapped = UsageCurationCloudClient.mapCallableError(
            functionsError(.resourceExhausted, details: ["lane": "video", "resetsAt": "2026-09-01T00:00:00.000Z"])
        )
        let typed = try XCTUnwrap(mapped as? UsageCurationCloudError)
        XCTAssertEqual(typed, .budgetExhausted(lane: nil, resetsAt: "2026-09-01T00:00:00.000Z"))
    }

    func testFailedPreconditionMapsToServerDisabled() throws {
        let mapped = UsageCurationCloudClient.mapCallableError(functionsError(.failedPrecondition))
        XCTAssertEqual(try XCTUnwrap(mapped as? UsageCurationCloudError), .serverDisabled)
    }

    func testAlreadyExistsMapsToReplayedRequest() throws {
        let mapped = UsageCurationCloudClient.mapCallableError(functionsError(.alreadyExists))
        XCTAssertEqual(try XCTUnwrap(mapped as? UsageCurationCloudError), .replayedRequest)
    }

    func testOtherFunctionsCodesPassThroughUnchanged() {
        for code: FunctionsErrorCode in [.unauthenticated, .permissionDenied, .invalidArgument, .internal, .unavailable] {
            let original = functionsError(code)
            let mapped = UsageCurationCloudClient.mapCallableError(original) as NSError
            XCTAssertEqual(mapped.domain, FunctionsErrorDomain, "code=\(code.rawValue)")
            XCTAssertEqual(mapped.code, code.rawValue, "code=\(code.rawValue)")
            XCTAssertNil(mapped as? UsageCurationCloudError, "code=\(code.rawValue)")
        }
    }

    func testNonFunctionsErrorsPassThroughUnchanged() {
        let transport = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        let mapped = UsageCurationCloudClient.mapCallableError(transport) as NSError
        XCTAssertEqual(mapped.domain, NSURLErrorDomain)
        XCTAssertEqual(mapped.code, NSURLErrorTimedOut)
    }

    // MARK: - Payload building

    func testPayloadCarriesLaneRequestIdAndCandidates() throws {
        let payload = UsageCurationCloudClient.payload(
            lane: .multimodal,
            candidates: [
                UsageCurationCloudCandidate(
                    id: "cand-1",
                    sourceKind: "safari_ask",
                    text: "candidate text",
                    imageRefs: ["data:image/png;base64,AAAA"]
                ),
                UsageCurationCloudCandidate(id: "cand-2", sourceKind: "agent_session", text: "text only")
            ],
            requestId: "req-123"
        )

        XCTAssertEqual(payload["lane"] as? String, "multimodal")
        XCTAssertEqual(payload["requestId"] as? String, "req-123")
        let candidates = try XCTUnwrap(payload["candidates"] as? [[String: Any]])
        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates[0]["id"] as? String, "cand-1")
        XCTAssertEqual(candidates[0]["sourceKind"] as? String, "safari_ask")
        XCTAssertEqual(candidates[0]["text"] as? String, "candidate text")
        XCTAssertEqual(candidates[0]["imageRefs"] as? [String], ["data:image/png;base64,AAAA"])
        XCTAssertNil(candidates[1]["imageRefs"], "Absent imageRefs must be OMITTED, not sent as an empty array.")
    }

    func testPayloadOmitsEmptyImageRefsArray() throws {
        let payload = UsageCurationCloudClient.payload(
            lane: .text,
            candidates: [UsageCurationCloudCandidate(id: "c", sourceKind: "safari_ask", text: "t", imageRefs: [])],
            requestId: "req"
        )
        let candidates = try XCTUnwrap(payload["candidates"] as? [[String: Any]])
        XCTAssertNil(candidates[0]["imageRefs"], "The server rejects imageRefs outside the multimodal lane.")
    }

    func testNewRequestIDsAreUniqueUUIDs() {
        let first = UsageCurationCloudClient.newRequestID()
        let second = UsageCurationCloudClient.newRequestID()
        XCTAssertNotEqual(first, second)
        XCTAssertNotNil(UUID(uuidString: first))
    }

    // MARK: - Response parsing

    func testWellFormedResponseParsesFully() throws {
        let response = try UsageCurationCloudClient.response(from: wellFormedResponseDict())

        XCTAssertEqual(response.promptVersion, "usage-curation-v1")
        XCTAssertEqual(response.usage.promptTokens, 1200)
        XCTAssertEqual(response.usage.outputTokens, 240)
        XCTAssertEqual(response.usage.cachedTokens, 300)
        XCTAssertEqual(response.usage.lane, .text)
        XCTAssertEqual(response.allowance.textRemainingMonth, 98_800)
        XCTAssertEqual(response.allowance.multimodalRemainingMonth, 50_000)
        XCTAssertEqual(response.allowance.resetsAt, "2026-09-01T00:00:00.000Z")

        XCTAssertEqual(response.results.count, 1)
        let memory = try XCTUnwrap(response.results.first)
        XCTAssertEqual(memory.text, "Prefers dark roast coffee")
        XCTAssertEqual(memory.kind, "preference")
        XCTAssertEqual(memory.confidence, 0.9, accuracy: 0.0001)
        XCTAssertEqual(memory.keywords, ["coffee", "dark roast"])
        XCTAssertEqual(memory.tags, ["food"])
        XCTAssertEqual(memory.context, "Recurring Safari asks about coffee beans")
        XCTAssertEqual(memory.candidateId, "cand-1")
    }

    func testMissingCachedTokensDefaultsToZero() throws {
        var dict = wellFormedResponseDict()
        var usage = try XCTUnwrap(dict["usage"] as? [String: Any])
        usage.removeValue(forKey: "cachedTokens")
        dict["usage"] = usage
        let response = try UsageCurationCloudClient.response(from: dict)
        XCTAssertEqual(response.usage.cachedTokens, 0)
    }

    func testMalformedResultEntriesAreDroppedNotFatal() throws {
        var dict = wellFormedResponseDict()
        var results = try XCTUnwrap(dict["results"] as? [[String: Any]])
        results.append(["kind": "fact"]) // no text/candidateId — dropped
        dict["results"] = results
        let response = try UsageCurationCloudClient.response(from: dict)
        XCTAssertEqual(response.results.count, 1)
    }

    func testMissingUsageThrowsMalformedResponse() {
        var dict = wellFormedResponseDict()
        dict.removeValue(forKey: "usage")
        XCTAssertThrowsError(try UsageCurationCloudClient.response(from: dict)) { error in
            XCTAssertEqual(error as? UsageCurationCloudError, .malformedResponse)
        }
    }

    func testUnknownLaneThrowsMalformedResponse() {
        var dict = wellFormedResponseDict()
        var usage = dict["usage"] as? [String: Any] ?? [:]
        usage["lane"] = "video"
        dict["usage"] = usage
        XCTAssertThrowsError(try UsageCurationCloudClient.response(from: dict)) { error in
            XCTAssertEqual(error as? UsageCurationCloudError, .malformedResponse)
        }
    }

    func testMissingAllowanceThrowsMalformedResponse() {
        var dict = wellFormedResponseDict()
        dict.removeValue(forKey: "allowance")
        XCTAssertThrowsError(try UsageCurationCloudClient.response(from: dict)) { error in
            XCTAssertEqual(error as? UsageCurationCloudError, .malformedResponse)
        }
    }

    // MARK: - Protocol seam (fake injection, no network)

    /// Minimal fake proving the pipeline seam: records invocations, returns a
    /// scripted result. This is the shape PR6's tests will inject.
    private final class FakeUsageCurationCloudClient: UsageCurationCloudClientProtocol, @unchecked Sendable {
        var recorded: [(lane: UsageCurationLane, candidateIds: [String], requestId: String)] = []
        var result: Result<UsageCurationBatchResponse, Error>

        init(result: Result<UsageCurationBatchResponse, Error>) {
            self.result = result
        }

        func curate(
            lane: UsageCurationLane,
            candidates: [UsageCurationCloudCandidate],
            requestId: String
        ) async throws -> UsageCurationBatchResponse {
            recorded.append((lane, candidates.map(\.id), requestId))
            return try result.get()
        }
    }

    func testFakeClientReceivesTypedRequestAndReturnsTypedResponse() async throws {
        let scripted = try UsageCurationCloudClient.response(from: wellFormedResponseDict())
        let fake = FakeUsageCurationCloudClient(result: .success(scripted))
        let client: UsageCurationCloudClientProtocol = fake

        let response = try await client.curate(
            lane: .text,
            candidates: [UsageCurationCloudCandidate(id: "cand-1", sourceKind: "safari_ask", text: "t")],
            requestId: "req-1"
        )

        XCTAssertEqual(response, scripted)
        XCTAssertEqual(fake.recorded.count, 1)
        XCTAssertEqual(fake.recorded[0].lane, .text)
        XCTAssertEqual(fake.recorded[0].candidateIds, ["cand-1"])
        XCTAssertEqual(fake.recorded[0].requestId, "req-1")
    }

    func testConvenienceOverloadMintsAFreshRequestIdPerCall() async throws {
        let scripted = try UsageCurationCloudClient.response(from: wellFormedResponseDict())
        let fake = FakeUsageCurationCloudClient(result: .success(scripted))
        let client: UsageCurationCloudClientProtocol = fake

        _ = try await client.curate(lane: .text, candidates: [])
        _ = try await client.curate(lane: .text, candidates: [])

        XCTAssertEqual(fake.recorded.count, 2)
        XCTAssertNotEqual(fake.recorded[0].requestId, fake.recorded[1].requestId)
        XCTAssertNotNil(UUID(uuidString: fake.recorded[0].requestId))
    }

    func testFakeClientPropagatesTypedErrors() async {
        let fake = FakeUsageCurationCloudClient(
            result: .failure(UsageCurationCloudError.budgetExhausted(lane: .text, resetsAt: "2026-09-01T00:00:00.000Z"))
        )
        let client: UsageCurationCloudClientProtocol = fake

        do {
            _ = try await client.curate(lane: .text, candidates: [], requestId: "req")
            XCTFail("Expected budgetExhausted")
        } catch {
            XCTAssertEqual(
                error as? UsageCurationCloudError,
                .budgetExhausted(lane: .text, resetsAt: "2026-09-01T00:00:00.000Z")
            )
        }
    }
}
