import SwiftUI
import FirebaseCore
import GoogleSignIn
import OpenBurnBarCore

@main
struct OpenBurnBarMobileApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var customization = AppCustomization.shared
    @StateObject private var agentNotifications = AgentReplyNotificationService.shared

    // Bound to ThemeSettingsView's "Appearance Mode" picker. Values match
    // the picker tags: "system" (no override), "light", "dark".
    @AppStorage("preferredAppearance") private var preferredAppearance: String = "system"

    private var appearanceOverride: ColorScheme? {
        switch preferredAppearance {
        case "light": return .light
        case "dark":  return .dark
        default:      return nil
        }
    }

    var body: some Scene {
        WindowGroup {
            AuthGateView()
                .tint(customization.themePalette.tintColor)
                .preferredColorScheme(appearanceOverride)
                .overlay(alignment: .top) {
                    if let banner = agentNotifications.banner {
                        AgentReplyNotificationBannerView(
                            banner: banner,
                            onOpen: { agentNotifications.open(banner) },
                            onDismiss: { agentNotifications.dismissBanner() }
                        )
                    }
                }
                .onOpenURL { url in
                    handleDeepLink(url)
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    agentNotifications.updateLifecycle("active")
                    // Sync any snippets the user added straight from the keyboard.
                    Task { await MobileTextExpansionStore.ingestKeyboardInboxIfNeeded() }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                    agentNotifications.updateLifecycle("inactive")
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                    agentNotifications.updateLifecycle("background")
                }
        }
    }

    private func handleDeepLink(_ url: URL) {
        if GIDSignIn.sharedInstance.handle(url) {
            return
        }
        guard isOpenBurnBarAppDeepLink(url) else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let promptParam = components?.queryItems?.first(where: { $0.name == "prompt" })?.value
        let threadParam = components?.queryItems?.first(where: { $0.name == "threadId" })?.value
            ?? components?.queryItems?.first(where: { $0.name == "threadID" })?.value
        let promptTrimmed = promptParam?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty()
        let threadTrimmed = threadParam?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty()

        switch url.host {
        case "dashboard":
            NotificationCenter.default.post(name: .init("NavigateToDashboard"), object: nil)
        case "settings":
            NotificationCenter.default.post(name: .init("ShowSettings"), object: nil)
        case "agent-watch", "agent-live", "computer-use":
            NotificationCenter.default.post(name: .init("ShowAgentWatch"), object: nil)
        case "chat", "hermes":
            // Hermes legacy deep link stays valid. The Assistants tab opens
            // with the Hermes runtime selected. An optional `?prompt=` is
            // stashed for user confirmation before sending.
            AssistantPendingPrompt.shared.stash(assistant: .hermes, prompt: promptTrimmed, source: .deepLink)
            NotificationCenter.default.post(name: .init("ShowHermesChat"), object: nil)
            var userInfo: [AnyHashable: Any] = ["runtime": AssistantRuntimeID.hermes.rawValue]
            if let promptTrimmed { userInfo["prompt"] = promptTrimmed }
            if let threadTrimmed { userInfo["threadId"] = threadTrimmed }
            NotificationCenter.default.post(
                name: .init("ShowAssistantsTab"),
                object: nil,
                userInfo: userInfo
            )
        case "pi":
            // Direct Pi entry point — symmetry with `burnbar://hermes`.
            AssistantPendingPrompt.shared.stash(assistant: .pi, prompt: promptTrimmed, source: .deepLink)
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
                ?? url.pathComponents.dropFirst().first
            let runtime = AssistantRuntimeID(rawValue: runtimeRaw ?? "") ?? .hermes
            AssistantPendingPrompt.shared.stash(assistant: runtime, prompt: promptTrimmed, source: .deepLink)
            var userInfo: [AnyHashable: Any] = ["runtime": runtime.rawValue]
            if let promptTrimmed { userInfo["prompt"] = promptTrimmed }
            if let threadTrimmed { userInfo["threadId"] = threadTrimmed }
            NotificationCenter.default.post(
                name: .init("ShowAssistantsTab"),
                object: nil,
                userInfo: userInfo
            )
        case "insights":
            // burnbar://insights/{slug} — open the Insights tab scoped to
            // the slug ("all" → aggregate, otherwise an agent persistedToken).
            let slug = url.pathComponents.dropFirst().first ?? ""
            NotificationCenter.default.post(
                name: .init("ShowInsightsTab"),
                object: nil,
                userInfo: ["slug": slug]
            )
        default:
            break
        }
    }
}

private func isOpenBurnBarAppDeepLink(_ url: URL) -> Bool {
    switch url.scheme?.lowercased() {
    case "burnbar", "openburnbar":
        return true
    default:
        return false
    }
}

private extension String {
    func nilIfEmpty() -> String? { isEmpty ? nil : self }
}
