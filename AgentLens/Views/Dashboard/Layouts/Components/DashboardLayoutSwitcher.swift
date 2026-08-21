import OpenBurnBarCore
import SwiftUI

enum DashboardLayoutMetrics {
    static let contentMaxWidth: CGFloat = 1_360
    /// Ledger is a single reading column, so it clamps far tighter than the grid
    /// layouts. Past roughly this width a table of six values stops being a
    /// column of aligned figures and becomes a row of scattered ones.
    static let ledgerMaxWidth: CGFloat = 1_040
}

// MARK: - Dashboard Layout Switcher
//
// A compact glass pill in the deck rail that opens a preview gallery.
//
// It used to be an expanding segmented control: eight pills, each one a word. At
// six that was already tight in a 40pt rail, and it had a worse problem than
// width — "Nebula" does not tell you what you are about to get. Choosing a
// *layout* from a list of *nouns* is a guess, and you can only tell whether the
// guess was right by looking at the whole page afterwards.
//
// So the collapsed state names the current layout, and the expanded state is a
// popover of vector wireframes: the shape of each layout at a glance, its name,
// and one line saying who it is for. You pick a picture, not a word.
//
// Keyboard: ←/→/↑/↓ move the highlight through the gallery, Return commits,
// Escape dismisses. `matchedGeometryEffect` still carries the selection sweep
// between the pill and the gallery so the choice feels continuous.

