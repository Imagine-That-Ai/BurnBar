import SwiftUI
import OpenBurnBarCore

/// Compact segmented toggle between Agent view (rich bubbles) and CLI view
/// (raw monospaced output) adapted for iOS/iPadOS mobile app layout.
struct MobileChatViewModePicker: View {
    @Binding var chatViewMode: ChatViewMode
    @Environment(\.uiMode) private var uiMode
    @Environment(\.uiTheme) private var theme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ChatViewMode.allCases) { mode in
                Button {
                    withAnimation(MobileTheme.Animation.snappy) {
                        chatViewMode = mode
                    }
                    Haptics.light()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: mode.icon)
                            .font(.system(size: 12, weight: .bold))
                        Text(mode.displayName)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                    }
                    .padding(.vertical, uiMode == .cooking ? 6 : 4)
                    .padding(.horizontal, uiMode == .cooking ? 10 : 8)
                    .foregroundStyle(
                        chatViewMode == mode
                            ? theme.textPrimary
                            : MobileTheme.Colors.textMuted
                    )
                    .background {
                        if chatViewMode == mode {
                            Capsule(style: .continuous)
                                .fill(theme.surface)
                                .shadow(color: theme.primaryAccent.opacity(0.12), radius: uiMode == .cooking ? 4 : 2, x: 0, y: 1)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(
            Capsule(style: .continuous)
                .fill(theme.surface.opacity(0.4))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(theme.border.opacity(0.25), lineWidth: 0.5)
        )
    }
}
