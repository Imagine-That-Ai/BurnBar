import SwiftUI

/// A one-shot, full-bleed branded launch splash.
///
/// Plays the BurnBar logo-formation animation over a dark backdrop on cold
/// start, then crossfades to reveal the live app underneath. Mount it once at
/// the app root via ``SwiftUI/View/burnBarLaunchSplash(duration:)``.
///
/// The auth state machine resolves almost instantly, so there is no real
/// "loading" gate to hang on — this is a deliberate brand moment: dots
/// converge into the flame, the flame solidifies inside the glass cube, then
/// we hand off to the app. Under **Reduce Motion** the splash is skipped
/// entirely and the app is shown immediately.
public struct BurnBarLaunchSplashModifier: ViewModifier {
    private let duration: Double

    @State private var finished = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(duration: Double) {
        self.duration = duration
    }

    private var showsSplash: Bool { !finished && !reduceMotion }

    public func body(content: Content) -> some View {
        ZStack {
            content

            if showsSplash {
                ZStack {
                    Color(hex: "07070A").ignoresSafeArea()
                    BurnBarLogoFormationView()
                        .frame(maxWidth: 460, maxHeight: 520)
                        .padding(.horizontal, 24)
                }
                .ignoresSafeArea()
                .transition(.opacity)
                .zIndex(1)
            }
        }
        .task {
            // Reduce Motion: don't churn the formation — reveal the app at once.
            guard !reduceMotion else {
                finished = true
                return
            }
            try? await Task.sleep(for: .seconds(duration))
            withAnimation(.easeInOut(duration: 0.6)) { finished = true }
        }
    }
}

public extension View {
    /// Overlays a one-shot branded launch splash that plays the BurnBar logo
    /// formation, then crossfades to reveal `self`. Mount at the app root.
    ///
    /// - Parameter duration: seconds the formation plays before crossfading
    ///   out. The default lets the dots converge, the flame solidify, and the
    ///   glass cube settle before the hand-off.
    func burnBarLaunchSplash(duration: Double = 4.2) -> some View {
        modifier(BurnBarLaunchSplashModifier(duration: duration))
    }
}
