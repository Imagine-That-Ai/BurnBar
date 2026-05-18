import SwiftUI

/// 14pt Mercury ring used as a menu-bar / status-bar live-share
/// indicator. Pulses while a media session is active. Click reveals the
/// `MediaSessionCoordinator` state in the popover.
@MainActor
struct MercuryRing: View {
    let isActive: Bool
    @State private var pulseTrigger: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(borderGradient, lineWidth: 1.5)
                .frame(width: 14, height: 14)
                .scaleEffect(isActive && pulseTrigger && !reduceMotion ? 1.18 : 1.0)
                .opacity(isActive ? (pulseTrigger && !reduceMotion ? 0.9 : 0.6) : 0.45)
                .animation(
                    reduceMotion
                        ? .none
                        : .easeInOut(duration: 1.5).repeatForever(autoreverses: true),
                    value: pulseTrigger
                )
        }
        .accessibilityElement()
        .accessibilityLabel(isActive ? "Mercury session live" : "Mercury idle")
        .accessibilityValue(isActive ? "Active" : "Idle")
        .accessibilityHint("Indicates whether a screen share, call, or file transfer is in progress.")
        .help(isActive ? "Mercury session live — Mirror, Call, or Transfer." : "Mercury idle.")
        .onAppear {
            if isActive && !reduceMotion { pulseTrigger.toggle() }
        }
        .onChange(of: isActive) { _, newValue in
            if newValue && !reduceMotion { pulseTrigger.toggle() }
        }
    }

    private var borderGradient: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.78, green: 0.74, blue: 0.69), Color(red: 0.63, green: 0.67, blue: 0.73)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
