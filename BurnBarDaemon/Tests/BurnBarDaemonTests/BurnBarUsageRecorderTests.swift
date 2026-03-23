import BurnBarCore
@testable import BurnBarDaemon
import Foundation
import XCTest

final class BurnBarUsageRecorderTests: XCTestCase {
    func testUsageRecorderIsIdempotentAcrossReinitialization() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("burnbar-usage-recorder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let ledgerURL = rootURL.appendingPathComponent("usage-events.jsonl", isDirectory: false)

        let event = BurnBarUsageEvent(
            runID: BurnBarRunID(rawValue: "run-1"),
            providerID: "zai",
            modelID: "glm-5",
            inputTokens: 100,
            outputTokens: 40,
            cacheReadTokens: 0,
            cost: 0.001,
            recordedAt: Date(timeIntervalSince1970: 1_710_000_000)
        )

        let firstRecorder = BurnBarUsageRecorder(
            fileURL: ledgerURL,
            logger: BurnBarDaemonLogger(category: "usage-recorder-tests")
        )
        let firstInsert = try await firstRecorder.record(event, idempotencyKey: "usage-1")
        let firstRecords = try await firstRecorder.records()
        XCTAssertTrue(firstInsert.inserted)
        XCTAssertEqual(firstRecords.count, 1)

        let secondRecorder = BurnBarUsageRecorder(
            fileURL: ledgerURL,
            logger: BurnBarDaemonLogger(category: "usage-recorder-tests")
        )
        let secondInsert = try await secondRecorder.record(event, idempotencyKey: "usage-1")
        let secondRecords = try await secondRecorder.records()
        XCTAssertFalse(secondInsert.inserted)
        XCTAssertEqual(secondRecords.count, 1)
    }

    func testUsageRecorderAppendsDistinctEvents() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("burnbar-usage-recorder-distinct-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let ledgerURL = rootURL.appendingPathComponent("usage-events.jsonl", isDirectory: false)

        let recorder = BurnBarUsageRecorder(
            fileURL: ledgerURL,
            logger: BurnBarDaemonLogger(category: "usage-recorder-tests")
        )

        let firstEvent = BurnBarUsageEvent(
            runID: BurnBarRunID(rawValue: "run-1"),
            providerID: "zai",
            modelID: "glm-5",
            inputTokens: 10,
            outputTokens: 5,
            cacheReadTokens: 0,
            cost: 0.0001,
            recordedAt: Date(timeIntervalSince1970: 1_710_000_010)
        )
        let secondEvent = BurnBarUsageEvent(
            runID: BurnBarRunID(rawValue: "run-2"),
            providerID: "minimax",
            modelID: "minimax-m2.7-highspeed",
            inputTokens: 50,
            outputTokens: 25,
            cacheReadTokens: 0,
            cost: 0.0009,
            recordedAt: Date(timeIntervalSince1970: 1_710_000_020)
        )

        let firstInsert = try await recorder.record(firstEvent, idempotencyKey: "usage-1")
        let secondInsert = try await recorder.record(secondEvent, idempotencyKey: "usage-2")
        XCTAssertTrue(firstInsert.inserted)
        XCTAssertTrue(secondInsert.inserted)

        let records = try await recorder.records()
        XCTAssertEqual(records.map(\.idempotencyKey), ["usage-1", "usage-2"])
        XCTAssertEqual(records.map(\.event.providerID), ["zai", "minimax"])
    }
}
