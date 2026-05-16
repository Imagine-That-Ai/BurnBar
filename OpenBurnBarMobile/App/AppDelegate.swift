import UIKit
import FirebaseAuth
import FirebaseCore
import FirebaseAppCheck
import GoogleSignIn
import OpenBurnBarCore
import OpenBurnBarMedia

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Retained iOS file-transfer service so its `@Published` state
    /// survives the lifetime of the app and any inbound
    /// `media.blob.advertise` frames have a live receiver.
    private var iOSFileTransfer: iOSFileTransferService?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        configureFirebase()
        configureMercuryFileTransfer()
        return true
    }

    /// Mercury Phase 1b — wire the iOS file-transfer service so inbound
    /// `media.blob.advertise` frames on the chat response stream trigger
    /// a fetch + ack. Falls back to a no-op dispatcher (frames are
    /// silently skipped) on builds that don't link the xcframework.
    @MainActor
    private func configureMercuryFileTransfer() {
        guard let service = MediaFileTransferServiceFactory.make() else { return }
        let receiver = iOSFileTransferService(
            service: service,
            settingsProvider: { @MainActor in
                // Mirrors the Mac `ChatBackendSettings.mediaBlobTransferEnabled`
                // key so Remote Config + per-device sync stays consistent.
                UserDefaults.standard.bool(forKey: "mediaBlobTransferEnabled")
            }
        )
        self.iOSFileTransfer = receiver
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
        GIDSignIn.sharedInstance.handle(url)
    }

    /// Configures Firebase + App Check.
    ///
    /// `AppCheck.setAppCheckProviderFactory(_:)` MUST be invoked **before**
    /// `FirebaseApp.configure()` so the very first Firestore call presents a
    /// valid attestation token. Otherwise the project's App Check enforcement
    /// will block every read (`App Check blocked` in Sync diagnostics).
    ///
    /// - Internal distribution builds: when `OpenBurnBarUseDebugAppCheck` is
    ///   present in Info.plist, use the App Check debug provider with a
    ///   pre-registered token. This keeps Firestore enforcement enabled for
    ///   TestFlight/App Distribution channels while Apple/Play attestation is
    ///   not available.
    /// - Production builds: DeviceCheck. App Attest is stronger, but it must
    ///   also be enabled on the Apple Bundle ID/provisioning profile before the
    ///   entitlement can be shipped. DeviceCheck keeps enforced Firestore App
    ///   Check working for TestFlight while that Apple capability is managed.
    /// - Debug builds: the App Check debug provider so a registered debug
    ///   token from `firebase.console -> App Check -> iOS app` is accepted.
    private func configureFirebase() {
        guard let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") else {
            print("warning: GoogleService-Info.plist not found; Firebase remains unconfigured.")
            return
        }
        guard Self.googleServiceInfoLooksConfigured(at: path) else {
            print("warning: GoogleService-Info.plist is a placeholder or invalid; Firebase remains unconfigured.")
            return
        }

        let useDebugProvider = Self.useDebugAppCheckProvider()
            || AppCheckDebugTokenEnvironment.token(inPlistAt: path) != nil
        let factory: AppCheckProviderFactory
        #if DEBUG
        _ = AppCheckDebugTokenEnvironment.configureIfAvailable(firebasePlistPath: path)
        factory = AppCheckDebugProviderFactory()
        #else
        if useDebugProvider {
            _ = AppCheckDebugTokenEnvironment.configureIfAvailable(firebasePlistPath: path)
            factory = AppCheckDebugProviderFactory()
        } else {
            factory = OpenBurnBarAppCheckProviderFactory()
        }
        #endif
        AppCheck.setAppCheckProviderFactory(factory)

        FirebaseApp.configure()
        #if DEBUG
        Self.signInWithE2ECustomTokenIfNeeded()
        #endif
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

    private static func useDebugAppCheckProvider(
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if truthy(environment["OPENBURNBAR_USE_DEBUG_APP_CHECK"]) {
            return true
        }
        return truthy(infoDictionary?["OpenBurnBarUseDebugAppCheck"])
    }

    private static func truthy(_ raw: Any?) -> Bool {
        switch raw {
        case let value as Bool:
            return value
        case let value as String:
            return ["1", "true", "yes", "y"].contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        default:
            return false
        }
    }

    #if DEBUG
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
                print("OpenBurnBarMobile E2E Firebase sign-in active for uid \(result.user.uid).")
                await launchE2EMissionIfRequested(environment: environment)
            } catch {
                print("warning: OpenBurnBarMobile E2E Firebase sign-in failed: \(error.localizedDescription)")
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
            print("OpenBurnBarMobile E2E mission dispatched: \(requestID)")
        } catch {
            print("warning: OpenBurnBarMobile E2E mission dispatch failed: \(error.localizedDescription)")
        }
    }
    #endif
}

/// App Check provider factory for release builds.
final class OpenBurnBarAppCheckProviderFactory: NSObject, AppCheckProviderFactory {
    func createProvider(with app: FirebaseApp) -> AppCheckProvider? {
        return DeviceCheckProvider(app: app)
    }
}
