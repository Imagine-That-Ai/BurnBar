import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import Foundation
import XCTest

final class BurnBarUsageProjectionRPCTests: XCTestCase {
    func testProjectionAndRecountRPCsExposeTheSameDaemonOwnedLedger() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-usage-projection-rpc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: rootURL) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let recorder = BurnBarUsageRecorder(
            fileURL: rootURL.appendingPathComponent("usage-events.jsonl"),
            projectionFileURL: rootURL.appendingPathComponent("usage-projection.json"),
            logger: BurnBarDaemonLogger(category: "usage-projection-rpc-tests"),
            now: { now }
        )
        _ = try await recorder.record(
            BurnBarUsageEvent(
                providerID: "codex",
                modelID: "gpt-5",
                inputTokens: 21,
                outputTokens: 8,
                cacheCreationTokens: 5,
                cacheReadTokens: 13,
                reasoningTokens: 3,
                cost: 0.42,
                recordedAt: Date(timeIntervalSince1970: 1_750_000_000),
                sessionID: "session-1",
                projectName: "Parity fixture"
            ),
            idempotencyKey: "fixture-1"
        )
        let server = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketPath: rootURL.appendingPathComponent("daemon.sock").path,
                startsMissionControlBackgroundLoops: false
            ),
            usageRecorder: recorder
        )

        let projectionResponse: BurnBarRPCResponseEnvelope<BurnBarUsageProjectionResponse> = try await call(
            server,
            id: "projection",
            method: .usageProjection,
            params: BurnBarUsageProjectionRequest()
        )
        let projected = try XCTUnwrap(projectionResponse.result?.projection)
        XCTAssertNil(projectionResponse.error)
        XCTAssertEqual(projected.generation, 1)
        XCTAssertEqual(projected.totals.eventCount, 1)
        XCTAssertEqual(projected.totals.totalTokens, 50)

        let recountResponse: BurnBarRPCResponseEnvelope<BurnBarUsageProjectionResponse> = try await call(
            server,
            id: "recount",
            method: .usageRecount,
            params: BurnBarUsageRecountRequest()
        )
        let recounted = try XCTUnwrap(recountResponse.result?.projection)
        XCTAssertNil(recountResponse.error)
        XCTAssertEqual(recounted.generation, 2)
        XCTAssertEqual(recounted.ledgerSHA256, projected.ledgerSHA256)
        XCTAssertEqual(recounted.totals, projected.totals)
        XCTAssertEqual(recounted.buckets, projected.buckets)
    }

    private func call<Params: Codable & Sendable>(
        _ server: BurnBarDaemonServer,
        id: String,
        method: BurnBarRPCMethod,
        params: Params
    ) async throws -> BurnBarRPCResponseEnvelope<BurnBarUsageProjectionResponse> {
        let request = BurnBarRPCRequestEnvelopeWithParams(
            id: id,
            method: method,
            params: params
        )
        let data = try JSONEncoder().encode(request)
        let responseData = try await server.handleUsageRPC(
            method: method,
            decoder: JSONDecoder(),
            requestData: data
        )
        return try JSONDecoder().decode(
            BurnBarRPCResponseEnvelope<BurnBarUsageProjectionResponse>.self,
            from: responseData
        )
    }
}
