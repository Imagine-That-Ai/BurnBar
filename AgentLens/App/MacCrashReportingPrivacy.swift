import Foundation

#if canImport(Sentry)
import Sentry
#endif

// Extracted verbatim from AgentLensApp.swift (audit wave 4, item 14).
// T-PRV-03 crash-reporting privacy: consent gate + per-install anonymized
// id, and the Sentry event/breadcrumb scrubber.

// MARK: - Crash-reporting consent (T-PRV-03)

/// Crash-reporting consent for the macOS app. Default-on (matches the existing
/// internal-distribution posture in `configureSentryIfAvailable` and the iOS
/// `MobileCrashReportingConsent`), but an explicit, user-settable key lets a
/// privacy-conscious user opt out, in which case Sentry is never started.
///
/// Also owns the non-PII per-install identifier that replaces the old
/// `NSFullUserName()` seed: a random UUID persisted in the app's own defaults,
/// hashed to a stable opaque hex id. It carries no account name, no email, and
/// nothing derivable about the human operating the Mac.
enum MacCrashReportingConsent {
    static let defaultsKey = "crashReporting.enabled"
    static let installIDDefaultsKey = "crashReporting.perInstallID"

    /// Whether crash reporting is allowed to run. Defaults to `true` when the
    /// key has never been set.
    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: defaultsKey) == nil { return true }
        return defaults.bool(forKey: defaultsKey)
    }

    /// Stable non-PII per-install id seeded from this install's own random UUID.
    /// Pure with injected defaults so the privacy property is unit-testable.
    static func perInstallAnonymizedID(defaults: UserDefaults = .standard) -> String {
        let seed: String
        if let stored = defaults.string(forKey: installIDDefaultsKey),
           !stored.isEmpty {
            seed = stored
        } else {
            let created = UUID().uuidString
            defaults.set(created, forKey: installIDDefaultsKey)
            seed = created
        }
        let bundleID = Bundle.main.bundleIdentifier ?? "com.openburnbar.app"
        let data = (bundleID + seed).data(using: .utf8) ?? Data()
        return String(data.map { String(format: "%02x", $0) }.joined().prefix(32))
    }
}

// MARK: - Sentry payload scrubber (T-PRV-03)

/// Strips user content from Sentry events + breadcrumbs before they leave device.
/// The pure redaction logic mirrors `MobileSentryScrubber`.
enum MacSentryScrubber {
    static let redactionPlaceholder = "[redacted]"

    /// Key fragments whose values are always fully redacted.
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

    /// Redacts email-like strings, bearer/long tokens, and absolute paths.
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

    /// Recursively redacts maps, nested maps, and arrays.
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
    /// Keeps crash signal while removing user content.
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

    /// Redacts breadcrumb message/data while keeping crash-correlation signal.
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
