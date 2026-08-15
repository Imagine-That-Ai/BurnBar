import XCTest
@testable import OpenBurnBarQuota

final class WarpTelemetryTailTests: XCTestCase {
    func testScan_readsTailWhenNewestCreditIsAtTheEnd() throws {
        let credit = creditBody(used: 12, limit: 100)
        let content = String(repeating: noiseBody(), count: 80) + credit
        let (home, url) = try writeLog(content)
        defer { try? FileManager.default.removeItem(at: home) }

        let fileSize = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber).intValue
        let scan = try XCTUnwrap(WarpQuotaAdapter.scanLogForCredit(at: url, tailBytes: 512))

        XCTAssertEqual(scan.bucket?.usedValue, 12)
        XCTAssertEqual(scan.bucket?.limitValue, 100)
        XCTAssertFalse(scan.usedFullFile)
        XCTAssertLessThan(scan.bytesRead, fileSize / 2)
        XCTAssertGreaterThan(fileSize, 2_000)
    }

    func testScan_failClosesToFullFileWhenCreditIsOnlyInThePrefix() throws {
        let credit = creditBody(used: 7, limit: 50)
        let content = credit + String(repeating: noiseBody(), count: 80)
        let (home, url) = try writeLog(content)
        defer { try? FileManager.default.removeItem(at: home) }

        let fullBucket = try XCTUnwrap(WarpQuotaAdapter.newestCreditBucket(in: content))
        let scan = try XCTUnwrap(WarpQuotaAdapter.scanLogForCredit(at: url, tailBytes: 512))

        XCTAssertTrue(scan.usedFullFile)
        XCTAssertEqual(scan.bucket?.usedValue, fullBucket.usedValue)
        XCTAssertEqual(scan.bucket?.limitValue, fullBucket.limitValue)
        XCTAssertEqual(scan.bucket?.usedValue, 7)
    }

    func testScan_tailAndFullAgreeWhenCreditIsInTheTail() throws {
        let content = String(repeating: noiseBody(), count: 40) + creditBody(used: 3, limit: 9)
        let (home, url) = try writeLog(content)
        defer { try? FileManager.default.removeItem(at: home) }

        let fromText = try XCTUnwrap(WarpQuotaAdapter.newestCreditBucket(in: content))
        let scan = try XCTUnwrap(WarpQuotaAdapter.scanLogForCredit(at: url, tailBytes: 256))
        XCTAssertEqual(scan.bucket?.usedValue, fromText.usedValue)
        XCTAssertEqual(scan.bucket?.limitValue, fromText.limitValue)
        XCTAssertFalse(scan.usedFullFile)
    }

    func testScan_returnsNilBucketWhenTelemetryHasNoCredits() throws {
        let (home, url) = try writeLog(String(repeating: noiseBody(), count: 8))
        defer { try? FileManager.default.removeItem(at: home) }

        let scan = try XCTUnwrap(WarpQuotaAdapter.scanLogForCredit(at: url, tailBytes: 256))
        XCTAssertNil(scan.bucket)
        XCTAssertTrue(scan.usedFullFile)
    }

    private func creditBody(used: Int, limit: Int) -> String {
        """
        Body {"credits_used":\(used),"credits_limit":\(limit),"resets_at":"2026-09-01T00:00:00Z"}

        """
    }

    private func noiseBody() -> String {
        let pad = String(repeating: "x", count: 80)
        return "Body {\"batch\":[{\"event\":\"noise\",\"payload\":{\"pad\":\"\(pad)\"}}]}\n"
    }

    private func writeLog(_ content: String) throws -> (URL, URL) {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-warp-tail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let url = home.appendingPathComponent("warp_network_0.log")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return (home, url)
    }
}
