import SwiftUI
import OpenBurnBarCore

/// Compact segmented toggle between Agent view (rich bubbles) and CLI view
/// (raw monospaced output). Placed in the chat header/toolbar alongside
/// the backend strip.
struct ChatViewModePicker: View {
    @Bindable var controller: ChatSessionController

    var body: some View {
        HStack(spacing: 1) {
            ForEach(ChatViewMode.allCases) { mode in
                Button {
                    withAnimation(DesignSystem.Animation.snappy) {
                        controller.chatViewMode = mode
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: mode.icon)
                            .font(.system(size: 9, weight: .semibold))
                        Text(mode.displayName)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                    }
                    .frame(height: 18)
                    .padding(.horizontal, 5)
                    .foregroundStyle(
                        controller.chatViewMode == mode
                            ? DesignSystem.Colors.textPrimary
                            : DesignSystem.Colors.textMuted
                    )
                    .background {
                        if controller.chatViewMode == mode {
                            Capsule(style: .continuous)
                                .fill(DesignSystem.Colors.surfaceElevated)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(DesignSystem.Colors.background.opacity(0.6))
        .clipShape(Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(DesignSystem.Colors.borderSubtle.opacity(0.5), lineWidth: 0.5)
        )
        .help("Switch between Agent view (rich bubbles) and CLI view (raw output)")
    }
}
