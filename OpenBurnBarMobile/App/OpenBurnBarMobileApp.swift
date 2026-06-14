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

    init() {
        MobileDataProtectionBootstrap.apply()
    }

    var body: some Scene {
        WindowGroup {
            // T-IOS-02 — app-wide LocalAuthentication (Face ID / passcode) gate.
            // Wraps the whole tree so chat + vault data are never revealed at
            // launch or after backgrounding until the device owner re-auths.
            // Default-on with a graceful fallback (fails open when no passcode
            // is enrolled so the user is never locked out of their own app).
            AppLockGate {
                AuthGateView()
            }
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
                #if DEBUG
                .task {
                    if let url = DebugLaunchURLArguments.consumeBurnBarURL() {
                        handleDeepLink(url)
                    }
                }
                #endif
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
        // T-IOS-07 — sanitize threadId before it reaches the Firestore-scoped
        // chat view. A malformed / path-traversing / overlong value is rejected
        // (treated as nil) so the deep link opens the chat tab unscoped rather
        // than constructing an invalid or attacker-chosen Firestore path.
        let threadTrimmed = DeepLinkThreadID.sanitize(threadParam)

        switch url.host {
        case "dashboard":
            NotificationCenter.default.post(name: .init("NavigateToDashboard"), object: nil)
        case "settings":
            NotificationCenter.default.post(name: .init("ShowSettings"), object: nil)
        case "agent-watch", "agent-live", "computer-use":
            NotificationCenter.default.post(name: .init("ShowAgentWatch"), object: nil)
        #if DEBUG
        case "mercury":
            let connectionID = components?.queryItems?.first(where: { $0.name == "connectionID" })?.value
                ?? components?.queryItems?.first(where: { $0.name == "connectionId" })?.value
            let trimmedConnectionID = connectionID?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty()
            NSLog("OpenBurnBarMercury deep_link_mercury connectionID=\(trimmedConnectionID ?? "nil")")
            var userInfo: [AnyHashable: Any] = [
                "runtime": AssistantRuntimeID.hermes.rawValue,
                "openMercury": true
            ]
            if let trimmedConnectionID {
                userInfo["connectionID"] = trimmedConnectionID
            }
            NotificationCenter.default.post(
                name: .init("ShowAssistantsTab"),
                object: nil,
                userInfo: userInfo
            )
            HermesSquarePendingThreadRoute.openMercuryWithRetries(connectionID: trimmedConnectionID)
        #endif
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

/// T-IOS-07 — validates a `threadId` deep-link parameter before it is used to
/// scope a Firestore query / document path. Mirrors Firestore's document-ID
/// rules and rejects anything that could traverse paths or smuggle an
/// unexpected segment. Pure + `static` so the decision is unit-testable.
enum DeepLinkThreadID {
    /// Firestore caps document IDs at 1500 bytes; we use a conservative,
    /// human-plausible thread-ID ceiling well under that.
    static let maxLength = 256

    /// Returns a sanitized thread ID, or `nil` when the input is missing,
    /// empty, or malformed. Fails closed: an unrecognized value yields `nil`
    /// (open the chat tab unscoped) rather than a guessed/attacker path.
    static func sanitize(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        guard trimmed.utf8.count <= maxLength else { return nil }
        // No path separators (no traversal / extra segments).
        guard !trimmed.contains("/") else { return nil }
        // Reject relative-path tokens.
        guard trimmed != "." && trimmed != ".." else { return nil }
        // Reject Firestore-reserved `__name__`-style IDs.
        guard !(trimmed.hasPrefix("__") && trimmed.hasSuffix("__")) else { return nil }
        // Allowlist: identifiers, dashes, dots — the shapes real thread IDs use.
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.")
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return trimmed
    }
}

#if DEBUG
@MainActor
private enum DebugLaunchURLArguments {
    private static var didConsume = false

    static func consumeBurnBarURL() -> URL? {
        guard !didConsume else { return nil }
        didConsume = true

        return ProcessInfo.processInfo.arguments
            .dropFirst()
            .lazy
            .compactMap(URL.init(string:))
            .first { $0.scheme?.lowercased() == "burnbar" }
    }
}
#endif
