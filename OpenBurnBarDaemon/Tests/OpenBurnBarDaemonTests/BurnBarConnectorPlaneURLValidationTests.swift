import XCTest
@testable import OpenBurnBarDaemon

/// Tests for the SSRF and HTTPS-enforcement validation on connector base URLs.
///
/// Connector outbound requests attach `Authorization: Bearer` credentials,
/// so the base URL must be HTTPS-only and must not point to private/reserved IPs.
final class BurnBarConnectorPlaneURLValidationTests: XCTestCase {

    // MARK: - Happy path

    func testValidatedConnectorBaseURL_acceptsHTTPS() {
        XCTAssertNoThrow(try BurnBarConnectorPlaneService.validatedConnectorBaseURL("https://api.github.com"))
        XCTAssertNoThrow(try BurnBarConnectorPlaneService.validatedConnectorBaseURL("https://slack.com/api"))
        XCTAssertNoThrow(try BurnBarConnectorPlaneService.validatedConnectorBaseURL("https://api.linear.app/graphql"))
        XCTAssertNoThrow(try BurnBarConnectorPlaneService.validatedConnectorBaseURL("https://app.posthog.com/api"))
        XCTAssertNoThrow(try BurnBarConnectorPlaneService.validatedConnectorBaseURL("https://sentry.io/api/0"))
    }

    func testValidatedConnectorBaseURL_acceptsURLsWithPaths() {
        XCTAssertNoThrow(try BurnBarConnectorPlaneService.validatedConnectorBaseURL("https://sentry.io/api/0"))
        XCTAssertNoThrow(try BurnBarConnectorPlaneService.validatedConnectorBaseURL("https://gmail.googleapis.com/gmail/v1"))
    }

    func testValidatedConnectorBaseURL_returnsCanonicalURL() throws {
        let url = try BurnBarConnectorPlaneService.validatedConnectorBaseURL("  https://api.github.com  ")
        XCTAssertEqual(url.absoluteString, "https://api.github.com")
    }

    // MARK: - Scheme enforcement (HTTPS only)

    func testValidatedConnectorBaseURL_rejectsHTTP() {
        XCTAssertThrowsError(
            try BurnBarConnectorPlaneService.validatedConnectorBaseURL("http://api.github.com")
        ) { error in
            guard case BurnBarConnectorURLValidationError.schemeNotHTTPS("http") = error else {
                return XCTFail("Expected schemeNotHTTPS, got \(error)")
            }
        }
    }

    func testValidatedConnectorBaseURL_rejectsDangerousSchemes() {
        for blocked in [
            "file:///etc/passwd",
            "javascript:alert(1)",
            "data:text/html,hi",
            "ftp://evil.com",
            "gopher://evil.com",
        ] {
            XCTAssertThrowsError(
                try BurnBarConnectorPlaneService.validatedConnectorBaseURL(blocked)
            ) { error in
                // All should fail — either invalidURL, schemeNotHTTPS, or missingHost
                guard case BurnBarConnectorURLValidationError.schemeNotHTTPS = error
                        ?? (error as? BurnBarConnectorURLValidationError).self else {
                    // Some schemes may not parse as URLs at all — that's also fine
                    return
                }
            }
        }
    }

    // MARK: - Empty / invalid

    func testValidatedConnectorBaseURL_rejectsEmpty() {
        XCTAssertThrowsError(
            try BurnBarConnectorPlaneService.validatedConnectorBaseURL("")
        ) { error in
            guard case BurnBarConnectorURLValidationError.emptyURL = error else {
                return XCTFail("Expected emptyURL, got \(error)")
            }
        }
    }

    func testValidatedConnectorBaseURL_rejectsWhitespaceOnly() {
        XCTAssertThrowsError(
            try BurnBarConnectorPlaneService.validatedConnectorBaseURL("   ")
        ) { error in
            guard case BurnBarConnectorURLValidationError.emptyURL = error else {
                return XCTFail("Expected emptyURL, got \(error)")
            }
        }
    }

