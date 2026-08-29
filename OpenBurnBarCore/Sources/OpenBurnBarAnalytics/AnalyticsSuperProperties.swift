import Foundation

/// The shared properties the wrapper attaches to every event. Call sites never
/// pass these. Locale is region-level only (no fine-grained geo). Ported from
/// `AgentLens/Services/Analytics/AnalyticsSuperProperties.swift` with iOS/iPad,
/// widget, and keyboard platform factories.
public struct AnalyticsSuperProperties {
    public let platform: String
    public let appVersion: String
    public let appBuild: String
    public let locale: String
    public let sessionId: String
    public let consentVersion: String

    public init(
        platform: String,
        appVersion: String,
        appBuild: String,
        locale: String,
        sessionId: String,
        consentVersion: String
    ) {
        self.platform = platform
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.locale = locale
        self.sessionId = sessionId
        self.consentVersion = consentVersion
    }

    public func asDictionary() -> [String: AnalyticsValue] {
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

    /// Resolve the marketing version + build from a bundle (defaults to `.main`).
    private static func version(_ bundle: Bundle) -> (String, String) {
        let v = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let b = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        return (v, b)
    }

    /// iPhone app surface (`platform: ios`).
    public static func iOS(
        bundle: Bundle = .main,
        locale: Locale = .current,
        sessionId: String,
        consentVersion: String = "1"
    ) -> AnalyticsSuperProperties {
        let (v, b) = version(bundle)
        return AnalyticsSuperProperties(
            platform: "ios", appVersion: v, appBuild: b,
            locale: locale.identifier, sessionId: sessionId, consentVersion: consentVersion
        )
    }

    /// iPad app surface (`platform: ipados`). Same binary, distinct platform value
    /// so the iPad funnel can be split from iPhone.
    public static func iPadOS(
        bundle: Bundle = .main,
        locale: Locale = .current,
        sessionId: String,
        consentVersion: String = "1"
    ) -> AnalyticsSuperProperties {
        let (v, b) = version(bundle)
        return AnalyticsSuperProperties(
            platform: "ipados", appVersion: v, appBuild: b,
            locale: locale.identifier, sessionId: sessionId, consentVersion: consentVersion
        )
    }

    /// WidgetKit extension surface (`platform: widget`).
    public static func widget(
        bundle: Bundle = .main,
        locale: Locale = .current,
        sessionId: String,
        consentVersion: String = "1"
    ) -> AnalyticsSuperProperties {
        let (v, b) = version(bundle)
        return AnalyticsSuperProperties(
            platform: "widget", appVersion: v, appBuild: b,
            locale: locale.identifier, sessionId: sessionId, consentVersion: consentVersion
        )
    }

    /// Keyboard extension surface (`platform: keyboard`).
    public static func keyboard(
        bundle: Bundle = .main,
        locale: Locale = .current,
        sessionId: String,
        consentVersion: String = "1"
    ) -> AnalyticsSuperProperties {
        let (v, b) = version(bundle)
        return AnalyticsSuperProperties(
            platform: "keyboard", appVersion: v, appBuild: b,
            locale: locale.identifier, sessionId: sessionId, consentVersion: consentVersion
        )
    }
}
