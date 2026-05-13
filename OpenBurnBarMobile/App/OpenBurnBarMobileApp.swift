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
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let promptParam = components?.queryItems?.first(where: { $0.name == "prompt" })?.value
        let promptTrimmed = promptParam?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty()

        switch url.host {
        case "dashboard":
            NotificationCenter.default.post(name: .init("NavigateToDashboard"), object: nil)
        case "settings":
            NotificationCenter.default.post(name: .init("ShowSettings"), object: nil)
        case "chat", "hermes":
            // Hermes legacy deep link stays valid. The Assistants tab opens
            // with the Hermes runtime selected. An optional `?prompt=` is
            // stashed for the Hermes auto-submit hook.
            AssistantPendingPrompt.shared.stash(assistant: .hermes, prompt: promptTrimmed)
            NotificationCenter.default.post(name: .init("ShowHermesChat"), object: nil)
            var userInfo: [AnyHashable: Any] = ["runtime": AssistantRuntimeID.hermes.rawValue]
            if let promptTrimmed { userInfo["prompt"] = promptTrimmed }
            NotificationCenter.default.post(
                name: .init("ShowAssistantsTab"),
                object: nil,
                userInfo: userInfo
            )
        case "pi":
            // Direct Pi entry point — symmetry with `burnbar://hermes`.
            AssistantPendingPrompt.shared.stash(assistant: .pi, prompt: promptTrimmed)
            var userInfo: [AnyHashable: Any] = ["runtime": AssistantRuntimeID.pi.rawValue]
            if let promptTrimmed { userInfo["prompt"] = promptTrimmed }
            NotificationCenter.default.post(
                name: .init("ShowAssistantsTab"),
                object: nil,
                userInfo: userInfo
            )
        case "assistants":
            // Generic deep link form: burnbar://assistants?runtime=hermes|pi&prompt=…
            let runtimeRaw = components?.queryItems?.first(where: { $0.name == "runtime" })?.value
            let runtime = AssistantRuntimeID(rawValue: runtimeRaw ?? "") ?? .hermes
            AssistantPendingPrompt.shared.stash(assistant: runtime, prompt: promptTrimmed)
            var userInfo: [AnyHashable: Any] = ["runtime": runtime.rawValue]
            if let promptTrimmed { userInfo["prompt"] = promptTrimmed }
            NotificationCenter.default.post(
                name: .init("ShowAssistantsTab"),
                object: nil,
                userInfo: userInfo
            )
        default:
            break
        }
    }
}

private extension String {
    func nilIfEmpty() -> String? { isEmpty ? nil : self }
}
