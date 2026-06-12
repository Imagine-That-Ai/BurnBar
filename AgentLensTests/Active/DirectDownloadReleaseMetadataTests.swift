import Foundation
import XCTest
@testable import OpenBurnBar

/// Covers the feed-metadata model for the direct-download updater: version
/// comparison, decoding of `latest-macos.json` (including the `critical`
/// security flag emitted by `scripts/generate-macos-appcast.mjs`), and the
/// shape-only well-formedness pre-filter.
final class DirectDownloadReleaseMetadataTests: XCTestCase {

    private static let feedURL =
        URL(string: "https://github.com/Imagine-That-Ai/BurnBar/releases/latest/download/latest-macos.json")!

    private func makeRelease(
        version: String = "2.0.0",
        build: String = "200",
        downloadUrl: URL = URL(string: "https://github.com/Imagine-That-Ai/BurnBar/releases/latest/download/OpenBurnBar-2.0.0.dmg")!,
        appcastUrl: URL? = URL(string: "https://github.com/Imagine-That-Ai/BurnBar/releases/latest/download/appcast.xml"),
        length: Int = 1024,
        sha256: String = String(repeating: "ab", count: 32),
        sparkleEdSignature: String? = "c2lnbmF0dXJl",
        critical: Bool = false
    ) -> DirectDownloadRelease {
        DirectDownloadRelease(
            version: version,
            build: build,
            downloadUrl: downloadUrl,
            appcastUrl: appcastUrl,
            length: length,
            sha256: sha256,
            sparkleEdSignature: sparkleEdSignature,
            critical: critical
        )
    }

    // MARK: - Version comparison

    func testHigherNumericBuildIsNewer() {
        let release = makeRelease(version: "1.0.0", build: "201")
        XCTAssertTrue(release.isNewer(thanBuild: "200", currentVersion: "1.0.0"))
        XCTAssertFalse(release.isNewer(thanBuild: "202", currentVersion: "1.0.0"))
    }

    func testEqualBuildFallsBackToNumericVersionComparison() {
        XCTAssertTrue(makeRelease(version: "1.10.0", build: "200").isNewer(thanBuild: "200", currentVersion: "1.9.0"))
        XCTAssertFalse(makeRelease(version: "1.9.0", build: "200").isNewer(thanBuild: "200", currentVersion: "1.10.0"))
        XCTAssertFalse(makeRelease(version: "1.9.0", build: "200").isNewer(thanBuild: "200", currentVersion: "1.9.0"))
    }

    func testNonNumericBuildFallsBackToVersionComparison() {
        let release = makeRelease(version: "2.0.0", build: "2.0.0.42")
        XCTAssertTrue(release.isNewer(thanBuild: "1.9.9.1", currentVersion: "1.9.9"))
    }

    // MARK: - Decoding latest-macos.json

    func testDecodesGeneratorOutputWithoutCriticalFlagAsNonCritical() throws {
        // Field names mirror scripts/generate-macos-appcast.mjs (pre-critical
        // feeds in the wild won't carry the key at all).
        let json = """
        {
          "appcastUrl": "https://github.com/Imagine-That-Ai/BurnBar/releases/latest/download/appcast.xml",
          "build": "200",
          "bundleId": "ai.burnbar.OpenBurnBar",
          "channel": "direct-download",
          "downloadUrl": "https://github.com/Imagine-That-Ai/BurnBar/releases/latest/download/OpenBurnBar-2.0.0.dmg",
          "length": 52428800,
          "sha256": "\(String(repeating: "ab", count: 32))",
          "sparkleEdSignature": "c2lnbmF0dXJl",
          "version": "2.0.0"
        }
        """
        let release = try JSONDecoder().decode(DirectDownloadRelease.self, from: Data(json.utf8))
        XCTAssertEqual(release.version, "2.0.0")
        XCTAssertEqual(release.build, "200")
        XCTAssertFalse(release.critical, "Absent critical flag must default to false")
    }

    func testDecodesCriticalFlagWhenPresent() throws {
        let json = """
        {
          "build": "201",
          "critical": true,
          "downloadUrl": "https://github.com/Imagine-That-Ai/BurnBar/releases/latest/download/OpenBurnBar-2.0.1.dmg",
          "length": 52428800,
          "sha256": "\(String(repeating: "ab", count: 32))",
          "sparkleEdSignature": "c2lnbmF0dXJl",
          "version": "2.0.1"
        }
        """
        let release = try JSONDecoder().decode(DirectDownloadRelease.self, from: Data(json.utf8))
        XCTAssertTrue(release.critical)
        XCTAssertNil(release.appcastUrl)
    }

    // MARK: - Well-formedness pre-filter (NOT a trust check)

    func testWellFormedMetadataPasses() {
        XCTAssertTrue(makeRelease().hasWellFormedDownloadMetadata(from: Self.feedURL))
    }

    func testNonHTTPSDownloadURLIsRejected() {
        let release = makeRelease(downloadUrl: URL(string: "http://github.com/x/OpenBurnBar.dmg")!)
        XCTAssertFalse(release.hasWellFormedDownloadMetadata(from: Self.feedURL))
    }

    func testDownloadHostMustMatchFeedHost() {
        let release = makeRelease(downloadUrl: URL(string: "https://evil.example.com/OpenBurnBar.dmg")!)
        XCTAssertFalse(release.hasWellFormedDownloadMetadata(from: Self.feedURL))
    }

    func testMalformedDigestIsRejected() {
        XCTAssertFalse(makeRelease(sha256: "not-hex").hasWellFormedDownloadMetadata(from: Self.feedURL))
        XCTAssertFalse(makeRelease(sha256: String(repeating: "a", count: 63)).hasWellFormedDownloadMetadata(from: Self.feedURL))
    }

    func testNonPositiveLengthIsRejected() {
        XCTAssertFalse(makeRelease(length: 0).hasWellFormedDownloadMetadata(from: Self.feedURL))
        XCTAssertFalse(makeRelease(length: -5).hasWellFormedDownloadMetadata(from: Self.feedURL))
    }

    func testMissingSignatureIsRejected() {
        XCTAssertFalse(makeRelease(sparkleEdSignature: nil).hasWellFormedDownloadMetadata(from: Self.feedURL))
        XCTAssertFalse(makeRelease(sparkleEdSignature: "  \n").hasWellFormedDownloadMetadata(from: Self.feedURL))
    }

    func testHTTPAppcastURLIsRejected() {
        let release = makeRelease(appcastUrl: URL(string: "http://github.com/x/appcast.xml"))
        XCTAssertFalse(release.hasWellFormedDownloadMetadata(from: Self.feedURL))
    }
}
