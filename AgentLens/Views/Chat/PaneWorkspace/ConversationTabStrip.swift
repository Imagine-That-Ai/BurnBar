import SwiftUI

struct ConversationTabStrip: View {
    var workspace: PaneWorkspaceModel

    @State private var renameTab: ChatWorkspaceTab?
    @State private var renameDraft = ""

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(workspace.tabs) { tab in
                    tabButton(tab)
                }

                Button {
                    workspace.newTab()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 28, height: 26)
                }
                .buttonStyle(.plain)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .help("New tab")

                if !workspace.closedTabStack.isEmpty {
                    Button {
                        workspace.reopenClosedTab()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 28, height: 26)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .help("Reopen closed tab")
                }
            }
            .padding(.horizontal, DesignSystem.Spacing.sm)
            .padding(.vertical, 5)
        }
        .background(DesignSystem.Colors.surface.opacity(0.58))
        .overlay(alignment: .bottom) { Divider().opacity(0.35) }
        .popover(item: $renameTab, arrowEdge: .bottom) { tab in
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                TextField("Tab title", text: $renameDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .onSubmit {
                        workspace.renameTab(tab.id, title: renameDraft)
                        renameTab = nil
                    }

                HStack {
                    Spacer()
                    Button("Cancel") { renameTab = nil }
                    Button("Save") {
                        workspace.renameTab(tab.id, title: renameDraft)
                        renameTab = nil
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(DesignSystem.Spacing.md)
        }
    }

    private func tabButton(_ tab: ChatWorkspaceTab) -> some View {
        let selected = tab.id == workspace.selectedTabID
        let hasUnseen = tab.leaves.contains { $0.unseenCompletionAt != nil }
        return HStack(spacing: 6) {
            Button {
                workspace.selectTab(tab.id)
            } label: {
                HStack(spacing: 6) {
                    AgentMarkStack(backends: tab.distinctBackends)
                    PaneColorChip(colorToken: tab.colorToken)
                    Text(workspace.displayTitle(for: tab))
                        .font(.system(size: 11, weight: selected ? .semibold : .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 170, alignment: .leading)
                    if hasUnseen {
                        PaneStatusDot(color: tab.colorToken?.color ?? DesignSystem.Colors.whimsy)
                    }
                    if tab.paneCount > 1 {
                        Image(systemName: tab.zoomedPaneID == nil ? "rectangle.split.2x1" : "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    }
                }
                .padding(.leading, 9)
                .padding(.trailing, workspace.tabs.count > 1 ? 2 : 9)
                .frame(height: 26)
            }
            .buttonStyle(.plain)

            if workspace.tabs.count > 1 {
                Button {
                    workspace.closeTab(tab.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .help("Close tab")
            }
        }
        .foregroundStyle(selected ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                .fill(selected ? DesignSystem.Colors.surfaceElevated.opacity(0.92) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                .strokeBorder(selected ? (tab.colorToken?.color ?? DesignSystem.Colors.whimsy).opacity(0.45) : Color.clear, lineWidth: 0.75)
        )
        .contextMenu {
            Button("Rename") {
                renameDraft = workspace.displayTitle(for: tab)
                renameTab = tab
            }
            Menu("Color") {
                Button("None") { workspace.setTabColor(tab.id, colorToken: nil) }
                Divider()
                ForEach(PaneColorToken.allCases) { token in
                    Button(token.rawValue.capitalized) {
                        workspace.setTabColor(tab.id, colorToken: token)
                    }
                }
            }
            Button("New Tab") { workspace.newTab() }
            Button("Reopen Closed Tab") { workspace.reopenClosedTab() }
            Divider()
            Button("Close Other Tabs") { workspace.closeOtherTabs(keeping: tab.id) }
            Button("Close Tab") { workspace.closeTab(tab.id) }
                .disabled(workspace.tabs.count <= 1)
        }
    }
}

/// Up to three 10pt agent marks, overlapping 4pt, `+N` beyond three.
///
/// This is what "the tab's agent" honestly means when `paneCount > 1`: **the
/// marks are plural because the tab is plural** (§3.7). Tab height is unchanged
/// at 26pt.
struct AgentMarkStack: View {
    var backends: [ChatBackendID]
    var size: CGFloat = 10

    private var visible: [ChatBackendID] { Array(backends.prefix(3)) }
    private var overflow: Int { max(0, backends.count - 3) }

    var body: some View {
        if !backends.isEmpty {
            HStack(spacing: -4) {
                ForEach(Array(visible.enumerated()), id: \.element) { index, backend in
                    AgentMark(backend: backend, size: size)
                        .overlay(
                            RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
                                .strokeBorder(backend.sigilTint.opacity(0.75), lineWidth: 0.75)
                        )
                        .zIndex(Double(visible.count - index))
                }
                if overflow > 0 {
                    Text("+\(overflow)")
                        .font(.system(size: 8, weight: .semibold, design: .rounded))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .padding(.leading, 5)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
        }
    }

    private var accessibilityLabel: String {
        let names = backends.map(\.displayName).joined(separator: ", ")
        return backends.count == 1 ? "Agent: \(names)" : "Agents: \(names)"
    }
}

struct PaneStatusDot: View {
    var color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .overlay(Circle().strokeBorder(.white.opacity(0.45), lineWidth: 0.5))
            .accessibilityLabel("Unread completion")
    }
}

private struct PaneColorChip: View {
    var colorToken: PaneColorToken?

    var body: some View {
        Circle()
            .fill(colorToken?.color ?? DesignSystem.Colors.border.opacity(0.7))
            .frame(width: 8, height: 8)
            .overlay(Circle().strokeBorder(DesignSystem.Colors.border.opacity(0.65), lineWidth: 0.5))
    }
}
