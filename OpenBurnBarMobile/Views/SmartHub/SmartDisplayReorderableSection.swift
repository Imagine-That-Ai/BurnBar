import OpenBurnBarCore
import SwiftUI

// MARK: - Smart Display Reorderable Section (iOS / iPadOS)
//
// Mirrors the macOS reorderable: each card is preceded by a grab strip
// the user can **touch and hold to drag the card** into a new slot.
// No edit mode, no chevrons.
//
// Why a dedicated grab strip and not the whole card: the card is full
// of toggles, sliders, and pickers. Letting the strip own `.draggable`
// keeps every form control inside the card responsive while still
// giving the user a single, obvious place to grab from.
//
// Drop targets sit between cards as thin lanes that highlight while a
// card is hovered over them. Persists changes through
// `SmartHubStore.updateDisplayOrder`.

struct SmartDisplayReorderableSection<Content: View>: View {
    @Bindable var smartHubStore: SmartHubStore
    let header: ((SmartDisplayKind, Int) -> AnyView)?
    let content: (SmartDisplayKind, Int) -> Content

    @State private var dragging: SmartDisplayKind?
    @State private var dropTarget: Int?

    init(
        smartHubStore: SmartHubStore,
        @ViewBuilder header: @escaping (SmartDisplayKind, Int) -> AnyView,
        @ViewBuilder content: @escaping (SmartDisplayKind, Int) -> Content
    ) {
        self.smartHubStore = smartHubStore
        self.header = header
        self.content = content
    }

    init(
        smartHubStore: SmartHubStore,
        @ViewBuilder content: @escaping (SmartDisplayKind, Int) -> Content
    ) {
        self.smartHubStore = smartHubStore
        self.header = nil
        self.content = content
    }

    var body: some View {
        let order = smartHubStore.displayOrder.kinds
        ForEach(Array(order.enumerated()), id: \.element) { index, kind in
            VStack(spacing: 0) {
                dropLane(at: index, total: order.count)
                grabStrip(for: kind, at: index)
                content(kind, index)
                if index == order.count - 1 {
                    dropLane(at: order.count, total: order.count)
                }
            }
            .opacity(dragging == kind ? 0.45 : 1)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            .listRowBackground(Color.clear)
            .animation(MobileTheme.Animation.gentle, value: order)
            .animation(MobileTheme.Animation.snappy, value: dropTarget)
        }
    }

    // MARK: - Grab strip

    @ViewBuilder
    private func grabStrip(for kind: SmartDisplayKind, at index: Int) -> some View {
        let header = self.header?(kind, index) ?? AnyView(defaultStrip(for: kind))
        header
            .padding(.bottom, MobileTheme.Spacing.xs)
            .contentShape(Rectangle())
            .draggable(kind.rawValue) {
                HStack(spacing: 6) {
                    Image(systemName: kind.symbolName)
                    Text(kind.displayName)
                        .font(MobileTheme.Typography.caption)
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

    private func defaultStrip(for kind: SmartDisplayKind) -> some View {
        HStack(spacing: MobileTheme.Spacing.sm) {
            Image(systemName: kind.symbolName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MobileTheme.Colors.textSecondary)
            Text(kind.displayName)
                .font(MobileTheme.Typography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
            Spacer(minLength: 0)
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(MobileTheme.Colors.textMuted)
                .accessibilityLabel("Drag handle. Touch and hold to move this display.")
        }
        .padding(.horizontal, MobileTheme.Spacing.xs)
    }

    // MARK: - Drop lanes

    @ViewBuilder
    private func dropLane(at index: Int, total: Int) -> some View {
        let active = dropTarget == index
        let isEdge = index == 0 || index == total

        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(active ? MobileTheme.whimsy : Color.clear)
            .frame(height: active ? 4 : (isEdge ? MobileTheme.Spacing.sm : MobileTheme.Spacing.md))
            .padding(.vertical, active ? 4 : 0)
            .padding(.horizontal, MobileTheme.Spacing.xs)
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
        var order = smartHubStore.displayOrder
        guard let source = order.kinds.firstIndex(of: kind) else { return }
        let destination: Int
        if slot > source {
            destination = max(0, slot - 1)
        } else {
            destination = slot
        }
        order.move(kind, to: destination)
        guard order != smartHubStore.displayOrder else {
            dropTarget = nil
            dragging = nil
            return
        }
        let snapshot = order
        Task { await smartHubStore.updateDisplayOrder(snapshot) }
        dropTarget = nil
        dragging = nil
    }
}
