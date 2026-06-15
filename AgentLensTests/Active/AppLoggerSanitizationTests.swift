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
    func testResolveSentryDSN_fromInfoDictionary() throws {
        let (mockBundle, cleanup) = try createMockBundle(
            info: ["sentry.dsn": "https://mock@sentry.io/1"]
        )
        defer { cleanup() }
        let dsn = OpenBurnBarApp.resolveSentryDSN(bundle: mockBundle)
        XCTAssertEqual(dsn, "https://mock@sentry.io/1")
    }

    @MainActor
    func testResolveSentryDSN_fromGoogleServiceInfo() throws {
        let (mockBundle, cleanup) = try createMockBundle(
            info: [:],
            files: ["GoogleService-Info.plist": ["sentry.dsn": "https://google-mock@sentry.io/2"]]
        )
        defer { cleanup() }
        let dsn = OpenBurnBarApp.resolveSentryDSN(bundle: mockBundle)
        XCTAssertEqual(dsn, "https://google-mock@sentry.io/2")
    }

    @MainActor
    func testResolveSentryDSN_emptyFallback() throws {
        let (mockBundle, cleanup) = try createMockBundle(info: [:])
        defer { cleanup() }
        let dsn = OpenBurnBarApp.resolveSentryDSN(bundle: mockBundle)
        XCTAssertNil(dsn)
    }

    private func createMockBundle(info: [String: Any], files: [String: [String: Any]] = [:]) throws -> (bundle: Bundle, cleanup: () -> Void) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MockBundle-\(UUID().uuidString).bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        // Write Info.plist
        let infoPlistURL = tempDir.appendingPathComponent("Info.plist")
        try (info as NSDictionary).write(to: infoPlistURL)
        
        // Write other files (like GoogleService-Info.plist)
        for (filename, content) in files {
            let fileURL = tempDir.appendingPathComponent(filename)
            try (content as NSDictionary).write(to: fileURL)
        }
        
        guard let bundle = Bundle(url: tempDir) else {
            throw NSError(domain: "MockBundle", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to construct Bundle from URL"])
        }
        
        let cleanup = {
            _ = try? FileManager.default.removeItem(at: tempDir)
        }
        
        return (bundle, cleanup)
    }
    #endif
}
