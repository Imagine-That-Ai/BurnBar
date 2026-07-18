import OpenBurnBarCore
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

    func testSanitizeMetadata_redactsRawErrorDescriptionKeys() {
        let input: [String: String] = [
            "error": "PRIVATE_BUDGET_MARKER provider returned budget details for /Users/alberto/project",
            "localizedDescription": "PRIVATE_BUDGET_MARKER detailed upstream response",
            "debugDescription": "PRIVATE_BUDGET_MARKER debug payload",
            "errorDomain": "NSCocoaErrorDomain",
            "errorCode": "4"
        ]

        let sanitized = AppLogger.sanitizeMetadata(input)

        XCTAssertEqual(sanitized["error"], "[REDACTED]")
        XCTAssertEqual(sanitized["localizedDescription"], "[REDACTED]")
        XCTAssertEqual(sanitized["debugDescription"], "[REDACTED]")
        XCTAssertEqual(sanitized["errorDomain"], "NSCocoaErrorDomain")
        XCTAssertEqual(sanitized["errorCode"], "4")
    }

    func testPublicErrorMetadataDoesNotIncludeLocalizedDescription() {
        let error = NSError(
            domain: "com.openburnbar.quota",
            code: 402,
            userInfo: [
                NSLocalizedDescriptionKey: "PRIVATE_BUDGET_MARKER budget details from provider"
            ]
        )

        let metadata = AppLogger.publicErrorMetadata(error)
        let serialized = metadata.values.joined(separator: " ")

        XCTAssertNil(metadata["error"])
        XCTAssertEqual(metadata["errorType"], "NSError")
        XCTAssertEqual(metadata["errorDomain"], "com.openburnbar.quota")
        XCTAssertEqual(metadata["errorCode"], "402")
        XCTAssertFalse(serialized.contains("PRIVATE_BUDGET_MARKER"))
        XCTAssertFalse(serialized.contains("budget details"))
        XCTAssertEqual(AppLogger.sanitizeMetadata(metadata), metadata)
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

    func testSilentlyOptional_returnsSuccessfulValueAndEvaluatesOnce() {
        var invocationCount = 0
        func produceValue() throws -> Int {
            invocationCount += 1
            return 42
        }

        let result = AppLogger.shared.silentlyOptional(
            "test_optional_success",
            try produceValue()
        )

        XCTAssertEqual(result, 42)
        XCTAssertEqual(invocationCount, 1)
    }

    func testSilentlyOptional_returnsNilAfterFailureAndEvaluatesOnce() {
        var invocationCount = 0
        func fail() throws -> Int {
            invocationCount += 1
            throw AppLoggerTestError.expected
        }

        let result = AppLogger.shared.silentlyOptional(
            "test_optional_failure",
            try fail()
        )

        XCTAssertNil(result)
        XCTAssertEqual(invocationCount, 1)
    }

    func testQuotaLogger_forwardsShadowComparisonToInjectedRecorder() {
        let recorded = Locked<[DomainCoreQuotaShadowComparison]>([])
        let logger = AppLoggerQuotaLogger { comparison in
            recorded.withLock { $0.append(comparison) }
        }
        let comparison = DomainCoreQuotaShadowComparison(
            operation: "claude_quota",
            coreVersion: "0.3.0",
            observedAt: Date(timeIntervalSince1970: 1_752_408_000),
            outcome: .mismatch,
            mismatchCategory: .resultMismatch,
            legacyMicros: 120,
            rustMicros: 80
        )

        logger.recordDomainCoreShadowComparison(comparison)

        XCTAssertEqual(recorded.read(), [comparison])
    }

    func testMacPlatformCompositionInstallsShadowSinkIdempotentlyBeforeFirstQuotaComparison() {
        let escapedComparisons = Locked<[DomainCoreShadowComparison]>([])
        DomainCoreShadowComparisonCollector.configure { comparison in
            escapedComparisons.withLock { $0.append(comparison) }
        }
        defer { DomainCoreShadowComparisonCollector.configure(nil) }

        // The startup composition call must install one lifetime-owned app sink.
        // No quota comparison has happened before this cross-domain record.
        ProviderQuotaMacPlatform.installDomainCoreShadowEvidenceRecorder()
        ProviderQuotaMacPlatform.installDomainCoreShadowEvidenceRecorder()
        DomainCoreShadowComparisonCollector.record(.init(
            domain: "cloudvault",
            slice: "search",
            operation: "query",
            coreVersion: "0.3.0",
            outcome: "match",
            mismatchCategory: nil,
            legacyMicros: 10,
            rustMicros: 8
        ))

        XCTAssertTrue(
            escapedComparisons.read().isEmpty,
            "The macOS composition owner left the collector's pre-install sink active"
        )
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

private enum AppLoggerTestError: Error {
    case expected
}
