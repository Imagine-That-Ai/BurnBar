import UIKit
import os.log
import FirebaseAuth
import FirebaseCore
import FirebaseAppCheck
import FirebaseFirestore
import FirebaseMessaging
import GoogleSignIn
import OpenBurnBarCore
import OpenBurnBarMedia
#if canImport(Sentry)
import Sentry
#endif

final class AppDelegate: NSObject, UIApplicationDelegate {
    private static let log = Logger(subsystem: "com.openburnbar.mobile", category: "AppDelegate")

    /// Retained iOS file-transfer service so its `@Published` state
    /// survives the lifetime of the app and any inbound
    /// `media.blob.advertise` frames have a live receiver.
    private var iOSFileTransfer: iOSFileTransferService?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        seedDefaultAppearanceIfNeeded()
        Self.configureSentryIfAvailable()
        configureFirebase()
        Task { @MainActor in
            MobileMediaBudgetStatusStore.shared.start()
        }
        configureMercuryFileTransfer()
        AgentReplyNotificationService.shared.configure(application: application)
        CloudVaultRotationPickupLifecycle.install()
        return true
    }

    /// On first launch, opt new users into the live provider-glyph swarm
    /// backdrop so the app greets them with the same beautiful dot swarm the
    /// website shows. Only seeds when the key is absent, so anyone who toggles
    /// it off keeps their choice across launches.
    private func seedDefaultAppearanceIfNeeded() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "useWebsiteBackground") == nil {
            defaults.set(true, forKey: "useWebsiteBackground")
        }
    }

    /// Initialize Sentry crash reporting if a DSN is available.
    ///
    /// Mirrors the macOS `AgentLensApp.configureSentryIfAvailable()` options and
    /// consent posture exactly: the DSN is read from the `sentry.dsn` key in
    /// Info.plist (injected via CI for internal builds) and Sentry remains
    /// disabled silently when absent. There is no additional in-app consent
    /// gate — same as the Mac app — so internal distribution builds are
    /// crash-instrumented while OSS/placeholder builds stay dark.
    #if canImport(Sentry)
    private static func configureSentryIfAvailable() {
        var dsn: String? = Bundle.main.object(forInfoDictionaryKey: "sentry.dsn") as? String
        if dsn == nil || dsn?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            if let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
               let dict = NSDictionary(contentsOfFile: path),
               let googleDsn = dict["sentry.dsn"] as? String {
                dsn = googleDsn
            }
        }
        guard let finalDsn = dsn, !finalDsn.trimmingCharacters(in: .whitespaces).isEmpty else {
            // No DSN configured — crash reporting remains disabled silently.
            return
        }
        // T-PRV-03 — consent gate. Crash reporting only runs when the user has
        // not opted out. Default-on matches the existing internal-build posture,
        // but the explicit key lets a privacy-conscious user disable it.
        guard MobileCrashReportingConsent.isEnabled() else {
            return
        }
        SentrySDK.start { options in
            options.dsn = finalDsn
            options.environment = "mobile"
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
            options.releaseName = "openburnbar-mobile@\(version)"
            options.tracesSampleRate = 0
            options.enableAutoSessionTracking = true
            // T-PRV-03 — never attach PII (IP, username, email) to events.
            options.sendDefaultPii = false
            // T-PRV-03 — scrub event payloads + breadcrumbs of any user content
            // (prompts, vault data, tokens, file paths) before they leave the
            // device. Returning nil drops the breadcrumb entirely.
            options.beforeSend = { event in
                MobileSentryScrubber.scrub(event)
            }
            options.beforeBreadcrumb = { breadcrumb in
                MobileSentryScrubber.scrub(breadcrumb)
            }
            #if DEBUG
            options.debug = false
            #endif
        }

        // Anonymized per-install user ID so Sentry can correlate crashes without
        // collecting any personally identifiable information.
        let user = User()
        let bundleID = Bundle.main.bundleIdentifier ?? "com.openburnbar.mobile"
        let vendorSeed = (bundleID + (UIDevice.current.identifierForVendor?.uuidString ?? "")).data(using: .utf8) ?? Data()
        let anonymizedID = vendorSeed.map { String(format: "%02x", $0) }.joined().prefix(32)
        user.userId = String(anonymizedID)
        SentrySDK.setUser(user)
    }
    #else
    private static func configureSentryIfAvailable() {
        // Sentry SDK not linked — skip silently.
    }
    #endif

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        AgentReplyNotificationService.shared.didRegisterForRemoteNotifications(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        #if DEBUG
        Self.log.error("Remote notification registration failed: \(error.localizedDescription, privacy: .public)")
        #endif
    }

    /// Mercury Phase 1b — wire the iOS file-transfer service so inbound
    /// `media.blob.advertise` frames on the chat response stream trigger
    /// a fetch + ack. Falls back to a no-op dispatcher (frames are
    /// silently skipped) on builds that don't link the xcframework.
    @MainActor
    private func configureMercuryFileTransfer() {
        let receiver = iOSFileTransferService(
            service: MediaFileTransferServiceFactory.make(),
            settingsProvider: { @MainActor in
                // Mirrors the Mac `ChatBackendSettings.mediaBlobTransferEnabled`
                // key so Remote Config + per-device sync stays consistent.
                UserDefaults.standard.bool(forKey: "mediaBlobTransferEnabled")
            }
        )
        self.iOSFileTransfer = receiver
        iOSFileTransferService.current = receiver

        // Mercury Phase 8.1 — every successful send/receive appends to the
        // Mercury transfer-history store so the Live screen can show a
        // recent-transfers timeline.
        receiver.onTransferCompleted = { completion in
            Task { @MainActor in
                MercuryTransferHistoryStore.shared.append(
                    MercuryTransferHistoryEntry(
                        id: completion.id,
                        connectionID: completion.connectionID,
                        direction: completion.direction == .sent ? .sent : .received,
                        filename: completion.filename,
                        mime: completion.mime,
                        sizeBytes: completion.sizeBytes,
                        completedAt: completion.completedAt,
                        bytesPerSecond: completion.bytesPerSecond,
                        didResume: completion.didResume,
                        localURL: completion.localURL
                    )
                )

                // Privacy-leak remediation (Fork F = SEAL): mirror the local
                // history row into the cloud manifest collection with the
                // filename SEALED via the vault key. This is the single
                // writer-of-record per direction; gated on the media
                // entitlement (skips silently if absent so local history is
                // unaffected) and the cleartext name never reaches Firestore.
                await MediaAttachmentManifestStore.persistManifest(completion)
            }
        }

        // Warm the personalization store so the first navigation to
        // MercuryLiveSheet doesn't pay the JSON-decode cost.
        _ = MercuryPersonalizationStore.shared

        HermesIrohRelayTransport.shared.installMediaControlStream(into: receiver)
        HermesIrohRelayTransport.shared.mediaDispatcher = { @Sendable frame, ackSender in
            await receiver.handleAdvertise(frame: frame, ackSender: ackSender)
        }
    }

    /// Forward OAuth callback URLs to GoogleSignIn. Without this, the Google
    /// sign-in flow opens Safari, returns to the app, and silently never
    /// completes the continuation in `LiveAuthGateway.signInWithGoogle()`.
    func application(_ app: UIApplication,
                     open url: URL,
                     options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        return GIDSignIn.sharedInstance.handle(url)
    }

    /// Configures Firebase + App Check.
    ///
    /// `AppCheck.setAppCheckProviderFactory(_:)` MUST be invoked **before**
    /// `FirebaseApp.configure()` so the very first Firestore call presents a
    /// valid attestation token. Otherwise the project's App Check enforcement
    /// will block every read (`App Check blocked` in Sync diagnostics).
    ///
    /// - All distributed builds: App Attest on supported OS versions with
    ///   DeviceCheck fallback. Release artifacts never accept debug providers
    ///   or reusable debug tokens.
    /// - Debug builds: the App Check debug provider so a registered debug
    ///   token from `firebase.console -> App Check -> iOS app` is accepted.
    private func configureFirebase() {
        guard let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") else {
            Self.log.warning("GoogleService-Info.plist not found; Firebase remains unconfigured.")
            return
        }
        guard Self.googleServiceInfoLooksConfigured(at: path) else {
            Self.log.warning("GoogleService-Info.plist is a placeholder or invalid; Firebase remains unconfigured.")
            return
        }

        let appCheckProvider = Self.installAppCheckProviderFactory(firebasePlistPath: path)
        #if DEBUG
        Self.log.info("OpenBurnBarMobile App Check provider: \(appCheckProvider, privacy: .public)")
        #endif

        FirebaseApp.configure()
        Self.disableFirestoreNetworkOnIncompatibleOSIfNeeded()
        Self.configureGoogleSignIn()
        _ = MobileAppCheckAttestationMonitor.shared
        Task { @MainActor in
            await Self.validateAppCheckIfNeeded()
        }
        Auth.auth().addStateDidChangeListener { _, user in
            let isCloudAccount = user?.isAnonymous == false
            Task { @MainActor in
                await IrohControllerRouteAuthLifecycleCoordinator.shared
                    .handleAuthenticatedUIDChanged(to: user?.uid)
                MobileMediaBudgetStatusStore.shared.handleCloudAccountStateChanged(isCloudAccount: isCloudAccount)
                guard isCloudAccount else { return }
                await Self.validateAppCheckIfNeeded()
            }
        }
        #if DEBUG
        Self.signInWithE2ECustomTokenIfNeeded()
        #endif
    }

    /// True when this launch deliberately turned Firestore's live network off
    /// (emergency kill switch below). `CloudSyncHealthStore` reads this so the
    /// sync UI says "cloud sync is switched off on this device" instead of
    /// rendering empty data as $0.00 burn and "Mac last seen: never".
    private(set) static var isFirestoreNetworkDisabled = false

    /// Emergency escape hatch: setting this defaults key to `true` (e.g. via a
    /// support script or `defaults write`) disables Firestore's live network on
    /// next launch without a binary update, should a runtime/gRPC regression
    /// like the iOS 27 beta one ever resurface.
    static let firestoreNetworkKillSwitchDefaultsKey = "OpenBurnBarDisableFirestoreNetwork"

    private static func disableFirestoreNetworkOnIncompatibleOSIfNeeded() {
        guard shouldDisableFirestoreNetworkForRuntime(
            isSimulator: isRunningInSimulator,
            operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersion,
            killSwitchEnabled: UserDefaults.standard.bool(forKey: firestoreNetworkKillSwitchDefaultsKey)
        ) else {
            return
        }
        isFirestoreNetworkDisabled = true
        Firestore.firestore().disableNetwork { error in
            #if DEBUG
            if let error {
                Self.log.error("failed to disable Firestore network via kill switch: \(error.localizedDescription, privacy: .public)")
            } else {
                Self.log.notice("OpenBurnBarMobile disabled Firestore network via the emergency kill switch.")
            }
            #endif
        }
    }

    /// History: the iOS 27 BETA runtime faulted inside the bundled
    /// gRPC/BoringSSL (Firebase 11.15 / grpc-binary 1.69) the first time
    /// Firestore opened its gRPC TLS channel — `EXC_BAD_ACCESS` (SIGBUS) in
    /// `OPENSSL_cleanse` via `ssl_cert_dup` → `create_tsi_ssl_handshaker` — so
    /// this gate used to hard-disable Firestore's network on iOS 27+. That
    /// left every iOS 27 user with a silently cloud-dead app ($0.00 burn,
    /// "Mac last seen: never", no quota) while auth kept working over REST.
    /// Verified on-device on iOS 27.0 GM with Firebase 12.15: the handshake no
    /// longer faults, so the version gate is gone. What remains is the
    /// explicit kill switch above — never an OS-version heuristic — and the
    /// sync UI now surfaces the disabled state instead of faking empty data.
    static func shouldDisableFirestoreNetworkForRuntime(
        isSimulator: Bool,
        operatingSystemVersion: OperatingSystemVersion,
        killSwitchEnabled: Bool
    ) -> Bool {
        killSwitchEnabled
    }

    private static var isRunningInSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    @MainActor
    private static func validateAppCheckIfNeeded() async {
        guard Auth.auth().currentUser?.isAnonymous == false else { return }
        do {
            let token = try await AppCheck.appCheck().token(forcingRefresh: false)
            guard !token.token.isEmpty else {
                postAppCheckWarning("App Check returned an empty token.")
                return
            }
        } catch {
            postAppCheckWarning("App Check token fetch failed: \(error.localizedDescription)")
            return
        }
        do {
            try await ComputerUseSecurityCallableClient.bindAppCheckAttestation()
        } catch {
            postAppCheckWarning("App Check attestation bind failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    private static func postAppCheckWarning(_ message: String) {
        Self.log.warning("App Check validation warning: \(message, privacy: .public)")
        NotificationCenter.default.post(
            name: .openBurnBarMobileAppCheckValidationFailed,
            object: nil,
            userInfo: ["message": message]
        )
    }

    private static func configureGoogleSignIn() {
        guard let clientID = FirebaseApp.app()?.options.clientID
            ?? googleServiceInfoValue("CLIENT_ID")
        else {
            Self.log.warning("Google sign-in client ID is missing; Google auth remains disabled.")
            return
        }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
    }

    private static func googleServiceInfoLooksConfigured(at path: String) -> Bool {
        guard
            let plist = NSDictionary(contentsOfFile: path) as? [String: Any],
            let googleAppID = plist["GOOGLE_APP_ID"] as? String
        else {
            return false
        }

        // Firebase throws an Objective-C exception for placeholder or malformed
        // app IDs, which Swift cannot catch. Validate before calling configure
        // so clean OSS checkouts and tests degrade to auth-disabled mode.
        return googleAppID.range(
            of: #"^1:[0-9]+:ios:[A-Za-z0-9]+$"#,
            options: .regularExpression
        ) != nil
    }

    private static func googleServiceInfoValue(_ key: String) -> String? {
        guard let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
              let plist = NSDictionary(contentsOfFile: path) as? [String: Any] else {
            return nil
        }
        return plist[key] as? String
    }

    @discardableResult
    static func installAppCheckProviderFactory(
        firebasePlistPath path: String,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isDebugBuild: Bool = AppCheckDebugTokenEnvironment.isDebugBuild
    ) -> String {
        let strategy = appCheckProviderStrategy(
            firebasePlistPath: path,
            infoDictionary: infoDictionary,
            environment: environment,
            isDebugBuild: isDebugBuild
        )
        switch strategy {
        case .debug:
            _ = AppCheckDebugTokenEnvironment.configureIfAvailable(
                firebasePlistPath: path,
                infoDictionary: infoDictionary,
                environment: environment,
                debugAppCheckAllowed: true
            )
            AppCheck.setAppCheckProviderFactory(AppCheckDebugProviderFactory())
        case .appAttest:
            AppCheck.setAppCheckProviderFactory(OpenBurnBarAppCheckProviderFactory())
        case .deviceCheck:
            AppCheck.setAppCheckProviderFactory(DeviceCheckOnlyAppCheckProviderFactory())
        }
        return strategy.rawValue
    }

    enum AppCheckProviderStrategy: String {
        case debug
        case appAttest = "appattest"
        case deviceCheck = "devicecheck"
    }

    static func appCheckProviderStrategy(
        firebasePlistPath path: String,
        infoDictionary: [String: Any]?,
        environment: [String: String],
        isDebugBuild: Bool = AppCheckDebugTokenEnvironment.isDebugBuild
    ) -> AppCheckProviderStrategy {
        let debugAllowed = isDebugBuild
        if let override = normalizedAppCheckProviderOverride(
            environment["OPENBURNBAR_APP_CHECK_PROVIDER"],
            debugAppCheckAllowed: debugAllowed
        ) {
            return override
        }

        if isDebugBuild {
            return .debug
        }
        return .appAttest
    }

    private static func normalizedAppCheckProviderOverride(
        _ raw: String?,
        debugAppCheckAllowed: Bool
    ) -> AppCheckProviderStrategy? {
        guard let raw else { return nil }
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
        switch normalized {
        case "debug":
            return debugAppCheckAllowed ? .debug : nil
        case "appattest", "appattestprovider", "production", "release":
            return .appAttest
        case "devicecheck", "devicecheckprovider":
            return .deviceCheck
        default:
            Self.log.warning("Unknown OPENBURNBAR_APP_CHECK_PROVIDER '\(raw, privacy: .public)'; falling back to the build default.")
            return nil
        }
    }

    #if DEBUG
    private static func truthy(_ raw: String?) -> Bool {
        guard let raw else { return false }
        return ["1", "true", "yes", "y"].contains(raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    private static func signInWithE2ECustomTokenIfNeeded(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let token = environment["OPENBURNBAR_E2E_FIREBASE_CUSTOM_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = environment["OPENBURNBAR_E2E_FIREBASE_EMAIL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = environment["OPENBURNBAR_E2E_FIREBASE_PASSWORD"]
        guard token?.isEmpty == false || (email?.isEmpty == false && password?.isEmpty == false) else {
            return
        }

        let expectedUID = environment["OPENBURNBAR_E2E_FIREBASE_UID"]
        if let expectedUID, Auth.auth().currentUser?.uid == expectedUID {
            Task { @MainActor in
                await launchE2EMissionIfRequested(environment: environment)
            }
            return
        }

        Task { @MainActor in
            do {
                let result: AuthDataResult
                if let token, token.isEmpty == false {
                    result = try await Auth.auth().signIn(withCustomToken: token)
                } else if let email, let password {
                    result = try await Auth.auth().signIn(withEmail: email, password: password)
                } else {
                    return
                }
                Self.log.info("OpenBurnBarMobile E2E Firebase sign-in active for uid \(result.user.uid, privacy: .public).")
                await launchE2EMissionIfRequested(environment: environment)
            } catch {
                Self.log.warning("OpenBurnBarMobile E2E Firebase sign-in failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func launchE2EMissionIfRequested(environment: [String: String]) async {
        guard truthy(environment["OPENBURNBAR_E2E_LAUNCH_MISSION"]) else {
            return
        }

        let runtime = environment["OPENBURNBAR_E2E_MISSION_RUNTIME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetProject = environment["OPENBURNBAR_E2E_MISSION_TARGET"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = environment["OPENBURNBAR_E2E_MISSION_PROMPT"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "Reply with exactly: OpenBurnBar simulator mission complete."

        do {
            let requestID = try await CLIAgentMissionDispatcher.shared.dispatch(
                title: "Simulator E2E Mission",
                prompt: prompt,
                missionKind: "custom",
                requestedRuntime: runtime?.isEmpty == false ? runtime! : "ollama",
                targetProject: targetProject?.isEmpty == false ? targetProject : nil,
                depth: "standard",
                approvalMode: "read_only",
                commandsAllowed: false,
                fileEditsAllowed: false
            )
            Self.log.info("OpenBurnBarMobile E2E mission dispatched: \(requestID, privacy: .public)")
        } catch {
            Self.log.warning("OpenBurnBarMobile E2E mission dispatch failed: \(error.localizedDescription, privacy: .public)")
        }
    }
    #endif
}

/// App Check provider factory for release builds.
final class OpenBurnBarAppCheckProviderFactory: NSObject, AppCheckProviderFactory {
    func createProvider(with app: FirebaseApp) -> AppCheckProvider? {
        if #available(iOS 14.0, *) {
            return AppAttestProvider(app: app)
        }
        return DeviceCheckProvider(app: app)
    }
}

final class DeviceCheckOnlyAppCheckProviderFactory: NSObject, AppCheckProviderFactory {
    func createProvider(with app: FirebaseApp) -> AppCheckProvider? {
        DeviceCheckProvider(app: app)
    }
}
