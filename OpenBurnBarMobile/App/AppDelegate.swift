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
    /// - Production builds: App Attest (iOS 14+) with DeviceCheck fallback.
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

        #if DEBUG
        let debugToken = AppCheckDebugTokenEnvironment.configureIfAvailable(firebasePlistPath: path)
        let factory: AppCheckProviderFactory = debugToken == nil
            ? PhysicalDebugAppCheckProviderFactory()
            : AppCheckDebugProviderFactory()
        #else
        let factory = OpenBurnBarAppCheckProviderFactory()
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
}

/// App Check provider factory that prefers App Attest (iOS 14+) and falls
/// back to DeviceCheck on devices that don't support attestation.
final class OpenBurnBarAppCheckProviderFactory: NSObject, AppCheckProviderFactory {
    func createProvider(with app: FirebaseApp) -> AppCheckProvider? {
        if #available(iOS 14.0, *) {
            return AppAttestProvider(app: app)
        }
        return DeviceCheckProvider(app: app)
    }
}

/// Physical Debug installs often run with a development provisioning profile
/// that does not include the App Attest entitlement. When no registered debug
/// token is configured, use DeviceCheck so Firestore App Check enforcement can
/// still accept local iPhone/iPad testing.
final class PhysicalDebugAppCheckProviderFactory: NSObject, AppCheckProviderFactory {
    func createProvider(with app: FirebaseApp) -> AppCheckProvider? {
        DeviceCheckProvider(app: app)
    }
}
