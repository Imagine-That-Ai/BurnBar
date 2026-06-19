import Foundation

/// Resolves the Amplitude API key for the iOS trio without ever committing one.
///
/// Read order (first non-empty wins), mirroring the existing Sentry-DSN posture
/// in `AppDelegate.configureSentryIfAvailable()`:
///   1. `amplitude.apiKey` in the app's Info.plist — the PRIMARY path. The
///      `project.yml` ships this key as the build-setting placeholder
///      `$(BURNBAR_AMPLITUDE_API_KEY)`, which is empty in clean checkouts and is
///      filled by `scripts/ci/inject-amplitude-mobile-config.sh` only when a real
///      key is provided. So an OSS/placeholder build resolves `nil`.
///   2. `amplitude.apiKey` in `GoogleService-Info.plist` — the same fallback slot
///      the Sentry DSN uses for internal distribution builds.
///   3. `BURNBAR_AMPLITUDE_API_KEY` environment variable — local dev only.
///
/// When this returns `nil`, the recorder's transport never constructs the
/// Amplitude client — so a build with no key configured commits nothing and sends
/// nothing, even if the user has granted consent. **No key → dark by construction.**
enum AnalyticsConfig {
    static let infoPlistKey = "amplitude.apiKey"
    static let environmentKey = "BURNBAR_AMPLITUDE_API_KEY"

    static func apiKey(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let fromInfo = nonEmpty(bundle.object(forInfoDictionaryKey: infoPlistKey) as? String) {
            return fromInfo
        }
        if let path = bundle.path(forResource: "GoogleService-Info", ofType: "plist"),
           let dict = NSDictionary(contentsOfFile: path),
           let fromGoogle = nonEmpty(dict[infoPlistKey] as? String) {
            return fromGoogle
        }
        if let fromEnv = nonEmpty(environment[environmentKey]) {
            return fromEnv
        }
        return nil
    }

    /// Trims, rejects empty, and rejects an un-substituted xcconfig placeholder
    /// (a value that is still literally `$(BURNBAR_AMPLITUDE_API_KEY)` or starts
    /// with the `__…__` sentinel) so a placeholder can never be mistaken for a key.
    private static func nonEmpty(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              !trimmed.hasPrefix("$("),
              !trimmed.hasPrefix("__")
        else { return nil }
        return trimmed
    }
}
