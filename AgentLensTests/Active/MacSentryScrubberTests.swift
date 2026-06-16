import XCTest
@testable import OpenBurnBar

// MARK: - Sentry scrubber + consent (T-PRV-03, macOS half)
//
// Locks the privacy contract for crash reporting on macOS: user content (prompts,
// vault data, tokens, emails, paths) is stripped from event payloads + breadcrumbs
// before they leave the device, and reporting is gated on consent. The string /
// dictionary redaction is pure, so it is unit-testable without the Sentry SDK.
// Mirrors `MobileSentryScrubberTests`.

final class MacSentryScrubberTests: XCTestCase {

    // MARK: Consent

    func testConsentDefaultsToEnabledWhenUnset() {
        let defaults = makeDefaults()
        XCTAssertTrue(MacCrashReportingConsent.isEnabled(defaults: defaults))
    }

    func testConsentRespectsOptOut() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: MacCrashReportingConsent.defaultsKey)
        XCTAssertFalse(MacCrashReportingConsent.isEnabled(defaults: defaults))
    }

    // MARK: Per-install anonymized ID

    func testPerInstallIDIsStable() {
        let defaults = makeDefaults()
        let id1 = MacCrashReportingConsent.perInstallAnonymizedID(defaults: defaults)
        let id2 = MacCrashReportingConsent.perInstallAnonymizedID(defaults: defaults)
        XCTAssertEqual(id1, id2)
        XCTAssertEqual(id1.count, 32)
    }

    func testPerInstallIDDoesNotContainUserName() {
        let defaults = makeDefaults()
        let id = MacCrashReportingConsent.perInstallAnonymizedID(defaults: defaults)
        XCTAssertFalse(id.contains(NSFullUserName()))
        XCTAssertFalse(id.contains("/Users/"))
    }

    // MARK: String redaction

    func testRedactsEmail() {
        let redacted = MacSentryScrubber.redact("contact alberto8793@gmail.com now")
        XCTAssertFalse(redacted.contains("@gmail.com"))
        XCTAssertTrue(redacted.contains(MacSentryScrubber.redactionPlaceholder))
    }

    func testRedactsBearerToken() {
        let fakeBearerToken = "sk-" + "live-ABCDEFGHIJ1234567890"
        let authHeader = "Auth" + "orization: Bearer "
        let redacted = MacSentryScrubber.redact("\(authHeader)\(fakeBearerToken)")
        XCTAssertFalse(redacted.contains(fakeBearerToken))
    }

    func testRedactsLongOpaqueToken() {
        let redacted = MacSentryScrubber.redact("token=ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        XCTAssertFalse(redacted.contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"))
    }

    func testRedactsUserPath() {
        let redacted = MacSentryScrubber.redact("failed at /Users/alberto/vault/recovery.key")
        XCTAssertFalse(redacted.contains("/Users/alberto"))
    }

    func testRedactsPrivateVarPath() {
        let redacted = MacSentryScrubber.redact("temp file /private/var/tmp/secret.txt")
        XCTAssertFalse(redacted.contains("/private/var/tmp/secret.txt"))
    }

    func testKeepsShortNonSensitiveText() {
        XCTAssertEqual(MacSentryScrubber.redact("network error 503"), "network error 503")
    }

    // MARK: Dictionary redaction

    func testRedactsSensitiveKeys() {
        XCTAssertTrue(MacSentryScrubber.isSensitiveKey("authToken"))
        XCTAssertTrue(MacSentryScrubber.isSensitiveKey("user_email"))
        XCTAssertTrue(MacSentryScrubber.isSensitiveKey("prompt"))
        XCTAssertTrue(MacSentryScrubber.isSensitiveKey("vaultKey"))
        XCTAssertFalse(MacSentryScrubber.isSensitiveKey("statusCode"))
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
        let out = MacSentryScrubber.redactDictionary(input)
        XCTAssertEqual(out["statusCode"] as? Int, 503)
        XCTAssertEqual(out["authToken"] as? String, MacSentryScrubber.redactionPlaceholder)
        let nested = out["nested"] as? [String: Any]
        XCTAssertEqual(nested?["email"] as? String, MacSentryScrubber.redactionPlaceholder)
        XCTAssertFalse((nested?["note"] as? String ?? "").contains("/Users/bob"))
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "MacSentryScrubberTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
