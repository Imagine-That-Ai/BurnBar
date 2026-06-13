import SwiftUI

// MARK: - State machine

/// Pure, UIKit-free decision logic for the Mac-mirror privacy overlay (RR-14 —
/// the iOS analogue of Android's `FLAG_SECURE`). Kept as a value type with no
/// SwiftUI / UIKit dependency so the masking contract can be unit-tested on any
/// platform without spinning up a scene.
///
/// Two leak vectors are covered:
///
///   * **App-switcher snapshot.** iOS renders a snapshot of the foreground
///     scene for the multitasking switcher the moment the app leaves `.active`
///     (`.inactive` fires first, *before* `.background`). Masking on any
///     non-active phase keeps the mirrored Mac surface out of that snapshot.
///   * **Screen recording / mirroring.** `UIScreen.isCaptured` is `true` while
///     the screen is being recorded, AirPlay-mirrored, or captured by a
///     ReplayKit broadcast. Masking while captured keeps the Mac surface out of
///     the recording even though the app itself stays `.active`.
struct MobileScreenPrivacyState: Equatable {
    /// Most recent scene phase observed by the modifier. Defaults to `.active`
    /// so a guard that is installed while already foregrounded starts unmasked.
    var scenePhase: ScenePhase = .active
    /// Whether the screen is currently being captured (recorded / mirrored).
    var isCaptured: Bool = false

    /// True when the sensitive content must be hidden behind the privacy cover.
    var shouldMask: Bool {
        scenePhase != .active || isCaptured
    }

    /// Short, stable reason string for the cover copy + diagnostics. `nil` when
    /// nothing needs masking.
    var maskReason: MaskReason? {
        // Capture takes precedence: an active+captured screen is still leaking,
        // and the recording-specific copy is the more actionable message.
        if isCaptured { return .screenCaptured }
        if scenePhase != .active { return .backgrounded }
        return nil
    }

    enum MaskReason: Equatable {
        /// Screen is being recorded / mirrored / AirPlayed.
        case screenCaptured
        /// App left the foreground (app-switcher snapshot window).
        case backgrounded
    }
}

#if canImport(UIKit)
import UIKit

// MARK: - ViewModifier

/// Drops an opaque, blurred privacy cover over sensitive (Mac-mirror) content
/// whenever `MobileScreenPrivacyState.shouldMask` is true. Apply with
/// `.screenPrivacyGuard()` to any screen that renders the paired Mac's surface.
///
/// The cover is rendered *inside* the view (rather than swapping the view out)
/// so the underlying mirror keeps streaming and the unmask is instant when the
/// app returns to the foreground or capture stops — no teardown / reconnect.
struct ScreenPrivacyGuardModifier: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @State private var state = MobileScreenPrivacyState()

    func body(content: Content) -> some View {
        content
            .overlay {
                if state.shouldMask {
                    PrivacyCover(reason: state.maskReason)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.18), value: state.shouldMask)
            .onAppear { state.isCaptured = UIScreen.main.isCaptured }
            .onChange(of: scenePhase, initial: true) { _, phase in
                state.scenePhase = phase
            }
            // Screen recording / mirroring toggles while the app stays active,
            // so it can't be observed via scenePhase — listen for the dedicated
            // notification. `UIScreen` is the publisher's `object`; reading
            // `isCaptured` off it (with a `UIScreen.main` fallback) keeps the
            // state authoritative even if the notification coalesces.
            .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { note in
                let screen = note.object as? UIScreen ?? UIScreen.main
                state.isCaptured = screen.isCaptured
            }
    }
}

/// The opaque cover shown while masked. Blurs nothing through itself (it is
/// fully opaque) so neither the app-switcher snapshot nor a screen recording
/// can capture the mirrored Mac surface underneath.
private struct PrivacyCover: View {
    let reason: MobileScreenPrivacyState.MaskReason?

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
            // A second opaque fill guarantees the cover is light-tight even when
            // the material is rendered translucent against a black mirror.
            Rectangle()
                .fill(MobileTheme.Colors.surface)
                .opacity(0.96)
            VStack(spacing: 12) {
                Image(systemName: glyph)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                Text(headline)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                    .multilineTextAlignment(.center)
                Text(detail)
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(headline)
    }

    private var glyph: String {
        switch reason {
        case .screenCaptured: return "rectangle.on.rectangle.slash"
        case .backgrounded, .none: return "lock.shield"
        }
    }

    private var headline: String {
        switch reason {
        case .screenCaptured: return "Screen recording hidden"
        case .backgrounded, .none: return "BurnBar"
        }
    }

    private var detail: String {
        switch reason {
        case .screenCaptured:
            return "The mirrored Mac screen is hidden while your screen is being recorded or mirrored."
        case .backgrounded, .none:
            return "The mirrored Mac screen stays private in the app switcher."
        }
    }
}

extension View {
    /// Masks this view's content for the app-switcher snapshot and during screen
    /// recording / mirroring (RR-14). Apply to screens that mirror the paired
    /// Mac so a recents snapshot or a screen recording never captures the Mac's
    /// terminal / desktop contents.
    func screenPrivacyGuard() -> some View {
        modifier(ScreenPrivacyGuardModifier())
    }
}
#endif
