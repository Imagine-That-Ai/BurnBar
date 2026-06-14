import Foundation
import OpenBurnBarCore
import XCTest
@testable import OpenBurnBar

/// Focused coverage for the `readCache()` hardening: a missing cache must
/// stay silent and fall through, a *present-but-corrupt* cache must degrade
/// gracefully (never crash, never be served as if valid), and a valid fresh
/// cache must still short-circuit the network exactly as before the refactor.
///
/// `readCache()` is private, so every assertion drives it through the public
/// `fetchRateLimits(credentials:now:)` entry point. A `URLProtocol` stub keeps
/// the live path fully hermetic — no real network — so each test deterministically
/// distinguishes "cache hit" (`sourceWasCache == true`) from "fell through to
/// live" (`sourceWasCache == false`).
final class ClaudeOAuthUsageFetcherMattersTests: XCTestCase {
    private var tempDirectories: [URL] = []

    override func tearDownWithError() throws {
        ClaudeOAuthUsageStubProtocol.requestHandler = nil
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    // MARK: - Happy path (refactor must not break valid-cache parsing)

    /// A fresh, well-formed cache inside its reset window must be returned
    /// verbatim without any network call. If the read/parse hardening had
    /// changed the success shape, `sourceWasCache` would flip to false.
    func test_validFreshCache_isServedWithoutNetwork() async throws {
        let cacheURL = try makeCacheURL()
        let now = Date()
        try writeCacheFile(
            at: cacheURL,
            fetchedAt: now,
            fiveHourResetsAt: now.addingTimeInterval(3600),
            usedPercentage: 42
        )

        let fetcher = makeFetcher(cacheURL: cacheURL) { _ in
            XCTFail("Live endpoint must not be called when a fresh cache exists")
            throw URLError(.cannotLoadFromNetwork)
        }

        let result = await fetcher.fetchRateLimits(credentials: makeCredentials(), now: now)

        XCTAssertTrue(result.sourceWasCache, "Fresh valid cache should short-circuit the network")
        XCTAssertEqual(result.rateLimits?.window(named: "five_hour")?.usedPercentage, 42)
    }

    // MARK: - The matters path: corrupt cache must NOT be served / crash

    /// A present-but-corrupt cache file must be skipped (logged + nil),
    /// letting the fetcher fall through to the live call. The decisive
    /// signal is `sourceWasCache == false` with a live payload returned —
    /// proving the garbage file was neither crashed on nor served.
    func test_corruptCache_fallsThroughToLive() async throws {
        let cacheURL = try makeCacheURL()
        try Data("{ this is not json ]".utf8).write(to: cacheURL)

        let now = Date()
        let liveBody = liveUsageBody(usedPercentage: 17, fiveHourResetSeconds: now.timeIntervalSince1970 + 3600)
        let fetcher = makeFetcher(cacheURL: cacheURL) { request in
            (try Self.okResponse(for: request), Data(liveBody.utf8))
        }

        let result = await fetcher.fetchRateLimits(credentials: makeCredentials(), now: now)

        XCTAssertFalse(result.sourceWasCache, "A corrupt cache must not be served as if valid")
        XCTAssertEqual(result.rateLimits?.window(named: "five_hour")?.usedPercentage, 17)
    }

    /// Fail-safe, not fail-open: a corrupt cache combined with an unreachable
    /// endpoint must yield `nil` rate limits. The old `try?` could only ever
    /// also return nil here, but it did so *silently* and indistinguishably
    /// from a healthy miss — this pins the "never serve garbage" contract.
    func test_corruptCache_andLiveFailure_returnsNilNotGarbage() async throws {
        let cacheURL = try makeCacheURL()
        try Data(Array(repeating: UInt8(0xFF), count: 32)).write(to: cacheURL)

        let fetcher = makeFetcher(cacheURL: cacheURL) { request in
            (try Self.response(for: request, statusCode: 500), Data("{}".utf8))
        }

        let result = await fetcher.fetchRateLimits(credentials: makeCredentials(), now: Date())

        XCTAssertNil(result.rateLimits, "Corrupt cache + dead endpoint must surface no signal, never garbage")
        XCTAssertFalse(result.sourceWasCache)
    }

    // MARK: - Missing cache stays silent + falls through

    /// No cache file at all is the normal cold-start case: it must fall
    /// straight through to the live call and return the live payload.
    func test_missingCache_fallsThroughToLive() async throws {
        let cacheURL = try makeCacheURL() // never written → missing cache

        let now = Date()
        let liveBody = liveUsageBody(usedPercentage: 8, fiveHourResetSeconds: now.timeIntervalSince1970 + 3600)
        let fetcher = makeFetcher(cacheURL: cacheURL) { request in
            (try Self.okResponse(for: request), Data(liveBody.utf8))
        }

        let result = await fetcher.fetchRateLimits(credentials: makeCredentials(), now: now)

        XCTAssertFalse(result.sourceWasCache)
        XCTAssertEqual(result.rateLimits?.window(named: "five_hour")?.usedPercentage, 8)
    }

    /// A valid JSON file of the *wrong shape* (a top-level array, not an
    /// object) is parseable but unusable — it must be treated like a miss
    /// and fall through, never crash. Guards the `as? [String: Any]`
    /// non-throwing nil branch the hardening preserves.
    func test_wrongShapeCache_fallsThroughToLive() async throws {
        let cacheURL = try makeCacheURL()
        try Data("[1, 2, 3]".utf8).write(to: cacheURL)

        let now = Date()
        let liveBody = liveUsageBody(usedPercentage: 5, fiveHourResetSeconds: now.timeIntervalSince1970 + 3600)
        let fetcher = makeFetcher(cacheURL: cacheURL) { request in
            (try Self.okResponse(for: request), Data(liveBody.utf8))
        }

        let result = await fetcher.fetchRateLimits(credentials: makeCredentials(), now: now)

        XCTAssertFalse(result.sourceWasCache)
        XCTAssertEqual(result.rateLimits?.window(named: "five_hour")?.usedPercentage, 5)
    }

    // MARK: - Fixtures

    private func makeFetcher(
        cacheURL: URL,
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> ClaudeOAuthUsageFetcher {
        ClaudeOAuthUsageStubProtocol.requestHandler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClaudeOAuthUsageStubProtocol.self]
        let session = URLSession(configuration: configuration)
        return ClaudeOAuthUsageFetcher(
            session: session,
            cacheURL: cacheURL,
            minimumLivePollInterval: 0 // never gate the live path in tests
        )
    }

    private func makeCredentials() -> ClaudeOAuthCredentials {
        ClaudeOAuthCredentials(
            accessToken: "test-access-token",
            refreshToken: nil,
            expiresAt: nil, // never-expiring synthetic creds — no refresh path
            subscriptionType: "max",
            rateLimitTier: "default_claude_max_20x",
            organizationUuid: nil
        )
    }

    private func liveUsageBody(usedPercentage: Double, fiveHourResetSeconds: TimeInterval) -> String {
        """
        {"rate_limits":{"five_hour":{"used_percentage":\(usedPercentage),"resets_at":\(fiveHourResetSeconds)}}}
        """
    }

    private func writeCacheFile(
        at url: URL,
        fetchedAt: Date,
        fiveHourResetsAt: Date,
        usedPercentage: Double
    ) throws {
        let formatter = ISO8601DateFormatter()
        let envelope: [String: Any] = [
            "fetchedAt": formatter.string(from: fetchedAt),
            "fiveHourResetsAt": formatter.string(from: fiveHourResetsAt),
            "payload": [
                "five_hour": [
                    "used_percentage": usedPercentage,
                    "resets_at": formatter.string(from: fiveHourResetsAt)
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        try data.write(to: url)
    }

    /// Returns a cache URL inside a fresh temp directory. The directory
    /// exists; the file does not until a test writes it. Tests that want a
    /// "missing cache" simply never write — `readCache()` must treat that
    /// (the cold-start case) as a silent miss.
    private func makeCacheURL() throws -> URL {
        let directory = try makeTemporaryDirectory()
        return directory.appendingPathComponent("usage-cache.json", isDirectory: false)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        return directory
    }

    private static func okResponse(for request: URLRequest) throws -> HTTPURLResponse {
        try response(for: request, statusCode: 200)
    }

    private static func response(for request: URLRequest, statusCode: Int) throws -> HTTPURLResponse {
        let url = try XCTUnwrap(request.url)
        return try XCTUnwrap(
            HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )
        )
    }
}

/// Hermetic `URLProtocol` stub for the fetcher's live path. Mirrors the
/// `Locked`-backed pattern already used by `ProviderQuotaServiceTests` so the
/// handler seam is thread-safe and swiftlint-clean.
private final class ClaudeOAuthUsageStubProtocol: URLProtocol {
    private static let _requestHandler =
        Locked<(@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?>(nil)

    static var requestHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { _requestHandler.read() }
        set { _requestHandler.write(newValue) }
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
