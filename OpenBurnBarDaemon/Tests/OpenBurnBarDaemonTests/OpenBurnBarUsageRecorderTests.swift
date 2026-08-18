import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import Foundation
import XCTest

final class BurnBarUsageRecorderTests: XCTestCase {
    func testUsageRecorderIsIdempotentAcrossReinitialization() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-usage-recorder-\(UUID().uuidString)", isDirectory: true)
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
            .appendingPathComponent("openburnbar-usage-recorder-distinct-\(UUID().uuidString)", isDirectory: true)
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

    func testUsageRecorderReadsHermesPythonShapedLedgerLine() async throws {
        // Mirrors the JSON shape `tools/openburnbar-mcp/burnbar_usage_ledger.py`
        // emits — Apple reference-date seconds for `recordedAt`, lower-case
        // `providerID`, plus the new `reasoningTokens` / `sessionID` /
        // `projectName` / `confidence` fields. If this round-trip ever fails,
        // the Hermes plugin is silently dropping spend on import.
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-usage-recorder-python-shape-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let ledgerURL = rootURL.appendingPathComponent("usage-events.jsonl", isDirectory: false)

        // 2025-06-01T12:00:00Z = unix 1_748_779_200 = Apple reference 770_472_000.
        let referenceSeconds: Double = 770_472_000
        let pythonShapedLine = #"""
        {"idempotencyKey":"hermes-pyshape-1","event":{"providerID":"hermes","modelID":"minimax-m2.7-highspeed","inputTokens":42,"outputTokens":17,"cacheCreationTokens":0,\#
        "cacheReadTokens":0,"reasoningTokens":4,"cost":0.012,"recordedAt":770472000,"sessionID":"hermes-mobile","projectName":"Hermes (proxy)","confidence":"exact"}}
        """#
        try (pythonShapedLine + "\n").write(to: ledgerURL, atomically: true, encoding: .utf8)

        let recorder = BurnBarUsageRecorder(
            fileURL: ledgerURL,
            logger: BurnBarDaemonLogger(category: "usage-recorder-tests")
        )

        let records = try await recorder.records()
        XCTAssertEqual(records.count, 1)
        let event = try XCTUnwrap(records.first?.event)
        XCTAssertEqual(event.providerID, "hermes")
        XCTAssertEqual(event.modelID, "minimax-m2.7-highspeed")
        XCTAssertEqual(event.inputTokens, 42)
        XCTAssertEqual(event.outputTokens, 17)
        XCTAssertEqual(event.reasoningTokens, 4)
        XCTAssertEqual(event.sessionID, "hermes-mobile")
        XCTAssertEqual(event.projectName, "Hermes (proxy)")
        XCTAssertEqual(event.confidence, .exact)
        XCTAssertEqual(event.recordedAt.timeIntervalSinceReferenceDate, referenceSeconds, accuracy: 0.5)

        // And confirm it round-trips back through the recorder's `recentUsage`
        // path the daemon's `usageRecent` RPC delegates to.
        let recent = try await recorder.recentUsage(limit: 5)
        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent.first?.providerID, "hermes")
    }

    func testUsageRecorderReadsLegacyEventsWithoutCacheCreationTokens() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-usage-recorder-legacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let ledgerURL = rootURL.appendingPathComponent("usage-events.jsonl", isDirectory: false)

        let event = BurnBarUsageEvent(
            runID: BurnBarRunID(rawValue: "run-legacy"),
            providerID: "minimax",
            modelID: "minimax-m2.7-highspeed",
            inputTokens: 120,
            outputTokens: 40,
            cacheCreationTokens: 25,
            cacheReadTokens: 10,
            cost: 0.42,
            recordedAt: Date(timeIntervalSince1970: 1_710_000_000)
        )
        let eventData = try JSONEncoder().encode(event)
        guard var eventObject = try JSONSerialization.jsonObject(with: eventData) as? [String: Any] else {
            XCTFail("Could not build legacy event payload")
            return
        }
        eventObject.removeValue(forKey: "cacheCreationTokens")
        let payload: [String: Any] = [
            "idempotencyKey": "usage-legacy",
            "event": eventObject
        ]
        let legacyLine = String(
            decoding: try JSONSerialization.data(withJSONObject: payload, options: []),
            as: UTF8.self
        )
        try legacyLine.write(to: ledgerURL, atomically: true, encoding: .utf8)

        let recorder = BurnBarUsageRecorder(
            fileURL: ledgerURL,
            logger: BurnBarDaemonLogger(category: "usage-recorder-tests")
        )

        let records = try await recorder.records()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.event.cacheCreationTokens, 0)
        XCTAssertEqual(records.first?.event.cacheReadTokens, 10)
    }

    func testUsageRecorderAcceptsZeroUsageAtCurrentTimestamp() async throws {
        let fixture = try makeRecorderFixture()
        let event = makeEvent(recordedAt: Date())

        let result = try await fixture.recorder.record(event, idempotencyKey: "zero-usage")
        let records = try await fixture.recorder.records()

        XCTAssertTrue(result.inserted)
        XCTAssertEqual(records.count, 1)
    }

    func testUsageRecorderRejectsEveryNegativeTokenFieldWithoutMutatingState() async throws {
        let invalidEvents = [
            makeEvent(inputTokens: -1),
            makeEvent(outputTokens: -1),
            makeEvent(cacheCreationTokens: -1),
            makeEvent(cacheReadTokens: -1),
            makeEvent(reasoningTokens: -1)
        ]

        for (index, event) in invalidEvents.enumerated() {
            let fixture = try makeRecorderFixture()
            await assertValidationFailure(
                fixture.recorder,
                event: event,
                idempotencyKey: "negative-token-\(index)"
            )
            let records = try await fixture.recorder.records()
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.ledgerURL.path))
            XCTAssertEqual(records, [])
        }
    }

    func testUsageRecorderRejectsInvalidCostValuesWithoutMutatingState() async throws {
        for (index, cost) in [-0.01, .infinity, -.infinity, .nan].enumerated() {
            let fixture = try makeRecorderFixture()
            await assertValidationFailure(
                fixture.recorder,
                event: makeEvent(cost: cost),
                idempotencyKey: "invalid-cost-\(index)"
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.ledgerURL.path))
        }
    }

    func testUsageRecorderRejectsInvalidIdentifiersWithoutMutatingDedupeState() async throws {
        let tooLong = String(repeating: "a", count: BurnBarUsageRecorder.maximumIdentifierBytes + 1)
        let cases: [(String, BurnBarUsageEvent)] = [
            ("valid-key", makeEvent(providerID: "")),
            ("valid-key", makeEvent(modelID: " model")),
            ("valid-key", makeEvent(runID: BurnBarRunID(rawValue: "run\ninvalid"))),
            ("valid-key", makeEvent(sessionID: tooLong)),
            ("valid-key", makeEvent(parentRequestID: "\t")),
            ("valid-key", makeEvent(projectName: " invalid-project")),
            ("valid-key", makeEvent(projectName: tooLong))
        ]

        for (key, event) in cases {
            let fixture = try makeRecorderFixture()
            await assertValidationFailure(fixture.recorder, event: event, idempotencyKey: key)
            let records = try await fixture.recorder.records()
            XCTAssertEqual(records, [])
        }

        for key in ["", " key", "key\ninvalid", tooLong] {
            let fixture = try makeRecorderFixture()
            await assertValidationFailure(fixture.recorder, event: makeEvent(), idempotencyKey: key)
            let records = try await fixture.recorder.records()
            XCTAssertEqual(records, [])
        }
    }

    func testUsageRecorderRejectsOutOfRangeAndNonFiniteTimestamps() async throws {
        let current = Date(timeIntervalSince1970: 1_800_000_000)
        let invalidDates = [
            BurnBarUsageRecorder.earliestRecordedAt.addingTimeInterval(-1),
            current.addingTimeInterval(BurnBarUsageRecorder.maximumFutureSkew + 1),
            Date(timeIntervalSince1970: .infinity)
        ]

        for (index, date) in invalidDates.enumerated() {
            let fixture = try makeRecorderFixture(now: current)
            await assertValidationFailure(
                fixture.recorder,
                event: makeEvent(recordedAt: date),
                idempotencyKey: "invalid-date-\(index)"
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.ledgerURL.path))
        }
    }

    func testUsageRecorderAcceptsInclusiveTimestampBoundsAndRejectsTokenOverflow() async throws {
        let current = Date(timeIntervalSince1970: 1_800_000_000)
        let fixture = try makeRecorderFixture(now: current)
        _ = try await fixture.recorder.record(
            makeEvent(recordedAt: BurnBarUsageRecorder.earliestRecordedAt),
            idempotencyKey: "earliest"
        )
        _ = try await fixture.recorder.record(
            makeEvent(recordedAt: current.addingTimeInterval(BurnBarUsageRecorder.maximumFutureSkew)),
            idempotencyKey: "latest"
        )
        _ = try await fixture.recorder.record(
            makeEvent(inputTokens: .max, recordedAt: current),
            idempotencyKey: String(repeating: "k", count: BurnBarUsageRecorder.maximumIdentifierBytes)
        )
        let recordsBeforeOverflow = try await fixture.recorder.records()
        XCTAssertEqual(recordsBeforeOverflow.count, 3)

        await assertValidationFailure(
            fixture.recorder,
            event: makeEvent(inputTokens: .max, outputTokens: 1),
            idempotencyKey: "overflow"
        )
        let recordsAfterOverflow = try await fixture.recorder.records()
        XCTAssertEqual(recordsAfterOverflow.count, 3)
    }

    func testRejectedInputDoesNotConsumeItsIdempotencyKey() async throws {
        let fixture = try makeRecorderFixture()
        await assertValidationFailure(
            fixture.recorder,
            event: makeEvent(inputTokens: -1),
            idempotencyKey: "reusable-key"
        )

        let validResult = try await fixture.recorder.record(
            makeEvent(inputTokens: 1),
            idempotencyKey: "reusable-key"
        )
        let records = try await fixture.recorder.records()

        XCTAssertTrue(validResult.inserted)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.event.inputTokens, 1)
    }

    func testDuplicateKeyRejectsConflictingEventWithoutMutatingLedger() async throws {
        let fixture = try makeRecorderFixture()
        let original = makeEvent(modelID: "canonical-model", inputTokens: 10)
        let conflictingRetry = makeEvent(modelID: "different-model", inputTokens: 999)

        _ = try await fixture.recorder.record(original, idempotencyKey: "same-key")
        do {
            _ = try await fixture.recorder.record(conflictingRetry, idempotencyKey: "same-key")
            XCTFail("Expected conflicting in-memory idempotency key to fail closed")
        } catch let error as BurnBarUsageLedgerError {
            XCTAssertEqual(error, .conflictingIdempotencyKey("same-key"))
        }

        let records = try await fixture.recorder.records()
        XCTAssertEqual(records.map(\.event), [original])
    }

    func testProjectionRecountsExactUTCDayProviderAndModelBuckets() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fixture = try makeRecorderFixture(now: now)
        let first = makeEvent(
            providerID: "codex",
            modelID: "gpt-5",
            inputTokens: 10,
            outputTokens: 2,
            cacheCreationTokens: 3,
            cacheReadTokens: 4,
            reasoningTokens: 5,
            cost: 0.25,
            recordedAt: Date(timeIntervalSince1970: 1_753_055_940),
            confidence: .exact
        )
        let second = makeEvent(
            providerID: "codex",
            modelID: "gpt-5",
            inputTokens: 7,
            outputTokens: 1,
            cost: 0.10,
            recordedAt: Date(timeIntervalSince1970: 1_753_056_060),
            confidence: .highConfidenceEstimate
        )
        let third = makeEvent(
            providerID: "claude_code",
            modelID: "claude-sonnet-4",
            inputTokens: 8,
            outputTokens: 6,
            cost: 0.50,
            recordedAt: Date(timeIntervalSince1970: 1_753_056_120),
            confidence: .unknown
        )

        _ = try await fixture.recorder.record(first, idempotencyKey: "first")
        _ = try await fixture.recorder.record(second, idempotencyKey: "second")
        _ = try await fixture.recorder.record(third, idempotencyKey: "third")
        let projection = try await fixture.recorder.projection()

        XCTAssertEqual(projection.schemaVersion, 1)
        XCTAssertEqual(projection.generation, 1)
        XCTAssertEqual(projection.ledgerSHA256.count, 64)
        XCTAssertEqual(projection.totals.eventCount, 3)
        XCTAssertEqual(projection.totals.inputTokens, 25)
        XCTAssertEqual(projection.totals.outputTokens, 9)
        XCTAssertEqual(projection.totals.cacheCreationTokens, 3)
        XCTAssertEqual(projection.totals.cacheReadTokens, 4)
        XCTAssertEqual(projection.totals.reasoningTokens, 5)
        XCTAssertEqual(projection.totals.totalTokens, 46)
        XCTAssertEqual(projection.totals.cost, 0.85, accuracy: 0.000_001)
        XCTAssertEqual(
            projection.buckets.map { "\($0.dayUTC)|\($0.providerID)|\($0.modelID)" },
            [
                "2025-07-20|codex|gpt-5",
                "2025-07-21|claude_code|claude-sonnet-4",
                "2025-07-21|codex|gpt-5"
            ]
        )
        XCTAssertEqual(projection.buckets[0].exactEventCount, 1)
        XCTAssertEqual(projection.buckets[1].unknownEventCount, 1)
        XCTAssertEqual(projection.buckets[2].estimatedEventCount, 1)
    }

    func testProjectionSurvivesRestartAndRecountRepairsTampering() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-usage-projection-restart-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: rootURL) }
        let ledgerURL = rootURL.appendingPathComponent("usage-events.jsonl")
        let projectionURL = rootURL.appendingPathComponent("usage-projection.json")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let firstRecorder = BurnBarUsageRecorder(
            fileURL: ledgerURL,
            projectionFileURL: projectionURL,
            logger: BurnBarDaemonLogger(category: "usage-projection-tests"),
            now: { now }
        )
        _ = try await firstRecorder.record(
            makeEvent(inputTokens: 4, recordedAt: Date(timeIntervalSince1970: 1_750_000_000)),
            idempotencyKey: "one"
        )
        let beforeRestart = try await firstRecorder.projection()
        XCTAssertEqual(beforeRestart.generation, 1)

        let secondRecorder = BurnBarUsageRecorder(
            fileURL: ledgerURL,
            projectionFileURL: projectionURL,
            logger: BurnBarDaemonLogger(category: "usage-projection-tests"),
            now: { now }
        )
        let afterRestart = try await secondRecorder.projection()
        XCTAssertEqual(afterRestart, beforeRestart)

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: projectionURL)) as? [String: Any]
        )
        var totals = try XCTUnwrap(object["totals"] as? [String: Any])
        totals["inputTokens"] = 123_456
        object["totals"] = totals
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: projectionURL, options: .atomic)

        let thirdRecorder = BurnBarUsageRecorder(
            fileURL: ledgerURL,
            projectionFileURL: projectionURL,
            logger: BurnBarDaemonLogger(category: "usage-projection-tests"),
            now: { now }
        )
        let repaired = try await thirdRecorder.projection()
        XCTAssertEqual(repaired.generation, 2)
        XCTAssertEqual(repaired.totals.inputTokens, 4)
        XCTAssertEqual(repaired.ledgerSHA256, beforeRestart.ledgerSHA256)

        let recounted = try await thirdRecorder.recountProjection()
        XCTAssertEqual(recounted.generation, 3)
        XCTAssertEqual(recounted.totals, repaired.totals)
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: projectionURL.path)[.posixPermissions] as? Int,
            0o600
        )
    }

    func testLedgerDeduplicatesIdenticalRowsAndRejectsConflictingRows() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fixture = try makeRecorderFixture(now: now)
        let original = BurnBarUsageRecord(
            idempotencyKey: "duplicate",
            event: makeEvent(inputTokens: 3, recordedAt: Date(timeIntervalSince1970: 1_750_000_000))
        )
        let encoder = JSONEncoder()
        let line = try encoder.encode(original) + Data([0x0A])
        try (line + line).write(to: fixture.ledgerURL)
        let duplicateRecords = try await fixture.recorder.records()
        XCTAssertEqual(duplicateRecords, [original])

        let conflictingFixture = try makeRecorderFixture(now: now)
        let conflict = BurnBarUsageRecord(
            idempotencyKey: "duplicate",
            event: makeEvent(inputTokens: 4, recordedAt: Date(timeIntervalSince1970: 1_750_000_000))
        )
        try (line + encoder.encode(conflict) + Data([0x0A])).write(to: conflictingFixture.ledgerURL)
        do {
            _ = try await conflictingFixture.recorder.projection()
            XCTFail("Expected conflicting idempotency rows to fail closed")
        } catch let error as BurnBarUsageLedgerError {
            XCTAssertEqual(error, .conflictingIdempotencyKey("duplicate"))
        }
    }

    func testLargeLedgerQueriesStayBoundedAndProjectionSurvivesRestart() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-usage-large-ledger-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: rootURL) }

        let ledgerURL = rootURL.appendingPathComponent("usage-events.jsonl")
        let projectionURL = rootURL.appendingPathComponent("usage-projection.json")
        let recordCount = 12_050
        let baseTimestamp: TimeInterval = 1_750_000_000
        let now = Date(timeIntervalSince1970: baseTimestamp + Double(recordCount) + 60)
        let encoder = JSONEncoder()
        var ledgerData = Data()
        ledgerData.reserveCapacity(recordCount * 320)
        var expectedInputTokens = 0
        var expectedOutputTokens = 0
        var expectedCacheCreationTokens = 0
        var expectedCacheReadTokens = 0
        var expectedReasoningTokens = 0
        var expectedCost = 0.0
        var expectedFilteredCost = 0.0

        for index in 0..<recordCount {
            let providerID = index.isMultiple(of: 2) ? "codex" : "claude_code"
            let inputTokens = (index % 17) + 1
            let outputTokens = index % 7
            let cacheCreationTokens = index % 3
            let cacheReadTokens = index % 5
            let reasoningTokens = index % 2
            let cost = Double((index % 11) + 1) / 1_000
            let event = makeEvent(
                providerID: providerID,
                modelID: providerID == "codex" ? "gpt-5" : "claude-sonnet-4",
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheCreationTokens: cacheCreationTokens,
                cacheReadTokens: cacheReadTokens,
                reasoningTokens: reasoningTokens,
                cost: cost,
                recordedAt: Date(timeIntervalSince1970: baseTimestamp + Double(index))
            )
            ledgerData.append(
                try encoder.encode(
                    BurnBarUsageRecord(
                        idempotencyKey: "large-ledger-\(index)",
                        event: event
                    )
                )
            )
            ledgerData.append(0x0A)

            expectedInputTokens += inputTokens
            expectedOutputTokens += outputTokens
            expectedCacheCreationTokens += cacheCreationTokens
            expectedCacheReadTokens += cacheReadTokens
            expectedReasoningTokens += reasoningTokens
            expectedCost += cost
            if index >= 5_000, providerID == "codex" {
                expectedFilteredCost += cost
            }
        }
        try ledgerData.write(to: ledgerURL, options: .atomic)

        let recorder = BurnBarUsageRecorder(
            fileURL: ledgerURL,
            projectionFileURL: projectionURL,
            logger: BurnBarDaemonLogger(category: "usage-large-ledger-tests"),
            now: { now }
        )

        let signature = try await recorder.signature()
        XCTAssertEqual(signature.recordCount, recordCount)
        XCTAssertEqual(
            signature.latestRecordedAt,
            Date(timeIntervalSince1970: baseTimestamp + Double(recordCount - 1))
        )
        let retainedRecordCount = await recorder.retainedRecordCount
        XCTAssertEqual(retainedRecordCount, 0)

        let recent = try await recorder.recentUsage(limit: 20_000)
        XCTAssertEqual(recent.count, BurnBarUsageRecorder.maximumReturnedRecords)
        XCTAssertEqual(recent.first?.recordedAt, signature.latestRecordedAt)
        XCTAssertEqual(
            recent.last?.recordedAt,
            Date(
                timeIntervalSince1970: baseTimestamp
                    + Double(recordCount - BurnBarUsageRecorder.maximumReturnedRecords)
            )
        )
        XCTAssertTrue(
            zip(recent, recent.dropFirst()).allSatisfy {
                $0.0.recordedAt >= $0.1.recordedAt
            }
        )

        let interval = DateInterval(
            start: Date(timeIntervalSince1970: baseTimestamp + 1_000),
            end: Date(timeIntervalSince1970: baseTimestamp + 1_099.5)
        )
        let boundedWindow = try await recorder.records(in: interval, limit: 25)
        XCTAssertEqual(boundedWindow.count, 25)
        XCTAssertEqual(
            boundedWindow.map(\.event.recordedAt),
            (1_075...1_099).map {
                Date(timeIntervalSince1970: baseTimestamp + Double($0))
            }
        )
        XCTAssertTrue(
            zip(boundedWindow, boundedWindow.dropFirst()).allSatisfy {
                $0.0.event.recordedAt <= $0.1.event.recordedAt
            }
        )

        let filteredCost = try await recorder.sumCost(
            since: Date(timeIntervalSince1970: baseTimestamp + 5_000)
        ) { $0.providerID == "codex" }
        XCTAssertEqual(filteredCost, expectedFilteredCost, accuracy: 0.000_000_1)

        let projection = try await recorder.projection()
        XCTAssertEqual(projection.totals.eventCount, recordCount)
        XCTAssertEqual(projection.totals.inputTokens, expectedInputTokens)
        XCTAssertEqual(projection.totals.outputTokens, expectedOutputTokens)
        XCTAssertEqual(projection.totals.cacheCreationTokens, expectedCacheCreationTokens)
        XCTAssertEqual(projection.totals.cacheReadTokens, expectedCacheReadTokens)
        XCTAssertEqual(projection.totals.reasoningTokens, expectedReasoningTokens)
        XCTAssertEqual(
            projection.totals.totalTokens,
            expectedInputTokens
                + expectedOutputTokens
                + expectedCacheCreationTokens
                + expectedCacheReadTokens
                + expectedReasoningTokens
        )
        XCTAssertEqual(projection.totals.cost, expectedCost, accuracy: 0.000_000_1)
        XCTAssertEqual(projection.ledgerSHA256.count, 64)

        let restartedRecorder = BurnBarUsageRecorder(
            fileURL: ledgerURL,
            projectionFileURL: projectionURL,
            logger: BurnBarDaemonLogger(category: "usage-large-ledger-tests"),
            now: { now }
        )
        let restartedProjection = try await restartedRecorder.projection()
        XCTAssertEqual(restartedProjection, projection)
        XCTAssertEqual(restartedProjection.ledgerSHA256, projection.ledgerSHA256)
        let restartedRetainedRecordCount = await restartedRecorder.retainedRecordCount
        XCTAssertEqual(restartedRetainedRecordCount, 0)
    }

    func testProjectionFailsClosedOnAggregateIntegerOverflow() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fixture = try makeRecorderFixture(now: now)
        let recordedAt = Date(timeIntervalSince1970: 1_750_000_000)
        _ = try await fixture.recorder.record(
            makeEvent(inputTokens: .max, recordedAt: recordedAt),
            idempotencyKey: "max"
        )
        _ = try await fixture.recorder.record(
            makeEvent(inputTokens: 1, recordedAt: recordedAt),
            idempotencyKey: "overflow"
        )
        do {
            _ = try await fixture.recorder.projection()
            XCTFail("Expected aggregate overflow to fail closed")
        } catch let error as BurnBarUsageLedgerError {
            XCTAssertEqual(error, .aggregateOverflow("inputTokens"))
        }
    }

    private func makeRecorderFixture(
        now: Date = Date()
    ) throws -> (recorder: BurnBarUsageRecorder, ledgerURL: URL) {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-usage-validation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: rootURL)
        }
        let ledgerURL = rootURL.appendingPathComponent("usage-events.jsonl")
        return (
            BurnBarUsageRecorder(
                fileURL: ledgerURL,
                logger: BurnBarDaemonLogger(category: "usage-validation-tests"),
                now: { now }
            ),
            ledgerURL
        )
    }

    private func makeEvent(
        runID: BurnBarRunID? = nil,
        providerID: String = "hermes",
        modelID: String = "minimax-m2.7-highspeed",
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheCreationTokens: Int = 0,
        cacheReadTokens: Int = 0,
        reasoningTokens: Int = 0,
        cost: Double = 0,
        recordedAt: Date = Date(),
        sessionID: String? = nil,
        projectName: String? = nil,
        parentRequestID: String? = nil,
        confidence: BurnBarUsageConfidence = .exact
    ) -> BurnBarUsageEvent {
        BurnBarUsageEvent(
            runID: runID,
            providerID: providerID,
            modelID: modelID,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens,
            reasoningTokens: reasoningTokens,
            cost: cost,
            recordedAt: recordedAt,
            sessionID: sessionID,
            projectName: projectName,
            confidence: confidence,
            parentRequestID: parentRequestID
        )
    }

    private func assertValidationFailure(
        _ recorder: BurnBarUsageRecorder,
        event: BurnBarUsageEvent,
        idempotencyKey: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await recorder.record(event, idempotencyKey: idempotencyKey)
            XCTFail("Expected usage validation to fail", file: file, line: line)
        } catch is BurnBarUsageValidationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }
}
