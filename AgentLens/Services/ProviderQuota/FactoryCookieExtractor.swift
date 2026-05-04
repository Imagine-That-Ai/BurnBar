import Foundation

// MARK: - Factory Cookie Helpers

/// Compatibility helpers for Factory session credentials.
///
/// OpenBurnBar intentionally does not read third-party browser cookie stores or
/// Chrome Safe Storage. Factory quota refreshes must use an explicit
/// OpenBurnBar-owned login session, stored under app-owned Keychain keys, or an
/// environment override supplied by the user.
enum FactoryCookieExtractor {

    /// Browser cookie auto-extraction is disabled by design.
    static func extractCookieHeader() -> String? {
        nil
    }

    /// Extracts the `access-token` value from a cookie header.
    /// Can be used as a Bearer token for Factory API calls.
    static func extractBearerToken(from cookieHeader: String) -> String? {
        for pair in cookieHeader.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard parts.count == 2, parts[0] == "access-token" else { continue }
            let value = parts[1]
            return value.isEmpty ? nil : value
        }
        return nil
    }
}
