import SwiftUI
import FirebaseCore
import GoogleSignIn
import OpenBurnBarCore

#if DEBUG && GSTACK_IOS_QA
import DebugBridgeCore
import DebugBridgeUI
#endif

enum MobileDebugBridgeBuild {
#if DEBUG && GSTACK_IOS_QA
    static let isEnabled = true
#else
    static let isEnabled = false
#endif
}

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

    /// Screenshot-only deep link: when launched with
    /// `-OpenBurnBarScreenshotRoute theme`, present the Appearance / Theme page
    /// (which hosts the swarm-substrate picker) over the root so App Store
    /// screenshots — and automated visual audits — can capture it directly
    /// without scripting two levels of navigation. No effect in normal runs.
    @State private var showThemeScreenshotPage = false
    @State private var livingThemeRequest: LivingThemeDeepLink?

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
#if DEBUG && GSTACK_IOS_QA
        DebugBridgeUIWiring.installAll()
        DebugOverlayWindow.shared.install()
        StateServer.shared.start()
#endif
        // Resume opt-in analytics for a previously-consented install WITHOUT
        // re-emitting the grant event, then record this app session. Both are
        // no-ops (and the SDK is never constructed) unless consent is granted and
        // an Amplitude key is configured — see MobileAnalytics / AmplitudeTransport.
        MobileAnalytics.shared.startIfConsented()
        MobileAnalytics.trackSessionStartIfConsented()
        MobileAnalytics.markLaunchSeen()
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
                    MobileAnalytics.shared.track(.appForegrounded)
                    // Sync any snippets the user added straight from the keyboard.
                    Task { await MobileTextExpansionStore.ingestKeyboardInboxIfNeeded() }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                    agentNotifications.updateLifecycle("inactive")
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                    agentNotifications.updateLifecycle("background")
                    MobileAnalytics.shared.track(.appBackgrounded)
                }
                // First-run, opt-in analytics consent prompt. Shows once while
                // consent is `.unset`; never reappears after a decision.
                .analyticsConsentPrompt()
                .burnBarLaunchSplash(onHaptic: HapticBus.logoFormation)
                .fullScreenCover(isPresented: $showThemeScreenshotPage) {
                    NavigationStack {
                        ThemeSettingsView()
                            .navigationTitle("Appearance")
                            .navigationBarTitleDisplayMode(.inline)
                    }
                }
                .task {
                    // Screenshot/audit affordance only — gated on the App Store
                    // screenshot launch flag so it can never fire in a real session.
                    if AppStoreScreenshotMode.isEnabled,
                       AppStoreScreenshotMode.route == "theme" {
                        showThemeScreenshotPage = true
                    }
                }
                .fullScreenCover(item: $livingThemeRequest) { request in
                    WallpaperGeneratorView(
                        colorDriver: SwarmColorDriver(),
                        livingTheme: request.kernel,
                        livingThemeMaxFrameRate: request.quality.maxFrameRate
                    )
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
        if let request = LivingThemeDeepLink.parse(url) {
            UserDefaults.standard.set(request.kernel.rawValue, forKey: MobileBackdropKernel.storageKey)
            livingThemeRequest = request
            return
        }
        guard url.scheme?.lowercased() == "burnbar" else { return }
        MobileOsDeepLinkApplier.apply(MobileOsIntegrationPolicy.route(url: url))
    }
}
