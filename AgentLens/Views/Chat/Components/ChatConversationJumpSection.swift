import SwiftUI

struct ChatConversationJumpSection: View {
    var targets: [ConversationJumpTarget]
    var onJump: (ConversationJumpTarget) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("Open Matched Sessions")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .textCase(.uppercase)

            ForEach(targets) { target in
                Button {
                    onJump(target)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(target.conversation.inferredTaskTitle)
                                .font(DesignSystem.Typography.body)
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text("\(target.startOffset)-\(target.endOffset)")
                                .font(DesignSystem.Typography.monoTiny)
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                        }
                        Text(target.snippet)
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .lineLimit(3)
                        Text("\(target.conversation.provider.displayName) · \(target.conversation.projectName)")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DesignSystem.Spacing.sm)
                    .background(RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous).fill(DesignSystem.Colors.surface.opacity(0.55)))
                    .overlay(RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous).strokeBorder(DesignSystem.Colors.border.opacity(0.35), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, DesignSystem.Spacing.sm)
    }
}
