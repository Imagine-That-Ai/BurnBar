import FirebaseAppCheck
import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import Foundation
import GoogleSignIn
import OpenBurnBarCore
import OSLog

#if canImport(Sentry)
import Sentry
#endif

/// Firestore is a replication and command plane for the Mac app; the canonical
/// durable state remains in encrypted local SQLite. Keeping Firestore's cache
/// in memory avoids replaying and compacting a second persistent database on
/// every background launch while preserving live listeners and server reads.
enum OpenBurnBarFirestoreCacheMode: Equatable {
    case memoryOnly
}

// Extracted verbatim from AgentLensApp.swift (audit wave 4, item 14).
// One-time process bootstrap called from `OpenBurnBarApp.init`: Firebase +
// App Check + Google Sign-In, Sentry crash reporting (consent-gated), and
// consent-gated Amplitude analytics.
extension OpenBurnBarApp {
    private static var didConfigureFirebase = false
    static let firestoreCacheMode: OpenBurnBarFirestoreCacheMode = .memoryOnly

    /// Wires consent-gated Amplitude analytics and resumes prior opt-ins.
    @MainActor
    static func configureAnalytics() {
        TelemetryService.shared.setForwarder { feature, outcome, durationMs, attributes in
            Task { @MainActor in
                var properties: [String: AnalyticsValue] = [
                    "feature": .string(feature.rawValue),
                    "outcome": .string(outcome.rawValue)
                ]
                if let durationMs {
                    properties["duration_ms_bucket"] = .string(AnalyticsBuckets.durationMs(durationMs))
                }
                for (key, value) in attributes {
                    properties[key] = .string(value)
                }
                Analytics.shared.track(.featureUsed, properties)
            }
        }
        Analytics.shared.startIfConsented()
    }

    @MainActor
    static func configureFirebaseIfAvailable(accountManager: AccountManager) {
        guard !didConfigureFirebase else {
            accountManager.onFirebaseConfigured()
            return
        }
        guard let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
              let options = FirebaseOptions(contentsOfFile: path) else {
            return
        }

        // Configure App Check before FirebaseApp.configure()
        let providerFactory = OpenBurnBarAppCheckProviderFactory()
        AppCheck.setAppCheckProviderFactory(providerFactory)

        FirebaseApp.configure(options: options)
        let firestore = Firestore.firestore()
        let settings = firestore.settings
        switch firestoreCacheMode {
        case .memoryOnly:
            settings.cacheSettings = MemoryCacheSettings()
        }
        firestore.settings = settings
        didConfigureFirebase = true
        if let clientID = FirebaseApp.app()?.options.clientID {
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        }
        accountManager.onFirebaseConfigured()
        #if DEBUG
        signInWithE2ECustomTokenIfNeeded(accountManager: accountManager)
        #endif

        // Validate App Check token when cloud sync is enabled.
        // This is a fail-open warning: the app continues to work but logs a warning.
        Task {
            await validateAppCheckIfNeeded(accountManager: accountManager)
        }
    }

