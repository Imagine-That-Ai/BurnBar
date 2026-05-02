import UIKit
import FirebaseCore
import FirebaseAppCheck

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        configureFirebase()
        return true
    }

    private func configureFirebase() {
        guard Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil else {
            print("warning: GoogleService-Info.plist not found; Firebase remains unconfigured.")
            return
        }
        FirebaseApp.configure()
    }
}
