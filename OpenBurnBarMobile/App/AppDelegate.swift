import UIKit
import FirebaseCore
import FirebaseAppCheck
import GoogleSignIn
import OpenBurnBarCore

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        configureFirebase()
        return true
    }

    /// Forward OAuth callback URLs to GoogleSignIn. Without this, the Google
    /// sign-in flow opens Safari, returns to the app, and silently never
    /// completes the continuation in `LiveAuthGateway.signInWithGoogle()`.
    func application(_ app: UIApplication,
                     open url: URL,
                     options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        GIDSignIn.sharedInstance.handle(url)
    }

    /// Configures Firebase + App Check.
    ///
    /// `AppCheck.setAppCheckProviderFactory(_:)` MUST be invoked **before**
    /// `FirebaseApp.configure()` so the very first Firestore call presents a
    /// valid attestation token. Otherwise the project's App Check enforcement
    /// will block every read (`App Check blocked` in Sync diagnostics).
    ///
    /// - Internal distribution builds: when `OpenBurnBarUseDebugAppCheck` is
    ///   present in Info.plist, use the App Check debug provider with a
    ///   pre-registered token. This keeps Firestore enforcement enabled for
    ///   TestFlight/App Distribution channels while Apple/Play attestation is
    ///   not available.
    /// - Production builds: DeviceCheck. App Attest is stronger, but it must
    ///   also be enabled on the Apple Bundle ID/provisioning profile before the
    ///   entitlement can be shipped. DeviceCheck keeps enforced Firestore App
    ///   Check working for TestFlight while that Apple capability is managed.
    /// - Debug builds: the App Check debug provider so a registered debug
    ///   token from `firebase.console -> App Check -> iOS app` is accepted.
    private func configureFirebase() {
        guard let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") else {
            print("warning: GoogleService-Info.plist not found; Firebase remains unconfigured.")
            return
        }
        guard Self.googleServiceInfoLooksConfigured(at: path) else {
            print("warning: GoogleService-Info.plist is a placeholder or invalid; Firebase remains unconfigured.")
            return
        }

        let useDebugProvider = Self.useDebugAppCheckProvider()
            || AppCheckDebugTokenEnvironment.token(inPlistAt: path) != nil
        let factory: AppCheckProviderFactory
        #if DEBUG
        _ = AppCheckDebugTokenEnvironment.configureIfAvailable(firebasePlistPath: path)
        factory = AppCheckDebugProviderFactory()
        #else
        if useDebugProvider {
            _ = AppCheckDebugTokenEnvironment.configureIfAvailable(firebasePlistPath: path)
            factory = AppCheckDebugProviderFactory()
        } else {
            factory = OpenBurnBarAppCheckProviderFactory()
        }
        #endif
        AppCheck.setAppCheckProviderFactory(factory)

        FirebaseApp.configure()
    }

    private static func googleServiceInfoLooksConfigured(at path: String) -> Bool {
        guard
            let plist = NSDictionary(contentsOfFile: path) as? [String: Any],
            let googleAppID = plist["GOOGLE_APP_ID"] as? String
        else {
            return false
        }

        // Firebase throws an Objective-C exception for placeholder or malformed
        // app IDs, which Swift cannot catch. Validate before calling configure
        // so clean OSS checkouts and tests degrade to auth-disabled mode.
        return googleAppID.range(
            of: #"^1:[0-9]+:ios:[A-Za-z0-9]+$"#,
            options: .regularExpression
        ) != nil
    }

    private static func useDebugAppCheckProvider(
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if truthy(environment["OPENBURNBAR_USE_DEBUG_APP_CHECK"]) {
            return true
        }
        return truthy(infoDictionary?["OpenBurnBarUseDebugAppCheck"])
    }

    private static func truthy(_ raw: Any?) -> Bool {
        switch raw {
        case let value as Bool:
            return value
        case let value as String:
            return ["1", "true", "yes", "y"].contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        default:
            return false
        }
    }
}

/// App Check provider factory for release builds.
final class OpenBurnBarAppCheckProviderFactory: NSObject, AppCheckProviderFactory {
    func createProvider(with app: FirebaseApp) -> AppCheckProvider? {
        return DeviceCheckProvider(app: app)
    }
}
