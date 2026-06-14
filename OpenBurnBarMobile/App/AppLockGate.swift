import SwiftUI
import Observation
import LocalAuthentication
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Pure policy (T-IOS-02)
//
// App-wide LocalAuthentication (Face ID / Touch ID / passcode) gate. The lock
// is default-on so chat + vault data are never revealed until the device owner
// re-authenticates at launch and after the app has been backgrounded. The
// decision logic is a pure value type with an injected clock so the relock
// behaviour is unit-testable without a device or a real `LAContext`.

/// Pure decision: given the last successful unlock time and the current time,
/// should the app require a fresh authentication before showing protected
/// content? A short grace window keeps quick task-switches (e.g. tapping a
/// share sheet) from forcing a Face ID prompt on every return, while a real
/// backgrounding past the window relocks.
struct AppLockPolicy: Equatable {
    /// How long after backgrounding the app stays unlocked. A small window
    /// matches the system "Require Password: After 1 minute"-style ergonomics
    /// without leaving sensitive screens exposed in the app switcher.
    var graceInterval: TimeInterval = 60

    /// Whether the feature is enabled at all. Default-on; the user can opt out
    /// in Settings, in which case the gate is transparent.
    var isEnabled: Bool = true

    /// Decide whether re-authentication is required.
    /// - Parameters:
    ///   - lastUnlock: when the user last authenticated successfully, or `nil`
    ///     if they never have this launch (cold start ⇒ always require).
    ///   - lastBackgrounded: when the app last left the foreground, or `nil` if
    ///     it has not been backgrounded since the last unlock.
    ///   - now: current time.
    func requiresAuthentication(
        lastUnlock: Date?,
        lastBackgrounded: Date?,
        now: Date
    ) -> Bool {
        guard isEnabled else { return false }
        // Never authenticated this process ⇒ require (covers cold launch).
        guard let lastUnlock else { return true }
        // Not backgrounded since the last unlock ⇒ stay unlocked.
        guard let lastBackgrounded, lastBackgrounded > lastUnlock else { return false }
        // Backgrounded after unlocking: relock once the grace window elapses.
        return now.timeIntervalSince(lastBackgrounded) >= graceInterval
    }
}

// MARK: - Authenticator seam

/// Injectable LocalAuthentication seam so the controller can be driven with a
/// fake in tests. Mirrors the existing `confirmLocalAuthentication` pattern in
/// `MercuryLiveSheet` (`.deviceOwnerAuthentication` = biometric-or-passcode).
protocol AppLocalAuthenticator: Sendable {
    /// Whether the device can evaluate biometric-or-passcode authentication at
    /// all. When `false` (no passcode set) the gate fails open so the user is
    /// never permanently locked out of their own app.
    func canAuthenticate() -> Bool
    /// Prompts the device owner. Returns `true` on success.
    func authenticate(reason: String) async -> Bool
}

/// Production authenticator backed by `LAContext`.
struct SystemLocalAuthenticator: AppLocalAuthenticator {
    func canAuthenticate() -> Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No passcode/biometrics enrolled — fail open rather than brick the
            // app. Data-at-rest protection (T-IOS-01/11) still applies.
            return true
        }
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }
}

// MARK: - Controller

@MainActor
@Observable
final class AppLockController {
    /// Whether protected content is currently hidden behind the lock screen.
    private(set) var isLocked: Bool
    /// True while an authentication prompt is in flight (prevents double prompts).
    private(set) var isAuthenticating = false

    var policy: AppLockPolicy
    private let authenticator: AppLocalAuthenticator
    private let now: () -> Date

    private var lastUnlock: Date?
    private var lastBackgrounded: Date?

    static let enabledDefaultsKey = "appLock.enabled"

    init(
        authenticator: AppLocalAuthenticator = SystemLocalAuthenticator(),
        policy: AppLockPolicy = AppLockPolicy(),
        now: @escaping () -> Date = Date.init
    ) {
        self.authenticator = authenticator
        self.now = now
        var resolved = policy
        // Default-on: only disabled when the user has explicitly opted out.
        if UserDefaults.standard.object(forKey: Self.enabledDefaultsKey) != nil {
            resolved.isEnabled = UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey)
        }
        self.policy = resolved
        // Start locked when enabled so the very first frame never shows data.
        self.isLocked = resolved.isEnabled
    }

    /// Called when the app becomes active / on first appear. Prompts when the
    /// policy says authentication is required, otherwise leaves content visible.
    func handleBecameActive() async {
        guard policy.isEnabled else {
            isLocked = false
            return
        }
        let needsAuth = policy.requiresAuthentication(
            lastUnlock: lastUnlock,
            lastBackgrounded: lastBackgrounded,
            now: now()
        )
        if needsAuth {
            isLocked = true
            await authenticate()
        } else {
            isLocked = false
        }
    }

    /// Records that the app left the foreground so the relock timer can start.
    func handleResignActive() {
        guard policy.isEnabled else { return }
        lastBackgrounded = now()
        // Hide content immediately on the way out so the app-switcher snapshot
        // shows the lock screen, not chat/vault data.
        isLocked = true
    }

    /// Presents the system authentication prompt and unlocks on success.
    func authenticate() async {
        guard policy.isEnabled, !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }
        let success = await authenticator.authenticate(
            reason: "Unlock BurnBar to view your chats and vault."
        )
        if success {
            lastUnlock = now()
            isLocked = false
        }
    }
}

// MARK: - Gate view

#if canImport(UIKit)
/// Wraps the app root and hides everything behind a full-bleed lock screen
/// until the device owner authenticates. Applied at the very top of the view
/// tree (see `OpenBurnBarMobileApp`) so chat + vault data are never on screen
/// before authentication, including in the app-switcher snapshot.
struct AppLockGate<Content: View>: View {
    @State private var controller = AppLockController()
    @Environment(\.scenePhase) private var scenePhase
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            content()
                .accessibilityHidden(controller.isLocked)
            if controller.isLocked {
                AppLockScreen(
                    isAuthenticating: controller.isAuthenticating,
                    onUnlock: { Task { await controller.authenticate() } }
                )
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: controller.isLocked)
        .task { await controller.handleBecameActive() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task { await controller.handleBecameActive() }
            case .inactive, .background:
                controller.handleResignActive()
            @unknown default:
                break
            }
        }
    }
}

/// The opaque lock screen shown while `AppLockController.isLocked`.
private struct AppLockScreen: View {
    let isAuthenticating: Bool
    let onUnlock: () -> Void

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
            Rectangle()
                .fill(MobileTheme.Colors.surface)
                .opacity(0.98)
            VStack(spacing: 16) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                Text("BurnBar is locked")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                Text("Authenticate to view your chats and vault.")
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Button(action: onUnlock) {
                    Label("Unlock", systemImage: "faceid")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                }
                .buttonStyle(.borderedProminent)
                .disabled(isAuthenticating)
                .padding(.top, 4)
            }
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("BurnBar is locked. Authenticate to continue.")
    }
}
#endif
