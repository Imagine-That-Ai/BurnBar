import XCTest
@testable import OpenBurnBar

final class AppLoggerSanitizationTests: XCTestCase {

    func testSanitizeMetadata_redactsSensitiveKeys() {
        let input: [String: String] = [
            "token": "sk-secret-12345",
            "apiKey": "abc-def",
            "password": "hunter2",
            "refreshToken": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9",
            "safeKey": "safe-value"
        ]
        let sanitized = AppLogger.sanitizeMetadata(input)
        XCTAssertEqual(sanitized["token"], "[REDACTED]")
        XCTAssertEqual(sanitized["apiKey"], "[REDACTED]")
        XCTAssertEqual(sanitized["password"], "[REDACTED]")
        XCTAssertEqual(sanitized["refreshToken"], "[REDACTED]")
        XCTAssertEqual(sanitized["safeKey"], "safe-value")
    }

    func testSanitizeMetadata_redactsPathLikeValues() {
        let input: [String: String] = [
            "somePath": "/Users/alice/Documents/secret.txt",
            "homeDir": "~/Downloads",
            "sshKey": "~/.ssh/id_rsa",
            "config": "/Users/alice/.aws/credentials"
        ]
        let sanitized = AppLogger.sanitizeMetadata(input)
        XCTAssertEqual(sanitized["somePath"], "[REDACTED]")
        XCTAssertEqual(sanitized["homeDir"], "[REDACTED]")
        XCTAssertEqual(sanitized["sshKey"], "[REDACTED]")
        XCTAssertEqual(sanitized["config"], "[REDACTED]")
    }

    func testSanitizeMetadata_redactsTokenLikeValues() {
        let input: [String: String] = [
            "header": "Bearer abc123",
            "auth": "token=sekrit",
            "x-api-key": "sk-prod-xyz",
            "raw": "bearer xyz789"
        ]
        let sanitized = AppLogger.sanitizeMetadata(input)
        XCTAssertEqual(sanitized["header"], "[REDACTED]")
        XCTAssertEqual(sanitized["auth"], "[REDACTED]")
        XCTAssertEqual(sanitized["x-api-key"], "[REDACTED]")
        XCTAssertEqual(sanitized["raw"], "[REDACTED]")
    }

    func testSanitizeMetadata_redactsProjectNamesAndModels() {
        let input: [String: String] = [
            "projectName": "AcmeCorp-SecretProject",
            "model": "gpt-4-turbo",
            "model_id": "claude-3-opus"
        ]
        let sanitized = AppLogger.sanitizeMetadata(input)
        XCTAssertEqual(sanitized["projectName"], "[REDACTED]")
        XCTAssertEqual(sanitized["model"], "[REDACTED]")
        XCTAssertEqual(sanitized["model_id"], "[REDACTED]")
    }

    func testSanitizeMetadata_truncatesLongValues() {
        let longValue = String(repeating: "A", count: 600)
        let input = ["longText": longValue]
        let sanitized = AppLogger.sanitizeMetadata(input)
        XCTAssertTrue(sanitized["longText"]?.hasSuffix("...[TRUNCATED]") ?? false)
        XCTAssertEqual(sanitized["longText"]?.count, 513)
    }

    func testSanitizeMetadata_preservesShortSafeValues() {
        let input: [String: String] = [
            "count": "42",
            "status": "ok",
            "provider": "openai"
        ]
        let sanitized = AppLogger.sanitizeMetadata(input)
        XCTAssertEqual(sanitized["count"], "42")
        XCTAssertEqual(sanitized["status"], "ok")
        XCTAssertEqual(sanitized["provider"], "openai")
    }

    func testSanitizeMetadata_caseInsensitiveKeyMatch() {
        let input: [String: String] = [
            "APIKEY": "secret",
            "Authorization": "Bearer token"
        ]
        let sanitized = AppLogger.sanitizeMetadata(input)
        XCTAssertEqual(sanitized["APIKEY"], "[REDACTED]")
        XCTAssertEqual(sanitized["Authorization"], "[REDACTED]")
    }

    #if canImport(Sentry)
    @MainActor
    func testResolveSentryDSN_fromInfoDictionary() {
        let mockBundle = MockBundle(
            info: ["sentry.dsn": "https://mock@sentry.io/1"],
            paths: [:]
        )
        let dsn = AgentLensApp.resolveSentryDSN(bundle: mockBundle)
        XCTAssertEqual(dsn, "https://mock@sentry.io/1")
    }

    @MainActor
    func testResolveSentryDSN_fromGoogleServiceInfo() {
        let tempDirectory = FileManager.default.temporaryDirectory
        let plistURL = tempDirectory.appendingPathComponent("GoogleService-Info.plist")
        let plistData: [String: Any] = ["sentry.dsn": "https://google-mock@sentry.io/2"]
        (plistData as NSDictionary).write(to: plistURL, atomically: true)

        defer {
            try? FileManager.default.removeItem(at: plistURL)
        }

        let mockBundle = MockBundle(
            info: [:],
            paths: ["GoogleService-Info.plist": plistURL.path]
        )
        let dsn = AgentLensApp.resolveSentryDSN(bundle: mockBundle)
        XCTAssertEqual(dsn, "https://google-mock@sentry.io/2")
    }

    @MainActor
    func testResolveSentryDSN_emptyFallback() {
        let mockBundle = MockBundle(info: [:], paths: [:])
        let dsn = AgentLensApp.resolveSentryDSN(bundle: mockBundle)
        XCTAssertNil(dsn)
    }

    private final class MockBundle: Bundle {
        private let mockInfo: [String: Any]
        private let mockPaths: [String: String]

        init(info: [String: Any], paths: [String: String] = [:]) {
            self.mockInfo = info
            self.mockPaths = paths
            super.init(path: FileManager.default.temporaryDirectory.path)!
        }

        override func object(forInfoDictionaryKey key: String) -> Any? {
            return mockInfo[key]
        }

        override func path(forResource name: String?, ofType ext: String?) -> String? {
            guard let name = name, let ext = ext else { return nil }
            return mockPaths["\(name).\(ext)"]
        }
    }
    #endif
}
