import SwiftUI

/// iOS in-app Mercury call HUD. Mirror of Mac `CallHUD`. Adds an 88×128
/// self-view PiP draggable to any corner.
@MainActor
struct CallHUDView: View {
    @ObservedObject var state: CallHUDState
    let onMuteMic: () -> Void
    let onMuteCamera: () -> Void
    let onShareScreen: () -> Void
    let onEnd: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack {
                Rectangle().fill(borderGradient).frame(height: 1)
                Spacer()
            }

            VStack {
                HStack {
                    Spacer()
                    Text(state.formattedDuration)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.top, 12)
                    Spacer()
                }
                Spacer()
                // Grouped so the four glass circles share one sampling region
                // on iOS 26 (glass cannot sample other glass); passes content
                // through unchanged on iOS 17–25.
                LiquidGlassGroup(spacing: 16) {
                    HStack(spacing: 16) {
                        controlButton(systemImage: state.isMicMuted ? "mic.slash.fill" : "mic.fill", action: onMuteMic)
                        controlButton(systemImage: state.isCameraMuted ? "video.slash.fill" : "video.fill", action: onMuteCamera)
                        controlButton(systemImage: state.isSharingScreen ? "rectangle.on.rectangle.slash" : "rectangle.on.rectangle", action: onShareScreen)
                        controlButton(systemImage: "phone.down.fill", tint: .red, action: onEnd)
                    }
                }
                .padding(.bottom, 32)
            }
        }
    }

    private func controlButton(
        systemImage: String,
        tint: Color = Color(red: 0.63, green: 0.67, blue: 0.73),
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(tint)
                // Tappable HUD control over live call video → interactive
                // Liquid Glass on iOS 26; identical .ultraThinMaterial circle
                // on iOS 17–25. Meaning stays on the symbol tint (red = end),
                // so the glass itself remains monochrome per the design
                // language. No fill rides under the glass — it samples the
                // live video behind it.
                .liquidGlassCircleButton(diameter: 56)
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
