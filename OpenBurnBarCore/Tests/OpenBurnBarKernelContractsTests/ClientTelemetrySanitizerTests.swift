import Foundation
import XCTest
@testable import OpenBurnBarKernelContracts

final class ClientTelemetrySanitizerTests: XCTestCase {
    func testSanitizesNestedSensitiveFields() {
        let sanitized = ClientTelemetrySanitizer.sanitizeJSONObject([
            "uid": "firebase-user-id",
            "safe": "ok",
            "nested": [
                "path": "/Users/alice/private.txt",
                "count": 3
            ],
            "array": [
                ["authorization": "Bearer secret"],
                "short"
            ]
        ]) as? [String: Any]

        XCTAssertEqual(sanitized?["uid"] as? String, ClientTelemetrySanitizer.redacted)
        XCTAssertEqual(sanitized?["safe"] as? String, "ok")
        let nested = sanitized?["nested"] as? [String: Any]
        XCTAssertEqual(nested?["path"] as? String, ClientTelemetrySanitizer.redacted)
        XCTAssertEqual(nested?["count"] as? Int, 3)
        let array = sanitized?["array"] as? [Any]
        let first = array?.first as? [String: Any]
        XCTAssertEqual(first?["authorization"] as? String, ClientTelemetrySanitizer.redacted)
    }

    func testStableInstallIdentifierDoesNotUseProvidedPII() {
        let suiteName = "ClientTelemetrySanitizerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = ClientTelemetrySanitizer.stableInstallIdentifier(defaults: defaults, key: "installID")
        let second = ClientTelemetrySanitizer.stableInstallIdentifier(defaults: defaults, key: "installID")

        XCTAssertEqual(first, second)
        XCTAssertTrue(first.hasPrefix("install:"))
        XCTAssertFalse(first.contains(NSFullUserName()))
    }

    // Regression for the M-014 context-drop bug: a blanket
    // `sanitizeJSONObject(context) as? [String:[String:Any]]` collapsed and then
    // dropped the ENTIRE context map when a section name was sensitive (e.g.
    // "model"). sanitizeContext must keep every section as a dictionary and only
    // redact sensitive inner values.
    func testSanitizeContextPreservesSectionsAndRedactsInnerValues() {
        let context: [String: [String: Any]] = [
            "device": ["name": "Alice's MacBook", "arch": "arm64"],
            "model": ["family": "m-series", "tier": 1],
            "app": ["build": "123"]
        ]
        let sanitized = ClientTelemetrySanitizer.sanitizeContext(context)
        XCTAssertEqual(Set(sanitized.keys), Set(context.keys), "no section may be dropped")
        XCTAssertEqual(sanitized["device"]?["arch"] as? String, "arm64")
        XCTAssertEqual(sanitized["device"]?["name"] as? String, ClientTelemetrySanitizer.redacted)
        XCTAssertEqual(sanitized["app"]?["build"] as? String, "123")
        // The sensitively-named "model" section must survive as a dictionary.
        XCTAssertNotNil(sanitized["model"])
        XCTAssertEqual(sanitized["model"]?["tier"] as? Int, 1)
    }

    func testSanitizeStringRedactsSensitiveValuePatterns() {
        XCTAssertEqual(ClientTelemetrySanitizer.sanitizeString("sk-live-deadbeef", key: nil), ClientTelemetrySanitizer.redacted)
        XCTAssertEqual(ClientTelemetrySanitizer.sanitizeString("/Users/alice/secret.txt", key: nil), ClientTelemetrySanitizer.redacted)
        XCTAssertEqual(ClientTelemetrySanitizer.sanitizeString("/private/var/tmp/openburnbar.trace", key: nil), ClientTelemetrySanitizer.redacted)
        XCTAssertEqual(ClientTelemetrySanitizer.sanitizeString("contact alice@example.com", key: nil), ClientTelemetrySanitizer.redacted)
        XCTAssertEqual(
            ClientTelemetrySanitizer.sanitizeString("opaque ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789", key: nil),
            ClientTelemetrySanitizer.redacted
        )
        XCTAssertEqual(ClientTelemetrySanitizer.sanitizeString("hello world", key: "greeting"), "hello world")
        let long = String(repeating: "a", count: 900)
        XCTAssertTrue(
            ClientTelemetrySanitizer.sanitizeString(long, key: nil).hasSuffix(ClientTelemetrySanitizer.truncatedValueSuffix),
            "over-long values must be truncated"
        )
    }
}
