import Foundation
#if canImport(Sentry)
import Sentry
#endif

// MARK: - Consent (T-PRV-03)

/// Crash-reporting consent for the iOS app. Default-on (matches the existing
/// internal-distribution posture in `AppDelegate.configureSentryIfAvailable`),
/// but an explicit, user-settable key lets a privacy-conscious user opt out, in
/// which case Sentry is never started.
enum MobileCrashReportingConsent {
    static let defaultsKey = "crashReporting.enabled"

    /// Whether crash reporting is allowed to run. Defaults to `true` when the
    /// key has never been set.
    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: defaultsKey) == nil { return true }
        return defaults.bool(forKey: defaultsKey)
    }
}

// MARK: - Payload scrubber (T-PRV-03)

/// Strips user content (prompts, vault data, tokens, emails, file paths) from
/// Sentry events + breadcrumbs before they leave the device. The string-level
/// redaction is pure so the privacy decision is unit-testable without the Sentry
/// SDK.
enum MobileSentryScrubber {
    static let redactionPlaceholder = "[redacted]"

    /// Substrings whose presence in a key marks the value as sensitive and
    /// therefore fully dropped.
    static let sensitiveKeyFragments: [String] = [
        "token", "secret", "password", "passcode", "key", "auth",
        "credential", "cookie", "session", "email", "prompt", "message",
        "body", "content", "snippet", "vault", "mnemonic", "recovery",
        "address", "phone", "name", "uid", "user"
    ]

    /// Returns `true` if a dictionary key should have its value redacted.
    static func isSensitiveKey(_ key: String) -> Bool {
        let lower = key.lowercased()
        return sensitiveKeyFragments.contains { lower.contains($0) }
    }

    /// Redacts a free-text string: collapses anything that looks like an email,
    /// a bearer/long token, or an absolute file path. Conservative — when in
    /// doubt it redacts.
    static func redact(_ text: String) -> String {
        var result = text
        let patterns = [
            // emails
            #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,
            // bearer / sk- / long opaque tokens (20+ url-safe chars)
            #"(?i)bearer\s+[A-Za-z0-9._-]+"#,
            #"\b[A-Za-z0-9._-]{20,}\b"#,
            // absolute POSIX paths (may carry the username / vault filenames)
            #"(/[Uu]sers/[^\s]+)"#,
            #"(/private/var/[^\s]+)"#
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(
                of: pattern,
                with: redactionPlaceholder,
                options: .regularExpression
            )
        }
        return result
    }

    /// Recursively redacts a `[String: Any]` map: sensitive keys are dropped to
    /// the placeholder, string values are run through `redact`, nested maps /
    /// arrays are walked.
    static func redactDictionary(_ input: [String: Any]) -> [String: Any] {
        var output: [String: Any] = [:]
        for (key, value) in input {
            if isSensitiveKey(key) {
                output[key] = redactionPlaceholder
            } else {
                output[key] = redactValue(value)
            }
        }
        return output
    }

    private static func redactValue(_ value: Any) -> Any {
        switch value {
        case let string as String:
            return redact(string)
        case let dict as [String: Any]:
            return redactDictionary(dict)
        case let array as [Any]:
            return array.map(redactValue)
        default:
            return value
        }
    }

    #if canImport(Sentry)
    /// Scrubs a Sentry event in place and returns it. Returning the event keeps
    /// crash signal (stack traces, OS/app version) while removing user content.
    static func scrub(_ event: Event) -> Event? {
        // Never report identity.
        event.user = nil
        if let message = event.message?.formatted {
            event.message = SentryMessage(formatted: redact(message))
        }
        if let extra = event.extra {
            event.extra = redactDictionary(extra)
        }
        // Drop request bodies / headers / cookies wholesale.
        event.request = nil
        // Redact breadcrumbs carried on the event.
        if let crumbs = event.breadcrumbs {
            event.breadcrumbs = crumbs.compactMap { scrub($0) }
        }
        return event
    }

    /// Scrubs a breadcrumb. Returns `nil` to drop it when it carries nothing
    /// safe to keep.
    static func scrub(_ breadcrumb: Breadcrumb) -> Breadcrumb? {
        if let message = breadcrumb.message {
            breadcrumb.message = redact(message)
        }
        if let data = breadcrumb.data {
            breadcrumb.data = redactDictionary(data)
        }
        return breadcrumb
    }
    #endif
}
