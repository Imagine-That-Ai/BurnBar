import SwiftUI
import FirebaseCore

@main
struct OpenBurnBarMobileApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            AuthGateView()
                .onOpenURL { url in
                    handleDeepLink(url)
                }
        }
    }

    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "burnbar" else { return }
        switch url.host {
        case "dashboard":
            NotificationCenter.default.post(name: .init("NavigateToDashboard"), object: nil)
        case "settings":
            NotificationCenter.default.post(name: .init("ShowSettings"), object: nil)
        case "chat", "hermes":
            NotificationCenter.default.post(name: .init("ShowHermesChat"), object: nil)
        default:
            break
        }
    }
}
