import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Renders the pane tree and installs the tiling keyboard shortcuts. The tree is drawn by
/// two mutually-recursive nominal views (`PaneNodeView` / `PaneSplitContainer`) — a
/// recursive `some View` function cannot express this and would not compile.
struct PaneWorkspaceView: View {
    var workspace: PaneWorkspaceModel
    var settingsManager: SettingsManager
    var onJumpToConversation: (ConversationJumpTarget) -> Void = { _ in }

    var body: some View {
        Group {
            if let zoomedPaneID = workspace.selectedTab.zoomedPaneID,
               let leaf = workspace.leaf(zoomedPaneID) {
                PaneConversationView(
                    controller: leaf.controller,
                    settingsManager: settingsManager,
                    workspace: workspace,
                    leafID: leaf.id,
                    onJumpToConversation: onJumpToConversation
                )
                .id(leaf.id)
            } else {
                PaneNodeView(
                    node: workspace.root,
                    workspace: workspace,
                    settingsManager: settingsManager,
                    onJumpToConversation: onJumpToConversation
                )
                .id(workspace.root.id)
            }
        }
        .id(workspace.selectedTabID)
        .background { ChatWorkspaceShortcuts(workspace: workspace) }
        .onAppear { workspace.mountedViewCount += 1 }
        .onDisappear { workspace.mountedViewCount = max(0, workspace.mountedViewCount - 1) }
    }
}

/// Hidden controls keep workspace commands in the responder chain without taking layout.
private struct ChatWorkspaceShortcuts: View {
    var workspace: PaneWorkspaceModel

    var body: some View {
        ZStack {
            Button("") { workspace.splitActive(axis: .horizontal) }
                .keyboardShortcut("d", modifiers: .command)
            Button("") { workspace.splitActive(axis: .vertical) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Button("") { workspace.newTab() }
                .keyboardShortcut("t", modifiers: .command)
            Button("") { workspace.reopenClosedTab() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Button("") { workspace.selectAdjacentTab(offset: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Button("") { workspace.selectAdjacentTab(offset: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("") { workspace.toggleZoomActive() }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
            Button("") { workspace.jumpToMostRecentUnseen() }
                .keyboardShortcut("u", modifiers: [.command, .shift])
            Button("") { workspace.focusAdjacentPane(offset: -1) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .shift])
            Button("") { workspace.focusAdjacentPane(offset: 1) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .shift])
            if workspace.paneCount > 1 || workspace.tabs.count > 1 {
                Button("") { _ = workspace.performCloseShortcut() }
                    .keyboardShortcut("w", modifiers: .command)
            }
            // ⌘1–⌘9 tab selection is deliberately NOT registered here.
            //
            // It was ambiguous against `DashboardView.swift:691`, which binds
            // ⌘1–⌘8 to the app's primary sections in the same responder chain,
            // and `docs/qa/CHAT_PANE_TABS_QA.md` marks the row NOT RUN — so
            // there was no verified behaviour to preserve, only a coin flip.
            // Tabs keep ⌘⇧[ / ⌘⇧] / ⌘T / ⌘⇧T / ⌘W; the digit keys stay with
            // app-global navigation. Removing a broken binding beats relocating
            // one (spec §4.2).
        }
        .hidden()
    }
}

// MARK: - Recursive node renderer

private struct PaneNodeView: View {
    let node: PaneNode
    var workspace: PaneWorkspaceModel
    var settingsManager: SettingsManager
    var onJumpToConversation: (ConversationJumpTarget) -> Void

    var body: some View {
        switch node {
        case .leaf(let leaf):
            PaneConversationView(
                controller: leaf.controller,
                settingsManager: settingsManager,
                workspace: workspace,
                leafID: leaf.id,
                onJumpToConversation: onJumpToConversation
            )
        case .split(let split):
            PaneSplitContainer(
                split: split,
                workspace: workspace,
                settingsManager: settingsManager,
                onJumpToConversation: onJumpToConversation
            )
        }
    }
}

private struct PaneSplitContainer: View {
    var split: PaneSplitNode
    var workspace: PaneWorkspaceModel
    var settingsManager: SettingsManager
    var onJumpToConversation: (ConversationJumpTarget) -> Void

    @State private var fractionAtDragStart: Double?
    @State private var isHoveringDivider = false
    private let dividerThickness: CGFloat = 7

    var body: some View {
        GeometryReader { geo in
            let isHorizontal = split.axis == .horizontal
            let total = isHorizontal ? geo.size.width : geo.size.height
            let usable = max(0, total - dividerThickness)
            let firstLength = usable * split.fraction
            let secondLength = usable * (1 - split.fraction)

            if isHorizontal {
                HStack(spacing: 0) {
                    childView(split.first).frame(width: firstLength)
                    divider(total: total, isHorizontal: true)
                    childView(split.second).frame(width: secondLength)
                }
            } else {
                VStack(spacing: 0) {
                    childView(split.first).frame(height: firstLength)
                    divider(total: total, isHorizontal: false)
                    childView(split.second).frame(height: secondLength)
                }
            }
        }
    }

    @ViewBuilder
    private func childView(_ child: PaneNode) -> some View {
        PaneNodeView(
            node: child,
            workspace: workspace,
            settingsManager: settingsManager,
            onJumpToConversation: onJumpToConversation
        )
        .id(child.id)
    }

    private func divider(total: CGFloat, isHorizontal: Bool) -> some View {
        // Brighten to the accent on hover/drag so the resize affordance is obvious.
        let active = isHoveringDivider || fractionAtDragStart != nil
        return Rectangle()
            .fill(active ? DesignSystem.Colors.whimsy.opacity(0.7) : DesignSystem.Colors.border.opacity(0.45))
            .frame(
                width: isHorizontal ? dividerThickness : nil,
                height: isHorizontal ? nil : dividerThickness
            )
            .contentShape(Rectangle())
            .accessibilityLabel("Drag to resize panes")
            .accessibilityAddTraits(.allowsDirectInteraction)
            .onHover { hovering in
                isHoveringDivider = hovering
                #if canImport(AppKit)
                // Use set() rather than push()/pop(): a split/close can destroy the divider
                // while hovered, and an unbalanced pop() leaves a stuck resize cursor.
                if hovering {
                    (isHorizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
                } else {
                    NSCursor.arrow.set()
                }
                #endif
            }
            .onDisappear {
                if isHoveringDivider {
                    #if canImport(AppKit)
                    NSCursor.arrow.set()
                    #endif
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if fractionAtDragStart == nil { fractionAtDragStart = split.fraction }
                        let translation = isHorizontal ? value.translation.width : value.translation.height
                        // Divide by the usable span (excludes the divider) so the pane edge
                        // tracks the cursor exactly rather than drifting ~1% per drag.
                        let delta = translation / max(total - dividerThickness, 1)
                        let proposed = (fractionAtDragStart ?? split.fraction) + delta
                        split.fraction = min(
                            PaneWorkspaceModel.maxFraction,
                            max(PaneWorkspaceModel.minFraction, proposed)
                        )
                    }
                    .onEnded { _ in
                        fractionAtDragStart = nil
                        workspace.persist()
                    }
            )
    }
}