    #if DEBUG
    private static func signInWithE2ECustomTokenIfNeeded(
        accountManager: AccountManager,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let token = environment["OPENBURNBAR_E2E_FIREBASE_CUSTOM_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = environment["OPENBURNBAR_E2E_FIREBASE_EMAIL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = environment["OPENBURNBAR_E2E_FIREBASE_PASSWORD"]
        guard token?.isEmpty == false || (email?.isEmpty == false && password?.isEmpty == false) else {
            return
        }

        let expectedUID = environment["OPENBURNBAR_E2E_FIREBASE_UID"]
        if let expectedUID, Auth.auth().currentUser?.uid == expectedUID {
            return
        }

        Task { @MainActor in
            do {
                let result: AuthDataResult
                if let token, token.isEmpty == false {
                    result = try await Auth.auth().signIn(withCustomToken: token)
                } else if let email, let password {
                    result = try await Auth.auth().signIn(withEmail: email, password: password)
                } else {
                    return
                }
                accountManager.onFirebaseConfigured()
                print("OpenBurnBar E2E Firebase sign-in active for uid \(result.user.uid).")
            } catch {
                print("warning: OpenBurnBar E2E Firebase sign-in failed: \(error.localizedDescription)")
            }
        }
    }
    #endif

    /// Validates that App Check is functional when cloud sync is enabled.
    /// Posts a notification if App Check cannot obtain a token so the UI can warn the user.
    @MainActor
    private static func validateAppCheckIfNeeded(accountManager: AccountManager) async {
        guard accountManager.isCloudSyncEnabled else { return }
        guard Auth.auth().currentUser?.isAnonymous == false else { return }
        do {
            let token = try await AppCheck.appCheck().token(forcingRefresh: false)
            guard !token.token.isEmpty else {
                postAppCheckWarning("App Check returned an empty token.")
                return
            }
        } catch {
            postAppCheckWarning("App Check token fetch failed: \(error.localizedDescription)")
            return
        }
        do {
            try await ComputerUseSecurityCallableClient.bindAppCheckAttestation()
        } catch {
            postAppCheckWarning("App Check attestation bind failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    private static func postAppCheckWarning(_ message: String) {
        os_log("App Check validation warning: %{public}@", log: .default, type: .error, message)
        NotificationCenter.default.post(
            name: .openBurnBarAppCheckValidationFailed,
            object: nil,
            userInfo: ["message": message]
        )
    }

    /// Initialize Sentry crash reporting if a DSN is available.
    /// The DSN is read from the `sentry.dsn` key in Info.plist (injected via
    /// CI for internal builds). If absent, Sentry remains disabled silently.
    #if canImport(Sentry)
    static func configureSentryIfAvailable() {
        guard let finalDsn = resolveSentryDSN(), !finalDsn.trimmingCharacters(in: .whitespaces).isEmpty else {
            // No DSN configured — crash reporting remains disabled silently.
            return
        }
        // T-PRV-03 — consent gate. Crash reporting only runs when the user has
        // not opted out. Default-on matches the existing internal-build posture
        // (and the iOS app), but the explicit key lets a privacy-conscious user
        // disable it, in which case Sentry is never started.
        guard MacCrashReportingConsent.isEnabled() else {
            return
        }
        SentrySDK.start { options in
            options.dsn = finalDsn
            options.environment = "app"
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
            options.releaseName = "openburnbar@\(version)"
            options.tracesSampleRate = 0
            options.enableAutoSessionTracking = true
            // T-PRV-03 — never attach PII (IP, username, email) to events.
            options.sendDefaultPii = false
            // T-PRV-03 — scrub event payloads + breadcrumbs of any user content
            // (prompts, vault data, tokens, file paths, the macOS user's home
            // directory) before they leave the device. Returning nil drops the
            // breadcrumb entirely. Mirrors `MobileSentryScrubber` on iOS.
            options.beforeSend = { event in
                MacSentryScrubber.scrub(event)
            }
            options.beforeBreadcrumb = { breadcrumb in
                MacSentryScrubber.scrub(breadcrumb)
            }
            #if DEBUG
            options.debug = false
            #endif
        }

        // T-PRV-03 — set a non-PII, per-install anonymized user ID so Sentry can
        // correlate crashes per install WITHOUT seeding from `NSFullUserName()`
        // (the macOS account full name is PII and is stable across reinstalls).
        // The seed is a random per-install UUID persisted in the app's own
        // defaults; it never leaves this install and reveals nothing about the
        // human operating the machine.
        let user = User()
        user.userId = MacCrashReportingConsent.perInstallAnonymizedID()
        SentrySDK.setUser(user)
    }
    #else
    @MainActor
    static func configureSentryIfAvailable() {
        // Sentry SDK not linked — skip silently.
    }
    #endif
}
