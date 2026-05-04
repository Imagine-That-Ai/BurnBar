import UIKit
import FirebaseCore
import FirebaseAppCheck
import GoogleSignIn

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
        guard Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil else {
            print("warning: GoogleService-Info.plist not found; Firebase remains unconfigured.")
            return
        }

        #if DEBUG
        let factory = AppCheckDebugProviderFactory()
        #else
        let factory = OpenBurnBarAppCheckProviderFactory()
        #endif
        AppCheck.setAppCheckProviderFactory(factory)

        FirebaseApp.configure()
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
