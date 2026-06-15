import XCTest
#if canImport(Sentry)
@testable import OpenBurnBar

/**
 * Regression coverage for F-RR09-003 Sentry DSN resolution.
 *
 * The app reads the DSN from `Info.plist` first, then falls back to the
 * `sentry.dsn` key inside `GoogleService-Info.plist` (injected by CI). These
 * tests prove the resolution order and whitespace/empty handling so Sentry
 * stays dark for OSS builds and lights up correctly for internal builds.
 */
final class SentryDSNResolutionTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-sentry-dsn-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true
        )
    }

    override func tearDown() {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        super.tearDown()
    }

    @MainActor
    func testResolveSentryDSNFromInfoPlist() throws {
        let bundle = try makeBundle(
            infoPlist: ["sentry.dsn": "https://primary@example.com/1"]
        )
        XCTAssertEqual(
            OpenBurnBarApp.resolveSentryDSN(bundle: bundle),
            "https://primary@example.com/1"
        )
    }

    @MainActor
    func testResolveSentryDSNFallsBackToGoogleServiceInfoPlist() throws {
        let bundle = try makeBundle(
            googleServicePlist: ["sentry.dsn": "https://fallback@example.com/2"]
        )
        XCTAssertEqual(
            OpenBurnBarApp.resolveSentryDSN(bundle: bundle),
            "https://fallback@example.com/2"
        )
    }

    @MainActor
    func testResolveSentryDSNPrefersInfoPlistOverGoogleServiceInfoPlist() throws {
        let bundle = try makeBundle(
            infoPlist: ["sentry.dsn": "https://primary@example.com/1"],
            googleServicePlist: ["sentry.dsn": "https://secondary@example.com/2"]
        )
        XCTAssertEqual(
            OpenBurnBarApp.resolveSentryDSN(bundle: bundle),
            "https://primary@example.com/1"
        )
    }

    @MainActor
    func testResolveSentryDSNReturnsNilWhenNoDSNConfigured() throws {
        let bundle = try makeBundle()
        XCTAssertNil(OpenBurnBarApp.resolveSentryDSN(bundle: bundle))
    }

    @MainActor
    func testResolveSentryDSNIgnoresWhitespaceOnlyDSN() throws {
        let bundle = try makeBundle(
            infoPlist: ["sentry.dsn": "   "],
            googleServicePlist: ["sentry.dsn": "\t\n"]
        )
        XCTAssertNil(OpenBurnBarApp.resolveSentryDSN(bundle: bundle))
    }

    @MainActor
    func testResolveSentryDSNIgnoresEmptyStringDSN() throws {
        let bundle = try makeBundle(
            infoPlist: ["sentry.dsn": ""],
            googleServicePlist: ["sentry.dsn": ""]
        )
        XCTAssertNil(OpenBurnBarApp.resolveSentryDSN(bundle: bundle))
    }

    // MARK: - Helpers

    private func makeBundle(
        infoPlist: [String: String] = [:],
        googleServicePlist: [String: String] = [:]
    ) throws -> Bundle {
        let bundleURL = tempDir.appendingPathComponent("SentryDSNTest.bundle")
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )

        // The bundle's own Info.plist. When infoPlist contains sentry.dsn it is
        // read by `object(forInfoDictionaryKey:)`. When absent the bundle still
        // needs a CFBundleIdentifier so `Bundle(path:)` loads successfully.
        var bundleInfo: [String: String] = ["CFBundleIdentifier": "com.openburnbar.tests.sentry-dsn"]
        for (key, value) in infoPlist {
            bundleInfo[key] = value
        }
        let infoURL = bundleURL.appendingPathComponent("Info.plist")
        try (bundleInfo as NSDictionary).write(to: infoURL)

        if !googleServicePlist.isEmpty {
            let googleURL = bundleURL.appendingPathComponent("GoogleService-Info.plist")
            try (googleServicePlist as NSDictionary).write(to: googleURL)
        }

        guard let bundle = Bundle(path: bundleURL.path) else {
            throw XCTSkip("Could not load test bundle from \(bundleURL.path)")
        }
        return bundle
    }
}
#endif
