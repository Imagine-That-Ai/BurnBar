import SwiftUI
import FirebaseCore
import OpenBurnBarCore

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
            // Hermes legacy deep link stays valid. The Assistants tab opens
            // with the Hermes runtime selected.
            NotificationCenter.default.post(name: .init("ShowHermesChat"), object: nil)
            NotificationCenter.default.post(
                name: .init("ShowAssistantsTab"),
                object: nil,
                userInfo: ["runtime": AssistantRuntimeID.hermes.rawValue]
            )
        case "assistants":
            // New deep link form: burnbar://assistants?runtime=hermes|pi
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let runtime = components?.queryItems?.first(where: { $0.name == "runtime" })?.value
            NotificationCenter.default.post(
                name: .init("ShowAssistantsTab"),
                object: nil,
                userInfo: ["runtime": runtime ?? "hermes"]
            )
        default:
            break
        }
    }
}
