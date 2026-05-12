import OpenBurnBarCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Smart Display Reorderable Container (macOS)
//
// Renders the Smart Displays section as a vertical stack of cards. To
// reorder, the user **clicks and holds the grab strip** at the top of
// any card and drags it onto the highlighted lane between cards.
//
// Why a dedicated grab strip instead of dragging the whole card:
//   Each card is full of interactive controls — pickers, toggles,
//   text fields, sliders. AppKit's `.draggable` on a full card would
//   fight those controls for the press gesture. Restricting drag to
//   the header strip means every control inside the card still works
//   normally, and the user has a clear, obvious "grab here" affordance.
//
// Drop targets are thin horizontal lanes between cards that highlight
// while the user hovers a dragged card over them.
//
// Persists into `SettingsManager.smartDisplayOrder` which the
// `SmartDisplayConfigPublisher` mirrors to Firestore so iOS sees the
// same arrangement on its next pull-to-refresh.

struct SmartDisplayReorderable<Content: View>: View {
    @Bindable var settingsManager: SettingsManager
    let header: (SmartDisplayKind, Int) -> AnyView
    let content: (SmartDisplayKind, Int) -> Content

    @State private var dragging: SmartDisplayKind?
    @State private var dropTarget: Int?

    init(
        settingsManager: SettingsManager,
        header: @escaping (SmartDisplayKind, Int) -> AnyView = { kind, _ in
            AnyView(SmartDisplayGrabStripDefault(kind: kind))
        },
        @ViewBuilder content: @escaping (SmartDisplayKind, Int) -> Content
    ) {
        self.settingsManager = settingsManager
        self.header = header
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(settingsManager.smartDisplayOrder.kinds.enumerated()), id: \.element) { index, kind in
                dropLane(at: index)
                card(for: kind, at: index)
            }
            dropLane(at: settingsManager.smartDisplayOrder.kinds.count)
        }
        .animation(DesignSystem.Animation.gentle, value: settingsManager.smartDisplayOrder.kinds)
        .animation(DesignSystem.Animation.snappy, value: dropTarget)
    }

    // MARK: - Card

    @ViewBuilder
    private func card(for kind: SmartDisplayKind, at index: Int) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            grabStrip(for: kind, at: index)
            content(kind, index)
        }
        .opacity(dragging == kind ? 0.45 : 1)
    }

    @ViewBuilder
    private func grabStrip(for kind: SmartDisplayKind, at index: Int) -> some View {
        header(kind, index)
            .contentShape(Rectangle())
            .help("Click and hold to drag this display into a new position")
            .draggable(kind.rawValue) {
                HStack(spacing: 6) {
                    Image(systemName: kind.symbolName)
                    Text(kind.displayName)
                        .font(DesignSystem.Typography.caption)
                }
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .onAppear { dragging = kind }
                .onDisappear {
                    dragging = nil
                    dropTarget = nil
                }
            }
    }

    // MARK: - Drop lanes

    @ViewBuilder
    private func dropLane(at index: Int) -> some View {
        let active = dropTarget == index
        let isEdge = index == 0 || index == settingsManager.smartDisplayOrder.kinds.count

        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(active ? DesignSystem.Colors.coral : Color.clear)
            .frame(height: active ? 4 : (isEdge ? DesignSystem.Spacing.md : DesignSystem.Spacing.lg))
            .padding(.vertical, active ? 4 : 0)
            .padding(.horizontal, DesignSystem.Spacing.xs)
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { items, _ in
                guard let raw = items.first, let kind = SmartDisplayKind(rawValue: raw) else {
                    return false
                }
                apply(move: kind, intoSlot: index)
                return true
            } isTargeted: { hovering in
                dropTarget = hovering ? index : (dropTarget == index ? nil : dropTarget)
            }
    }

    // MARK: - Move semantics

    private func apply(move kind: SmartDisplayKind, intoSlot slot: Int) {
        var order = settingsManager.smartDisplayOrder
        guard let source = order.kinds.firstIndex(of: kind) else { return }
        // A "slot" is a lane index meaning "insert before card N".
        // Convert it to the canonical move(_:to:) destination (which is
        // an array index after removal).
        let destination: Int
        if slot > source {
            destination = max(0, slot - 1)
        } else {
            destination = slot
        }
        order.move(kind, to: destination)
        if order != settingsManager.smartDisplayOrder {
            settingsManager.smartDisplayOrder = order
        }
        dropTarget = nil
        dragging = nil
    }
}

// MARK: - Default grab strip

/// Default grab strip used when callers don't override the header
/// builder. Caller-provided headers (e.g. `SmartDisplayCardLabel` in
/// `SmartDisplaysSection`) replace this entirely.
struct SmartDisplayGrabStripDefault: View {
    let kind: SmartDisplayKind

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: kind.symbolName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            Text(kind.displayName)
                .font(DesignSystem.Typography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            Spacer(minLength: 0)
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
        .padding(.horizontal, DesignSystem.Spacing.xs)
    }
}
