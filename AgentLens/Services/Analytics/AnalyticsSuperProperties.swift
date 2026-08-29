import Foundation

/// The shared properties the wrapper attaches to every event. Call sites never
/// pass these. Locale is region-level only (no fine-grained geo).
struct AnalyticsSuperProperties {
    let platform: String
    let appVersion: String
    let appBuild: String
    let locale: String
    let sessionId: String
    let consentVersion: String

    func asDictionary() -> [String: AnalyticsValue] {
        [
            "product": .string("burnbar"),
            "platform": .string(platform),
            "app_version": .string(appVersion),
            "app_build": .string(appBuild),
            "locale": .string(locale),
            "session_id": .string(sessionId),
            "consent_version": .string(consentVersion)
        ]
    }

    static func macOS(
        bundle: Bundle = .main,
        locale: Locale = .current,
        sessionId: String,
        consentVersion: String = "1"
    ) -> AnalyticsSuperProperties {
        AnalyticsSuperProperties(
            platform: "macos",
            appVersion: bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            appBuild: bundle.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            locale: locale.identifier,
            sessionId: sessionId,
            consentVersion: consentVersion
        )
    }
}
