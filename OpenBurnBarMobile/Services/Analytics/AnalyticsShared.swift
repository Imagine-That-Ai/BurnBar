import Foundation
import UIKit
import OpenBurnBarAnalytics

extension AnalyticsConsentStore {
    /// The single app-wide consent store for the iOS host. The first-run prompt
    /// and the Settings toggle mutate this; `MobileAnalytics.shared` reads it on
    /// every call. Persisted to the **shared App Group** so the widget + keyboard
    /// extensions read the same decision (see `AnalyticsConsentStore`).
    @MainActor
    static let shared = AnalyticsConsentStore()
}

/// The iOS host's single app-wide analytics surface. Named `MobileAnalytics` to
/// avoid colliding with the package's `Analytics` type at call sites. Every
/// instrumentation call goes through `MobileAnalytics.shared.track(...)`; nothing
/// touches the Amplitude SDK directly. Built once, lazily — the SDK is not
/// constructed until the recorder's `start()` runs (only after consent is granted
/// AND a key is present).
@MainActor
enum MobileAnalytics {
    private static let launchMarkerKey = "hasLaunchedBefore"
    private static var sessionSpineEmitted = false
    static let currentSessionIsFirstLaunch: Bool = !UserDefaults.standard.bool(forKey: launchMarkerKey)

    static let shared: Analytics = {
        let sessionId = UUID().uuidString
        let transport = AmplitudeTransport(
            apiKey: AnalyticsConfig.apiKey(),
            deviceId: AnalyticsIdentity.deviceId()
        )
        return Analytics(
            consent: AnalyticsConsentStore.shared,
            transport: transport,
            superProperties: { superProperties(sessionId: sessionId).asDictionary() },
            // On a fresh grant, re-identify if a user is ALREADY signed in (they
            // opted in after signing in, so no auth-state change fires to set the
            // id). Reads the live Firebase uid and returns its STABLE HASH — never
            // the raw uid; `nil` when signed out. Same hash AuthStore uses on
            // auth-state changes, so the identity matches across both paths.
            authenticatedUserId: {
                AuthRepository.shared.currentUserUID.flatMap(
                    AnalyticsUserIdentity.amplitudeUserId(forAccountUID:)
                )
            }
        )
    }()

    /// iPad reports `platform: ipados`; iPhone (and anything else) reports `ios`,
    /// so the funnels can be split without a second binary.
    private static func superProperties(sessionId: String) -> AnalyticsSuperProperties {
        if UIDevice.current.userInterfaceIdiom == .pad {
            return .iPadOS(sessionId: sessionId)
        }
        return .iOS(sessionId: sessionId)
    }

    /// Flip consent + notify the recorder in one call (used by the prompt + toggle).
    static func setConsent(granted: Bool) {
        if granted {
            AnalyticsConsentStore.shared.grant()
            shared.consentDidChange()
            trackSessionStartIfConsented()
        } else {
            AnalyticsConsentStore.shared.revoke()
            shared.consentDidChange()
        }
    }

    static func trackSessionStartIfConsented() {
        guard AnalyticsConsentStore.shared.isGranted else { return }
        guard !sessionSpineEmitted else { return }
        sessionSpineEmitted = true
        shared.track(.appSessionStarted, [
            "is_first_launch": .bool(currentSessionIsFirstLaunch),
            "cold_start": .bool(true)
        ])
        shared.track(.appOpened, [
            "is_first_launch": .bool(currentSessionIsFirstLaunch),
            "cold_start": .bool(true),
            "surface": .string("ios")
        ])
        if currentSessionIsFirstLaunch {
            shared.track(.installStarted, ["surface": .string("ios")])
        }
    }

    static func trackSessionSpineAfterFirstGrant() {
        trackSessionStartIfConsented()
        shared.track(.screenViewed, [
            "surface": .string("app"),
            "is_first_view": .bool(true)
        ])
    }

    static func markLaunchSeen() {
        UserDefaults.standard.set(true, forKey: launchMarkerKey)
    }
}
