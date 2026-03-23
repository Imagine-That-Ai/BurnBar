import SwiftUI

// MARK: - Chat Message View

struct ChatMessageView: View {
    let message: ChatMessageRecord
    var isStreaming: Bool
    var showViaBadge: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: DesignSystem.Spacing.sm) {
            if message.role == .user {
                Spacer(minLength: 40)
                bubble(alignment: .trailing, fill: DesignSystem.Colors.purple.opacity(0.22))
            } else {
                bubble(alignment: .leading, fill: DesignSystem.Colors.surfaceElevated.opacity(0.95))
                Spacer(minLength: 40)
            }
        }
    }

    @ViewBuilder
    private func bubble(alignment: HorizontalAlignment, fill: Color) -> some View {
        VStack(alignment: alignment == .trailing ? .trailing : .leading, spacing: 6) {
            if message.role == .assistant, showViaBadge, let via = message.cliUsed {
                Text("via \(via)")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }

            Text(message.content + (isStreaming && message.role == .assistant ? "▍" : ""))
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
                .textSelection(.enabled)
                .animation(.easeOut(duration: 0.12), value: message.content.count)
        }
        .padding(DesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(fill)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                        .stroke(DesignSystem.Colors.border.opacity(0.35), lineWidth: 0.5)
                )
        )
    }
}
