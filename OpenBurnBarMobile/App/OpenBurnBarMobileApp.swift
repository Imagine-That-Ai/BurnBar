import SwiftUI
import FirebaseCore

@main
struct OpenBurnBarMobileApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            AuthGateView()
        }
    }
}
