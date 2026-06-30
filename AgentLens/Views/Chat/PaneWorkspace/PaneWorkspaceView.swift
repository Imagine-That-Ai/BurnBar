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
        PaneNodeView(
            node: workspace.root,
            workspace: workspace,
            settingsManager: settingsManager,
            onJumpToConversation: onJumpToConversation
        )
        .id(workspace.root.id)
        .background { shortcuts }
    }

    /// ⌘D / ⌘⇧D split the active pane; ⌘W closes it. ⌘W is mounted ONLY while tiled, so a
    /// single-pane ⌘W falls through to the standard macOS window close (a disabled shortcut
    /// would be version-fragile). Hidden buttons keep the shortcuts in the responder chain
    /// without taking layout space.
    @ViewBuilder
    private var shortcuts: some View {
        ZStack {
            Button("") { workspace.splitActive(axis: .horizontal) }
                .keyboardShortcut("d", modifiers: .command)
            Button("") { workspace.splitActive(axis: .vertical) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            if workspace.paneCount > 1 {
                Button("") { workspace.closeActive() }
                    .keyboardShortcut("w", modifiers: .command)
            }
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
