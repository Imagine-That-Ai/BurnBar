import XCTest
@testable import OpenBurnBarCore

final class InsightDigestPrivacyTests: XCTestCase {

    func testDigestStaysUnderTwentyFourKB() throws {
        let snapshot = InsightTestFixtures.twoWeeksOfUsage()
        let builder = InsightDigestBuilder()
        let digest = try builder.build(from: snapshot, filter: InsightFilter(window: .last30d))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(digest)
        XCTAssertLessThanOrEqual(data.count, InsightDigest.maxEncodedBytes,
                                 "Digest exceeded 24KB ceiling: \(data.count) bytes")
    }

    func testDigestRedactsDeviceNames() throws {
        let snapshot = InsightTestFixtures.twoWeeksOfUsage()
        let digest = try InsightDigestBuilder().build(from: snapshot, filter: InsightFilter(window: .last30d))
        for device in digest.devices {
            XCTAssertFalse(device.displayName.contains("Alberto"),
                           "Device displayName leaked real name: \(device.displayName)")
            XCTAssertTrue(device.id.hasPrefix("device_"),
                          "Device id is not anonymized: \(device.id)")
            XCTAssertTrue(device.displayName.hasPrefix("Device · "),
                          "Device displayName is not the safe template form")
        }
    }

    func testDigestAnonymizesProjectPaths() throws {
        let snapshot = InsightTestFixtures.twoWeeksOfUsage()
        let digest = try InsightDigestBuilder().build(from: snapshot, filter: InsightFilter(window: .last30d))
        for project in digest.projects {
            XCTAssertTrue(project.id.hasPrefix("project_"),
                          "Project id is not anonymized: \(project.id)")
            XCTAssertFalse(project.displayName.contains("/Users/"),
                           "Project displayName leaked filesystem path")
        }
    }

    func testDigestContentHashIsStable() throws {
        let snapshot = InsightTestFixtures.twoWeeksOfUsage()
        let builder = InsightDigestBuilder()
        let a = try builder.build(from: snapshot, filter: InsightFilter(window: .last30d))
        let b = try builder.build(from: snapshot, filter: InsightFilter(window: .last30d))
        XCTAssertEqual(a.contentHash, b.contentHash)
        XCTAssertEqual(a.contentHash.count, 64, "SHA-256 hash should be 64 hex chars")
    }

    func testDigestContainsNoKeyFiles() throws {
        // KeyFiles in a session are sensitive — they must not appear in
        // any string-serialized field of the digest.
        let snapshot = InsightTestFixtures.twoWeeksOfUsage()
        let digest = try InsightDigestBuilder().build(from: snapshot, filter: InsightFilter(window: .last30d))
        let encoded = try JSONEncoder().encode(digest)
        let str = String(data: encoded, encoding: .utf8) ?? ""
        XCTAssertFalse(str.contains("sensitive_file.swift"),
                       "Digest leaked keyFile content")
    }

    func testEmptySnapshotProducesEmptyDigest() throws {
        let window = DateInterval(start: Date().addingTimeInterval(-3600), end: Date())
        let snapshot = InsightTestFixtures.emptySnapshot(window: window)
        let digest = try InsightDigestBuilder().build(from: snapshot, filter: InsightFilter(window: .last24h))
        XCTAssertEqual(digest.rowCount, 0)
        XCTAssertEqual(digest.totals.costUSD, 0)
        XCTAssertTrue(digest.providers.isEmpty)
    }

    func testTaxonomyMembersAreOnlyAllowedOutputs() throws {
        let snapshot = InsightTestFixtures.twoWeeksOfUsage()
        let digest = try InsightDigestBuilder().build(from: snapshot, filter: InsightFilter(window: .last30d))
        for signal in digest.agentFocusSignals {
            XCTAssertTrue(InsightTaxonomy.default.isKnownFocus(signal.focus),
                          "Agent focus '\(signal.focus)' is not in the taxonomy")
        }
        for signal in digest.modelFocusSignals {
            XCTAssertTrue(InsightTaxonomy.default.isKnownFocus(signal.focus),
                          "Model focus '\(signal.focus)' is not in the taxonomy")
        }
        for bin in digest.useCaseHistogram {
            XCTAssertTrue(InsightTaxonomy.default.isKnownUseCase(bin.id),
                          "Use case '\(bin.id)' is not in the taxonomy")
        }
    }
}