    func testValidatedConnectorBaseURL_rejectsUnparseable() {
        XCTAssertThrowsError(
            try BurnBarConnectorPlaneService.validatedConnectorBaseURL("not a url :// ???")
        )
    }

    // MARK: - SSRF: private/reserved IPs

    func testValidatedConnectorBaseURL_rejectsLoopback() {
        for host in ["127.0.0.1", "127.0.0.2", "127.1.1.1"] {
            XCTAssertThrowsError(
                try BurnBarConnectorPlaneService.validatedConnectorBaseURL("https://\(host)")
            ) { error in
                guard case BurnBarConnectorURLValidationError.privateOrReservedIP = error else {
                    return XCTFail("Expected privateOrReservedIP for \(host), got \(error)")
                }
            }
        }
    }

    func testValidatedConnectorBaseURL_rejectsRFC1918() {
        for host in ["10.0.0.1", "10.255.255.255", "172.16.0.1", "172.31.255.255", "192.168.0.1", "192.168.1.1"] {
            XCTAssertThrowsError(
                try BurnBarConnectorPlaneService.validatedConnectorBaseURL("https://\(host)")
            ) { error in
                guard case BurnBarConnectorURLValidationError.privateOrReservedIP = error else {
                    return XCTFail("Expected privateOrReservedIP for \(host), got \(error)")
                }
            }
        }
    }

    func testValidatedConnectorBaseURL_rejectsCloudMetadata() {
        XCTAssertThrowsError(
            try BurnBarConnectorPlaneService.validatedConnectorBaseURL("https://169.254.169.254")
        ) { error in
            guard case BurnBarConnectorURLValidationError.cloudMetadataEndpoint = error else {
                return XCTFail("Expected cloudMetadataEndpoint, got \(error)")
            }
        }
    }

    func testValidatedConnectorBaseURL_rejectsGCPMetadata() {
        XCTAssertThrowsError(
            try BurnBarConnectorPlaneService.validatedConnectorBaseURL("https://metadata.google.internal")
        ) { error in
            guard case BurnBarConnectorURLValidationError.cloudMetadataEndpoint = error else {
                return XCTFail("Expected cloudMetadataEndpoint, got \(error)")
            }
        }
    }

    func testValidatedConnectorBaseURL_rejectsLinkLocal() {
        XCTAssertThrowsError(
            try BurnBarConnectorPlaneService.validatedConnectorBaseURL("https://169.254.1.1")
        ) { error in
            guard case BurnBarConnectorURLValidationError.privateOrReservedIP = error else {
                return XCTFail("Expected privateOrReservedIP for 169.254.1.1, got \(error)")
            }
        }
    }

    func testValidatedConnectorBaseURL_rejectsZeroAddress() {
        XCTAssertThrowsError(
            try BurnBarConnectorPlaneService.validatedConnectorBaseURL("https://0.0.0.0")
        ) { error in
            guard case BurnBarConnectorURLValidationError.privateOrReservedIP = error else {
                return XCTFail("Expected privateOrReservedIP for 0.0.0.0, got \(error)")
            }
        }
    }

    func testValidatedConnectorBaseURL_rejectsIPv6Loopback() {
        XCTAssertThrowsError(
            try BurnBarConnectorPlaneService.validatedConnectorBaseURL("https://[::1]")
        ) { error in
            guard case BurnBarConnectorURLValidationError.privateOrReservedIP = error else {
                return XCTFail("Expected privateOrReservedIP for [::1], got \(error)")
            }
        }
    }

    // MARK: - Error descriptions are human-readable

    func testErrorDescriptions() {
        let cases: [BurnBarConnectorURLValidationError] = [
            .emptyURL,
            .invalidURL("garbage"),
            .schemeNotHTTPS("ftp"),
            .missingHost,
            .privateOrReservedIP("10.0.0.1"),
            .cloudMetadataEndpoint,
        ]
        for error in cases {
            XCTAssertFalse(error.description.isEmpty, "Error description should not be empty: \(error)")
        }
    }
}
