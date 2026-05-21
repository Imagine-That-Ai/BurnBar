import SwiftUI

/// Phase 5 Mac in-call HUD. 1pt mercury hairline, mono call timer,
/// 44pt circular control buttons (mute mic / mute cam / share / end).
@MainActor
struct CallHUD: View {
    @ObservedObject var state: CallHUDState
    let onMuteMic: () -> Void
    let onMuteCamera: () -> Void
    let onShareScreen: () -> Void
    let onEnd: () -> Void

    var body: some View {
        Group {
            if state.isCollapsed {
                collapsedPill
            } else {
                expandedHUD
            }
        }
    }

    private var expandedHUD: some View {
        VStack(spacing: 16) {
            HStack(spacing: 10) {
                Rectangle()
                    .fill(borderGradient)
                    .frame(height: 1)

                Button {
                    state.isCollapsed = true
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color(red: 0.63, green: 0.67, blue: 0.73))
                        .frame(width: 24, height: 24)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Collapse Mercury mirror")
                .help("Collapse Mercury mirror")
            }

            Text(state.formattedDuration)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .padding(.top, 8)

            HStack(spacing: 12) {
                liveDot
            }

            Spacer()

            HStack(spacing: 24) {
                controlButton(
                    systemImage: state.isMicMuted ? "mic.slash.fill" : "mic.fill",
                    action: onMuteMic
                )
                controlButton(
                    systemImage: state.isCameraMuted ? "video.slash.fill" : "video.fill",
                    action: onMuteCamera
                )
                controlButton(
                    systemImage: state.isSharingScreen ? "rectangle.on.rectangle.slash" : "rectangle.on.rectangle",
                    action: onShareScreen
                )
                controlButton(
                    systemImage: "phone.down.fill",
                    tint: .red,
                    action: onEnd
                )
            }
            .padding(.bottom, 24)
        }
    }

    private var collapsedPill: some View {
        HStack(spacing: 10) {
            trafficLightButton(
                color: Color(red: 1.0, green: 0.36, blue: 0.32),
                label: "End Mercury mirror",
                action: onEnd
            )

            trafficLightButton(
                color: Color(red: 1.0, green: 0.78, blue: 0.25),
                label: "Expand Mercury mirror",
                action: { state.isCollapsed = false }
            )

            Button {
                state.isCollapsed = false
            } label: {
                ZStack {
                    Circle()
                        .fill(Color(red: 0.26, green: 0.84, blue: 0.39))
                        .frame(width: 12, height: 12)
                    Circle()
                        .strokeBorder(.white.opacity(state.pulse ? 0.42 : 0.18), lineWidth: 3)
                        .frame(width: 18, height: 18)
                        .scaleEffect(state.pulse ? 1.12 : 0.88)
                        .opacity(state.pulse ? 0.42 : 0.18)
                        .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: state.pulse)
                }
                .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Mercury mirror live. Expand controls")
            .help("Mercury mirror live")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(.white.opacity(0.28), lineWidth: 0.75)
        )
        .shadow(color: .black.opacity(0.18), radius: 14, x: 0, y: 8)
    }

    private func trafficLightButton(
        color: Color,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)
                .overlay(Circle().strokeBorder(.white.opacity(0.34), lineWidth: 0.6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }

    private var liveDot: some View {
        Circle()
            .fill(Color(red: 0.63, green: 0.67, blue: 0.73))
            .frame(width: 6, height: 6)
            .scaleEffect(state.pulse ? 1.2 : 1.0)
            .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: state.pulse)
    }

    private func controlButton(
        systemImage: String,
        tint: Color = Color(red: 0.63, green: 0.67, blue: 0.73),
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
    }

    private var borderGradient: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.78, green: 0.74, blue: 0.69), Color(red: 0.63, green: 0.67, blue: 0.73)],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

@MainActor
final class CallHUDState: ObservableObject {
    @Published var startedAt: Date = Date()
    @Published var isMicMuted: Bool = false
    @Published var isCameraMuted: Bool = false
    @Published var isSharingScreen: Bool = false
    @Published var isCollapsed: Bool = true
    @Published var pulse: Bool = false

    func reset(startedAt: Date = Date()) {
        self.startedAt = startedAt
        isMicMuted = false
        isCameraMuted = false
        isSharingScreen = false
        isCollapsed = true
        pulse = false
    }

    var formattedDuration: String {
        let elapsed = Int(Date().timeIntervalSince(startedAt))
        let hours = elapsed / 3600
        let minutes = (elapsed % 3600) / 60
        let seconds = elapsed % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
