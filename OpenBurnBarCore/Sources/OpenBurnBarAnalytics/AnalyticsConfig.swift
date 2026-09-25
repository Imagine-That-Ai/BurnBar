import Foundation

/// Resolves the Amplitude API key without ever committing one.
///
/// Wave 3.4 union of the former macOS / iOS twins. The two platforms provision
/// the key through different mechanisms, so each keeps its own entry point with
/// its twin's exact resolution order (a property and a method cannot share one
/// `apiKey` name in a single type, hence the distinct iOS entry point):
/// - macOS `apiKey`: the `__AMPLITUDE_API_KEY__` sentinel, replaced at build
///   time by `scripts/ci/inject-amplitude-config.sh`, else the
///   `BURNBAR_AMPLITUDE_API_KEY` env var for local dev.
/// - iOS `apiKeyFromBundle(bundle:environment:)`: `amplitude.apiKey` in the
///   app's Info.plist (primary; `$(BURNBAR_AMPLITUDE_API_KEY)` in project.yml),
///   then `GoogleService-Info.plist`, then the env var.
///
/// `nil` keeps analytics dark: the transport never constructs the Amplitude
/// client, so an unkeyed build commits nothing and sends nothing even when the
/// user has granted consent.
public enum AnalyticsConfig {
    public static let infoPlistKey = "amplitude.apiKey"
    public static let environmentKey = "BURNBAR_AMPLITUDE_API_KEY"

    /// macOS resolution: build-time sentinel, else the env var.
    public static var apiKey: String? {
        let injected = "__AMPLITUDE_API_KEY__"
        if !injected.hasPrefix("__"), !injected.isEmpty { return injected }
        if let env = ProcessInfo.processInfo.environment[environmentKey],
           !env.isEmpty {
            return env
        }
        return nil
    }

    /// iOS-trio resolution (first non-empty wins): app Info.plist, then
    /// `GoogleService-Info.plist`, then the env var. Parameters are injectable
    /// for tests; production call sites use the defaults.
    public static func apiKeyFromBundle(
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

    /// Trims, rejects empty, and rejects an un-substituted placeholder (still
    /// literally `$(…)` or a `__…__` sentinel) so one can never pass as a key.
    private static func nonEmpty(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              !trimmed.hasPrefix("$("),
              !trimmed.hasPrefix("__")
        else { return nil }
        return trimmed
    }
}
