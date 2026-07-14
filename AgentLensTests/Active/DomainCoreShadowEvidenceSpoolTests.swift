import Foundation
import OpenBurnBarCore
import OpenBurnBarKernel
import XCTest
@testable import OpenBurnBar

final class DomainCoreShadowEvidenceSpoolTests: XCTestCase {
    func testSampleEncodingUsesExactPrivacySafeSchemaIncludingNullCategory() throws {
        let sample = try XCTUnwrap(makeSample())
        let data = try JSONEncoder().encode(sample)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(Set(object.keys), Set([
            "schemaVersion", "sampleId", "domain", "slice", "consumer", "channel", "operation",
            "coreVersion", "observedAt", "outcome", "mismatchCategory", "legacyMicros", "rustMicros"
        ]))
        XCTAssertTrue(object["mismatchCategory"] is NSNull)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("uid"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("payload"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("deviceId"))
    }

    func testRotationBoundsFilesAndDropsOldestWholeBatch() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let spool = try DomainCoreShadowEvidenceSpool(
            directory: directory,
            maxFileBytes: 4_096,
            maxReadyFiles: 2,
            maxSamplesPerFile: 1
        )

        try spool.append(try XCTUnwrap(makeSample(micros: 1)))
        try spool.append(try XCTUnwrap(makeSample(micros: 2)))
        try spool.append(try XCTUnwrap(makeSample(micros: 3)))
        let batch = try XCTUnwrap(spool.nextBatch())

        XCTAssertEqual(try spool.pendingSampleCount(), 2)
        let readyFiles = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("ready-") }
        XCTAssertEqual(readyFiles.count, 2)
        XCTAssertEqual(batch.samples.single?.legacyMicros, 2)
    }

    func testGenericCollectorBuildsValidatedV2SamplesForEveryAppleDomain() throws {
        for (domain, slice, operation) in [
            ("cloudvault", "search", "query"),
            ("hermes", "ratchet", "ratchet_chain_kdf"),
            ("pricing", "token-cost", "calculate_token_cost")
        ] {
            let sample = try XCTUnwrap(DomainCoreShadowSampleV2(
                comparison: .init(
                    domain: domain,
                    slice: slice,
                    operation: operation,
                    coreVersion: "0.3.0",
                    outcome: "match",
                    mismatchCategory: nil,
                    legacyMicros: 10,
                    rustMicros: 8
                ),
                channel: "internal"
            ))
            XCTAssertEqual(sample.schemaVersion, 2)
            XCTAssertEqual(sample.domain, domain)
            XCTAssertEqual(sample.slice, slice)
            XCTAssertEqual(sample.consumer, "apple")
        }
    }

    func testUnacknowledgedBatchIsReturnedForRetryUntilAcknowledged() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let spool = try DomainCoreShadowEvidenceSpool(directory: directory)
        try spool.append(try XCTUnwrap(makeSample()))

        let first = try XCTUnwrap(spool.nextBatch())
        let retry = try XCTUnwrap(spool.nextBatch())
        XCTAssertEqual(first.token, retry.token)
        XCTAssertEqual(try spool.pendingSampleCount(), 1)

        try spool.acknowledge(retry.token)
        XCTAssertEqual(try spool.pendingSampleCount(), 0)
        XCTAssertNil(try spool.nextBatch())
    }

    func testRapidSamplesCoalesceIntoOneBoundedDelayedUpload() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let spool = try DomainCoreShadowEvidenceSpool(directory: directory)
        let submitter = RecordingDomainCoreShadowSubmitter()
        let coordinator = DomainCoreShadowEvidenceUploadCoordinator(
            spool: spool,
            submitter: submitter,
            debounceNanoseconds: 20_000_000
        )

        try spool.append(try XCTUnwrap(makeSample(micros: 1)))
        await coordinator.scheduleFlush()
        try spool.append(try XCTUnwrap(makeSample(micros: 2)))
        await coordinator.scheduleFlush()
        try spool.append(try XCTUnwrap(makeSample(micros: 3)))
        await coordinator.scheduleFlush()
        try await Task.sleep(nanoseconds: 200_000_000)

        let batchSizes = await submitter.batchSizes()
        XCTAssertEqual(batchSizes, [3])
        XCTAssertEqual(try spool.pendingSampleCount(), 0)
    }

    private func makeSample(micros: UInt64 = 120) -> DomainCoreShadowSampleV2? {
        DomainCoreShadowSampleV2(
            comparison: DomainCoreQuotaShadowComparison(
                operation: "claude_quota",
                coreVersion: "0.3.0",
                observedAt: Date(timeIntervalSince1970: 1_752_408_000),
                outcome: .match,
                legacyMicros: micros,
                rustMicros: 80
            ),
            channel: "internal"
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-shadow-\(UUID().uuidString)", isDirectory: true)
    }
}

private actor RecordingDomainCoreShadowSubmitter: DomainCoreShadowSampleSubmitting {
    private var sizes: [Int] = []

    func submit(_ samples: [DomainCoreShadowSampleV2]) async throws {
        sizes.append(samples.count)
    }

    func batchSizes() -> [Int] { sizes }
}

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}
