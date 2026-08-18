import SwiftUI

// MARK: - Resizable section divider
//
// A draggable divider for a stack of resizable regions.
//
// This repo already had two: `PaneSplitContainer.divider` (chat panes) and
// `ResizableTraySectionDivider` (menu bar popover tray). Writing a third is how
// a codebase ends up with four that behave slightly differently, so this is the
// shared one — the tray divider's chrome with `PaneSplitContainer`'s cursor
// discipline.
//
// The cursor handling is deliberately `NSCursor.set()` with an `.onDisappear`
// reset, and **not** `push()`/`pop()`. The Home rail can vanish while hovered —
// the user hits the collapse chevron, or the window narrows into the band that
// stubs the rail — and an unbalanced `pop()` leaves the resize cursor stuck
// over the whole app. `PaneSplitContainer` learned this already; the comment
// there names the exact failure.

struct ResizableSectionDivider: View {
    enum Axis { case horizontal, vertical }

    let axis: Axis
    /// Drag delta in points, positive meaning "grow the leading region".
    let onDrag: (CGFloat) -> Void
    /// Called when the gesture ends, so the host can persist.
    let onCommit: () -> Void
    /// Double-click resets to the natural split, when the host supports it.
    var onReset: (() -> Void)?

    static let thickness: CGFloat = 7

    @State private var isHovering = false
    @State private var isDragging = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())

            Rectangle()
                .fill(DesignSystem.Colors.borderSubtle.opacity(0.72))
                .frame(
                    width: axis == .horizontal ? nil : 0.75,
                    height: axis == .horizontal ? 0.75 : nil
                )

            // Grab handle, revealed on hover so the divider is discoverable
            // without drawing a permanent bar across the rail.
            Capsule()
                .fill(DesignSystem.Colors.ember.opacity(isDragging ? 0.85 : 0.55))
                .frame(
                    width: axis == .horizontal ? 36 : 3,
                    height: axis == .horizontal ? 3 : 36
                )
                .opacity(isHovering || isDragging ? 1 : 0)
                .animation(DesignSystem.Animation.snappy, value: isHovering)
        }
        .frame(
            width: axis == .horizontal ? nil : Self.thickness,
            height: axis == .horizontal ? Self.thickness : nil
        )
        .onHover { hovering in
            isHovering = hovering
            updateCursor(hovering: hovering)
        }
        // A pane can be destroyed mid-hover, so always hand the cursor back.
        .onDisappear {
            isHovering = false
            NSCursor.arrow.set()
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    isDragging = true
                    onDrag(axis == .horizontal ? value.translation.height : value.translation.width)
                }
                .onEnded { _ in
                    isDragging = false
                    onCommit()
                    if isHovering == false { NSCursor.arrow.set() }
                }
        )
        .onTapGesture(count: 2) { onReset?() }
        .accessibilityElement()
        .accessibilityLabel(axis == .horizontal ? "Resize panels" : "Resize rail")
        .accessibilityHint("Drag to resize. Double-click to reset.")
    }

    private func updateCursor(hovering: Bool) {
        if hovering {
            (axis == .horizontal ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).set()
        } else if isDragging == false {
            NSCursor.arrow.set()
        }
    }
}
