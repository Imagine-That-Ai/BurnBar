import SwiftUI
import FirebaseCore
import GoogleSignIn
import OpenBurnBarCore

@MainActor
enum HermesGatewayPairingDeepLink {
    static let notificationName = Notification.Name("OpenHermesGatewayPairing")
    static let codeUserInfoKey = "code"

    private static var pendingCode: String?

    static func open(code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pendingCode = trimmed
        NotificationCenter.default.post(
            name: notificationName,
            object: nil,
            userInfo: [codeUserInfoKey: trimmed]
        )
    }

    static func code(from notification: Notification) -> String? {
        (notification.userInfo?[codeUserInfoKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty()
    }

    static func consumePendingCode() -> String? {
        let code = pendingCode
        pendingCode = nil
        return code
    }

    static func pairingCode(from url: URL) -> String? {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let code = components?.queryItems?
            .first { ["code", "userCode", "user_code"].contains($0.name) }?
            .value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty()
        guard let code else { return nil }

        let scheme = url.scheme?.lowercased()
        let host = url.host?.lowercased()
        let path = url.path.lowercased()

        if scheme == "https",
           ["burnbar.ai", "www.burnbar.ai"].contains(host ?? ""),
           path == "/hermes/connect" {
            return code
        }

        guard scheme == "burnbar" else { return nil }
        if ["hermes-gateway", "gateway", "hermes-connect"].contains(host ?? "") {
            return code
        }
        if host == "hermes", ["/gateway", "/connect"].contains(path) {
            return code
        }
        return nil
    }
}

@main
struct OpenBurnBarMobileApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var customization = AppCustomization.shared
    @StateObject private var agentNotifications = AgentReplyNotificationService.shared

    /// Composition root (see `AppServices`). Built once here and exposed to
    /// the whole view tree via `\.appServices`. The value is an empty struct
    /// whose accessors resolve the existing long-lived singletons lazily, so
    /// creating it has no side effects and changes no launch ordering.
    private let appServices = AppServices()

    // Bound to ThemeSettingsView's "Appearance Mode" picker. Values match
    // the picker tags: "system" (no override), "light", "dark".
    @AppStorage("preferredAppearance") private var preferredAppearance: String = "system"

    // The Editorial / Paper skin (see `AppSkin`). When active it is light-locked
    // and accented with coral, overriding the appearance picker. Toggling it
    // changes `preferredColorScheme`, which forces a trait change so the
    // skin-aware design tokens re-resolve immediately.
    @AppStorage(AppSkin.storageKey) private var appSkin: AppSkin = .aurora

    private var appearanceOverride: ColorScheme? {
        if appSkin == .editorial { return .light }
        switch preferredAppearance {
        case "light": return .light
        case "dark":  return .dark
        default:      return nil
        }
    }

    private var resolvedTint: Color? {
        appSkin == .editorial ? MobileTheme.ember : customization.themePalette.tintColor
    }

    var body: some Scene {
        WindowGroup {
            AuthGateView()
                .environment(\.appServices, appServices)
                .tint(resolvedTint)
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
        if let pairingCode = HermesGatewayPairingDeepLink.pairingCode(from: url) {
            HermesGatewayPairingDeepLink.open(code: pairingCode)
            return
        }
        guard url.scheme == "burnbar" else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let threadParam = components?.queryItems?.first(where: { $0.name == "threadId" })?.value
            ?? components?.queryItems?.first(where: { $0.name == "threadID" })?.value
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
            // Public URL handlers navigate only. Prompt-bearing deep links are
            // never auto-submitted; in-process AppIntents may still stash prompts.
            AssistantPendingThread.shared.stash(assistant: .hermes, threadID: threadTrimmed)
            NotificationCenter.default.post(name: .init("ShowHermesChat"), object: nil)
            var userInfo: [AnyHashable: Any] = ["runtime": AssistantRuntimeID.hermes.rawValue]
            if let threadTrimmed { userInfo["threadId"] = threadTrimmed }
            NotificationCenter.default.post(
                name: .init("ShowAssistantsTab"),
                object: nil,
                userInfo: userInfo
            )
        case "pi":
            // Direct Pi entry point — symmetry with `burnbar://hermes`.
            AssistantPendingThread.shared.stash(assistant: .pi, threadID: threadTrimmed)
            var userInfo: [AnyHashable: Any] = ["runtime": AssistantRuntimeID.pi.rawValue]
            if let threadTrimmed { userInfo["threadId"] = threadTrimmed }
            NotificationCenter.default.post(
                name: .init("ShowAssistantsTab"),
                object: nil,
                userInfo: userInfo
            )
        case "assistants":
            // Generic deep link form: burnbar://assistants?runtime=hermes|pi.
            // `prompt` query values are ignored by public URL handling.
            let runtimeRaw = components?.queryItems?.first(where: { $0.name == "runtime" })?.value
                ?? url.pathComponents.dropFirst().first
            let runtime = AssistantRuntimeID(rawValue: runtimeRaw ?? "") ?? .hermes
            AssistantPendingThread.shared.stash(assistant: runtime, threadID: threadTrimmed)
            var userInfo: [AnyHashable: Any] = ["runtime": runtime.rawValue]
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

private extension String {
    func nilIfEmpty() -> String? { isEmpty ? nil : self }
}
