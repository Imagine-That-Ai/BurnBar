import Foundation

/// Resolves the Amplitude API key without ever committing one. The placeholder
/// `__AMPLITUDE_API_KEY__` is replaced at build time by
/// `scripts/ci/inject-amplitude-config.sh` (mirroring the Sentry DSN pattern);
/// it falls back to the `BURNBAR_AMPLITUDE_API_KEY` env var for local dev.
///
/// When this returns `nil`, the wrapper never constructs the Amplitude client —
/// so a build with no key configured commits nothing and sends nothing, even if
/// the user has granted consent.
enum AnalyticsConfig {
    static var apiKey: String? {
        let injected = "__AMPLITUDE_API_KEY__"
        if !injected.hasPrefix("__"), !injected.isEmpty { return injected }
        if let env = ProcessInfo.processInfo.environment["BURNBAR_AMPLITUDE_API_KEY"],
           !env.isEmpty {
            return env
        }
        return nil
    }
}
