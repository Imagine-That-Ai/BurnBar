import XCTest
@testable import OpenBurnBarMobile

// MARK: - Sentry scrubber + consent (T-PRV-03, iOS half)
//
// Locks the privacy contract for crash reporting: user content (prompts, vault
// data, tokens, emails, paths) is stripped from event payloads + breadcrumbs
// before they leave the device, and reporting is gated on consent. The string /
// dictionary redaction is pure, so it is testable without the Sentry SDK.

final class MobileSentryScrubberTests: XCTestCase {

    // MARK: Consent

    func testConsentDefaultsToEnabledWhenUnset() {
        let defaults = makeDefaults()
        XCTAssertTrue(MobileCrashReportingConsent.isEnabled(defaults: defaults))
    }

    func testConsentRespectsOptOut() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: MobileCrashReportingConsent.defaultsKey)
        XCTAssertFalse(MobileCrashReportingConsent.isEnabled(defaults: defaults))
    }

    // MARK: String redaction

    func testRedactsEmail() {
        let redacted = MobileSentryScrubber.redact("contact alberto8793@gmail.com now")
        XCTAssertFalse(redacted.contains("@gmail.com"))
        XCTAssertTrue(redacted.contains(MobileSentryScrubber.redactionPlaceholder))
    }

    func testRedactsBearerToken() {
        let redacted = MobileSentryScrubber.redact("Authorization: Bearer sk-live-ABCDEFGHIJ1234567890")
        XCTAssertFalse(redacted.contains("sk-live-ABCDEFGHIJ1234567890"))
    }

    func testRedactsLongOpaqueToken() {
        let redacted = MobileSentryScrubber.redact("token=ABCDEFGHIJKLMNOPQRSTUVWXYZ012345")
        XCTAssertFalse(redacted.contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ012345"))
    }

    func testRedactsUserPath() {
        let redacted = MobileSentryScrubber.redact("failed at /Users/alberto/vault/recovery.key")
        XCTAssertFalse(redacted.contains("/Users/alberto"))
    }

    func testKeepsShortNonSensitiveText() {
        XCTAssertEqual(MobileSentryScrubber.redact("network error 503"), "network error 503")
    }

    // MARK: Dictionary redaction

    func testRedactsSensitiveKeys() {
        XCTAssertTrue(MobileSentryScrubber.isSensitiveKey("authToken"))
        XCTAssertTrue(MobileSentryScrubber.isSensitiveKey("user_email"))
        XCTAssertTrue(MobileSentryScrubber.isSensitiveKey("prompt"))
        XCTAssertTrue(MobileSentryScrubber.isSensitiveKey("vaultKey"))
        XCTAssertFalse(MobileSentryScrubber.isSensitiveKey("statusCode"))
    }

    func testRedactDictionaryDropsSensitiveValuesAndWalksNested() {
        let input: [String: Any] = [
            "statusCode": 503,
            "authToken": "supersecret",
            "nested": [
                "email": "x@y.com",
                "note": "ping /Users/bob/secret"
            ]
        ]
        let out = MobileSentryScrubber.redactDictionary(input)
        XCTAssertEqual(out["statusCode"] as? Int, 503)
        XCTAssertEqual(out["authToken"] as? String, MobileSentryScrubber.redactionPlaceholder)
        let nested = out["nested"] as? [String: Any]
        XCTAssertEqual(nested?["email"] as? String, MobileSentryScrubber.redactionPlaceholder)
        XCTAssertFalse((nested?["note"] as? String ?? "").contains("/Users/bob"))
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "MobileSentryScrubberTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
