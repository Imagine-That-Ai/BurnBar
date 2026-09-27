import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import Foundation
import XCTest

/// The daemon router already knows which credential slot served a request.
/// These pin that identity surviving the ledger round-trip, so the Mac import
/// can attribute gateway burn to a specific account instead of the provider
/// total.
final class BurnBarUsageEventAccountAttributionTests: XCTestCase {
    func testCredentialSlotSurvivesLedgerRoundTrip() async throws {
        let ledgerURL = try makeLedgerURL()
        let event = makeEvent(
            providerAccountID: "openai-seat-two",
            providerAccountLabel: "Work"
        )

        let recorder = BurnBarUsageRecorder(
            fileURL: ledgerURL,
            logger: BurnBarDaemonLogger(category: "usage-account-tests")
        )
        _ = try await recorder.record(event, idempotencyKey: "usage-account-1")

        // A fresh recorder decodes from disk, proving the fields are persisted
        // rather than only held in memory.
        let reopened = BurnBarUsageRecorder(
            fileURL: ledgerURL,
            logger: BurnBarDaemonLogger(category: "usage-account-tests")
        )
        let records = try await reopened.records()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.event.providerAccountID, "openai-seat-two")
        XCTAssertEqual(records.first?.event.providerAccountLabel, "Work")
    }

    /// Ledger lines written before this feature have no account keys; they must
    /// still decode, with the account reported as absent.
    func testLegacyLedgerLineWithoutAccountKeysStillDecodes() throws {
        let legacyJSON = """
        {"providerID":"zai","modelID":"glm-5","inputTokens":100,"outputTokens":40,\
        "cacheCreationTokens":0,"cacheReadTokens":0,"reasoningTokens":0,"cost":0.001,\
        "recordedAt":728884800,"confidence":"exact"}
        """
        let decoder = JSONDecoder()
        let event = try decoder.decode(BurnBarUsageEvent.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(event.providerAccountID)
        XCTAssertNil(event.providerAccountLabel)
        XCTAssertEqual(event.providerID, "zai")
    }

    func testUnattributedEventOmitsAccountKeys() throws {
        let event = makeEvent(providerAccountID: nil, providerAccountLabel: nil)
        let encoded = try JSONEncoder().encode(event)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertNil(object["providerAccountID"])
        XCTAssertNil(object["providerAccountLabel"])
    }

    // MARK: - Helpers

    private func makeLedgerURL() throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-usage-account-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        return rootURL.appendingPathComponent("usage-events.jsonl", isDirectory: false)
    }

    private func makeEvent(
        providerAccountID: String?,
        providerAccountLabel: String?
    ) -> BurnBarUsageEvent {
        BurnBarUsageEvent(
            runID: BurnBarRunID(rawValue: "run-account-1"),
            providerID: "openai",
            modelID: "gpt-5",
            inputTokens: 100,
            outputTokens: 40,
            cacheReadTokens: 0,
            cost: 0.001,
            recordedAt: Date(timeIntervalSince1970: 1_710_000_000),
            providerAccountID: providerAccountID,
            providerAccountLabel: providerAccountLabel
        )
    }
}
