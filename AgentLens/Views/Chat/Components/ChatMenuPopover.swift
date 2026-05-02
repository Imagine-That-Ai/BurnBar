import SwiftUI

struct ChatMenuPopover: View {
    @Bindable var controller: ChatSessionController
    var onShowClearChatPrompt: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(DesignSystem.Colors.textMuted)
                    TextField("Search indexed sessions...", text: $controller.searchQuery)
                        .textFieldStyle(.plain)
                        .font(DesignSystem.Typography.caption)
                        .onSubmit { controller.performSearch() }
                }
                .padding(.horizontal, DesignSystem.Spacing.sm)
                .padding(.vertical, DesignSystem.Spacing.xs + 2)
                .background(RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous).fill(DesignSystem.Colors.surface.opacity(0.35)))
            }
            .padding(DesignSystem.Spacing.md)

            Divider().foregroundStyle(DesignSystem.Colors.borderSubtle)

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                HStack {
                    Text("Chat History").font(DesignSystem.Typography.caption).fontWeight(.semibold).foregroundStyle(DesignSystem.Colors.textSecondary)
                    Spacer()
                }
                if controller.historyThreads.isEmpty {
                    Text("No chats yet").font(DesignSystem.Typography.tiny).foregroundStyle(DesignSystem.Colors.textMuted).padding(.vertical, DesignSystem.Spacing.sm)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                            ForEach(controller.historyThreads) { thread in
                                historyRow(thread)
                            }
                        }
                    }
                    .frame(maxHeight: 260)
                }
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.sm)

            Divider().foregroundStyle(DesignSystem.Colors.borderSubtle)

            VStack(spacing: 2) {
                chatMenuAction(icon: "trash", label: "Clear current chat", color: DesignSystem.Colors.error.opacity(0.8)) {
                    onShowClearChatPrompt()
                }
            }
            .padding(DesignSystem.Spacing.sm)
        }
        .frame(width: 300)
        .background(DesignSystem.Colors.surfaceElevated.opacity(0.95))
        .onAppear { controller.refreshHistory() }
    }

    private func historyRow(_ thread: ChatThreadSummary) -> some View {
        let isActive = thread.id == controller.activeThreadID
        return Button {
            controller.openHistoryThread(thread.id)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(thread.title).font(DesignSystem.Typography.caption).foregroundStyle(DesignSystem.Colors.textPrimary).lineLimit(1)
                    Spacer(minLength: 0)
                    if isActive {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(DesignSystem.Colors.whimsy)
                    }
                }
                Text(thread.preview).font(DesignSystem.Typography.tiny).foregroundStyle(DesignSystem.Colors.textSecondary).lineLimit(2)
                Text("\(thread.messageCount) msgs · \(thread.lastActivityAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(DesignSystem.Typography.tiny).foregroundStyle(DesignSystem.Colors.textMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignSystem.Spacing.sm)
            .background(RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous).fill(isActive ? DesignSystem.Colors.whimsy.opacity(0.10) : DesignSystem.Colors.surface.opacity(0.30)))
        }
        .buttonStyle(.plain)
    }

    private func chatMenuAction(icon: String, label: String, color: Color = DesignSystem.Colors.textSecondary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: icon).font(.system(size: 12, weight: .medium)).frame(width: 16)
                Text(label).font(DesignSystem.Typography.caption)
                Spacer()
            }
            .foregroundStyle(color)
            .padding(.horizontal, DesignSystem.Spacing.sm)
            .padding(.vertical, DesignSystem.Spacing.xs + 2)
            .background(RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous).fill(Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