struct DashboardLayoutSwitcher: View {
    @Binding var selection: DashboardLayout
    var scale: CGFloat = 1

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.backdropInk) private var ink
    @State private var isExpanded = false
    /// The gallery's keyboard cursor, held apart from `selection` so arrowing
    /// around does not repeatedly rebuild the dashboard behind the popover.
    @State private var highlighted: DashboardLayout?
    @Namespace private var selectionAnimation

    var body: some View {
        collapsedPill
            .popover(isPresented: $isExpanded, arrowEdge: .bottom) {
                DashboardLayoutGallery(
                    selection: $selection,
                    highlighted: $highlighted,
                    onCommit: { layout in
                        withAnimation(reduceMotion ? .easeOut(duration: 0.12) : DesignSystem.Animation.standard) {
                            selection = layout
                        }
                        isExpanded = false
                    },
                    onDismiss: { isExpanded = false }
                )
            }
            .onChange(of: isExpanded) { _, expanded in
                if expanded { highlighted = selection }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Dashboard layout")
            .accessibilityValue(selection.displayName)
    }

    private var collapsedPill: some View {
        Button {
            isExpanded = true
        } label: {
            HStack(spacing: 6 * scale) {
                Image(systemName: selection.symbolName)
                    .font(.system(size: 10 * scale, weight: .semibold))
                Text(selection.displayName)
                    .font(.system(size: 12 * scale, weight: .semibold, design: .rounded))
                Image(systemName: "chevron.down")
                    .font(.system(size: 7 * scale, weight: .bold))
                    .foregroundStyle(ink.icon)
            }
            .foregroundStyle(ink.primary)
            .padding(.horizontal, 12 * scale)
            .padding(.vertical, 6 * scale)
            .background {
                Capsule()
                    .fill(DesignSystem.Colors.ember.opacity(0.16))
                    .matchedGeometryEffect(id: "layoutSelection", in: selectionAnimation)
            }
            .overlay(Capsule().strokeBorder(DesignSystem.Colors.border.opacity(0.36), lineWidth: 0.65))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Choose a dashboard layout")
        .accessibilityHint("Opens the layout gallery")
    }
}

// MARK: - Gallery

/// The expanded picker: a grid of wireframe previews, two columns wide.
///
/// Split out of the switcher rather than inlined so it can be inspected and
/// previewed on its own — the switcher itself is a pill and a popover trigger,
/// and testing "does every layout present" should not require presenting a
/// popover.
struct DashboardLayoutGallery: View {
    @Binding var selection: DashboardLayout
    @Binding var highlighted: DashboardLayout?
    let onCommit: (DashboardLayout) -> Void
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var galleryFocused: Bool

    private let columns = 2

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            header
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.fixed(196), spacing: DesignSystem.Spacing.sm, alignment: .top),
                    count: columns
                ),
                alignment: .leading,
                spacing: DesignSystem.Spacing.sm
            ) {
                ForEach(DashboardLayout.allCases, id: \.self) { layout in
                    card(layout)
                }
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(width: 196 * CGFloat(columns) + DesignSystem.Spacing.sm + DesignSystem.Spacing.lg * 2)
        .background(DesignSystem.Colors.surface)
        .focusable()
        .focused($galleryFocused)
        .onAppear { galleryFocused = true }
        .onMoveCommand(perform: move)
        .onExitCommand(perform: onDismiss)
        .onKeyPress(.return) {
            if let highlighted { onCommit(highlighted) }
            return .handled
        }
        .onKeyPress(.space) {
            if let highlighted { onCommit(highlighted) }
            return .handled
        }
        .accessibilityLabel("Dashboard layout gallery")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("LAYOUT")
                .font(DesignSystem.Typography.tiny)
                .tracking(1.3)
                .foregroundStyle(DesignSystem.Colors.ember)
            Text("Eight ways to read the same numbers")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
    }

    private func card(_ layout: DashboardLayout) -> some View {
        let isSelected = selection == layout
        let isHighlighted = highlighted == layout
        return Button {
            onCommit(layout)
        } label: {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                DashboardLayoutWireframe(layout: layout, accent: DashboardLayoutWireframe.accent(for: layout))
                    .frame(height: 74)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                            .fill(DesignSystem.Colors.surfaceElevated.opacity(0.5))
                    )

                HStack(spacing: 5) {
                    Image(systemName: layout.symbolName)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(DashboardLayoutWireframe.accent(for: layout))
                    Text(layout.displayName)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Spacer(minLength: 0)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(DesignSystem.Colors.ember)
                    }
                }

                Text(layout.tagline)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(DesignSystem.Spacing.sm)
            .background {
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(
                        isSelected
                            ? DesignSystem.Colors.ember.opacity(0.12)
                            : Color.clear
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .strokeBorder(
                        isHighlighted
                            ? DesignSystem.Colors.ember
                            : DesignSystem.Colors.border.opacity(isSelected ? 0.5 : 0.24),
                        lineWidth: isHighlighted ? 1.5 : 0.75
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { highlighted = layout }
        }
        .animation(reduceMotion ? nil : DesignSystem.Animation.snappy, value: isHighlighted)
        .help("\(layout.displayName) — \(layout.tagline)")
        .accessibilityLabel("\(layout.displayName). \(layout.tagline)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Arrow keys walk the grid: left/right by one, up/down by a row.
    private func move(_ direction: MoveCommandDirection) {
        let cases = DashboardLayout.allCases
        guard !cases.isEmpty else { return }
        let current = cases.firstIndex(of: highlighted ?? selection) ?? 0
        let step: Int
        switch direction {
        case .left: step = -1
        case .right: step = 1
        case .up: step = -columns
        case .down: step = columns
        @unknown default: return
        }
        let next = (current + step + cases.count) % cases.count
        highlighted = cases[next]
    }
}

// MARK: - Wireframe

/// A vector sketch of a layout's *shape* — bars, columns, and blocks, no data.
///
/// The whole value of a preview gallery is that these are honestly different
/// from each other. Each one is drawn from the same primitive (a rounded bar) so
/// no layout gets a prettier thumbnail than another, and the differences you see
/// are exactly the differences in the compositions: Ledger's stack of equal
/// rules, Focus's one big block, Bento's uniform grid, Ask's field over a short
/// list, Cockpit's three circles, Canvas's single full bleed, Stream's spine, and
/// Atlas's two columns.
struct DashboardLayoutWireframe: View {
    let layout: DashboardLayout
    var accent: Color = DesignSystem.Colors.ember

    static func accent(for layout: DashboardLayout) -> Color {
        switch layout {
        case .classic: return DesignSystem.Colors.ember
        case .aurora: return DesignSystem.Colors.whimsy
        case .nebula: return DesignSystem.Colors.blaze
        case .constellation: return DesignSystem.Colors.ember
        case .cockpit: return DesignSystem.Colors.warning
        case .atelier: return DesignSystem.Colors.amber
        case .stream: return DesignSystem.Colors.amber
        case .atlas: return DesignSystem.Colors.success
        }
    }

    private var quiet: Color { DesignSystem.Colors.textSecondary.opacity(0.28) }

    var body: some View {
        Group {
            switch layout {
            case .classic: ledger
            case .aurora: focus
            case .nebula: bento
            case .constellation: ask
            case .cockpit: cockpit
            case .atelier: canvas
            case .stream: stream
            case .atlas: atlas
            }
        }
        .padding(8)
        .accessibilityHidden(true)
    }

    private func bar(_ height: CGFloat, _ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(color)
            .frame(height: height)
    }

    private func block(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(color)
    }

    /// Ordered rules, no hero.
    private var ledger: some View {
        VStack(spacing: 4) {
            ForEach(0..<7, id: \.self) { index in
                bar(3, index == 0 ? accent : quiet)
            }
        }
    }

    /// One block, dominant, with a couple of rows beneath it.
    private var focus: some View {
        VStack(spacing: 5) {
            block(accent.opacity(0.65))
                .frame(height: 30)
            bar(3, quiet)
            bar(3, quiet)
        }
    }

    /// A uniform grid — no cell larger than any other.
    private var bento: some View {
        VStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { column in
                        block(row == 0 && column == 0 ? accent.opacity(0.55) : quiet)
                    }
                }
            }
        }
    }

    /// A field on top, a short list under it.
    private var ask: some View {
        VStack(spacing: 6) {
            block(accent.opacity(0.5))
                .frame(height: 20)
            HStack(spacing: 4) {
                block(quiet).frame(height: 9)
                block(quiet).frame(height: 9)
            }
            bar(3, quiet)
            bar(3, quiet)
        }
    }

    /// Three dials over dense rows — the only wireframe with circles.
    private var cockpit: some View {
        VStack(spacing: 5) {
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .strokeBorder(index == 0 ? accent : quiet, lineWidth: 2)
                        .frame(height: 20)
                }
            }
            ForEach(0..<3, id: \.self) { _ in
                bar(2.5, quiet)
            }
        }
    }

    /// One full-bleed field, type over it.
    private var canvas: some View {
        ZStack(alignment: .bottomLeading) {
            block(accent.opacity(0.4))
            VStack(alignment: .leading, spacing: 3) {
                bar(3, accent).frame(width: 34)
                bar(2.5, quiet).frame(width: 22)
            }
            .padding(6)
        }
    }

    /// A spine down the left with entries branching off it.
    private var stream: some View {
        HStack(alignment: .top, spacing: 6) {
            Capsule()
                .fill(accent)
                .frame(width: 2)
            VStack(alignment: .leading, spacing: 5) {
                ForEach(0..<5, id: \.self) { index in
                    bar(2.5, quiet)
                        .frame(width: index.isMultiple(of: 2) ? 46 : 32)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// Two ranked columns, side by side.
    private var atlas: some View {
        HStack(spacing: 8) {
            ForEach(0..<2, id: \.self) { column in
                VStack(spacing: 5) {
                    ForEach(0..<5, id: \.self) { row in
                        bar(3, row == 0 && column == 0 ? accent : quiet)
                    }
                }
            }
        }
    }
}
