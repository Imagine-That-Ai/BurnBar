import SwiftUI

/// 14pt Mercury ring used as a menu-bar / status-bar live-share
/// indicator. Pulses while a media session is active. Click reveals the
/// `MediaSessionCoordinator` state in the popover.
@MainActor
struct MercuryRing: View {
    let isActive: Bool
    @State private var pulseTrigger: Bool = false

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(borderGradient, lineWidth: 1.5)
                .frame(width: 14, height: 14)
                .scaleEffect(isActive && pulseTrigger ? 1.18 : 1.0)
                .opacity(isActive ? (pulseTrigger ? 0.9 : 0.6) : 0.45)
                .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: pulseTrigger)
        }
        .accessibilityLabel(isActive ? "Mercury session live" : "Mercury idle")
        .help(isActive ? "Mercury session live — Mirror, Call, or Transfer." : "Mercury idle.")
        .onAppear {
            if isActive { pulseTrigger.toggle() }
        }
        .onChange(of: isActive) { _, newValue in
            if newValue { pulseTrigger.toggle() }
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
