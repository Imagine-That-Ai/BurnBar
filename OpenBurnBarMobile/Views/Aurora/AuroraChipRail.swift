import SwiftUI

// MARK: - Aurora Chip Rail
//
// Horizontal segmented chip rail with `matchedGeometryEffect` selection pill.
// Used by Streams (Activity / Sessions / Projects) and any filter switching.

struct AuroraChipRail<Item: Hashable & Identifiable>: View {
    let items: [Item]
    let label: (Item) -> String
    let icon: ((Item) -> String?)?
    @Binding var selection: Item

    @Namespace private var pillNamespace

    init(
        items: [Item],
        selection: Binding<Item>,
        label: @escaping (Item) -> String,
        icon: ((Item) -> String?)? = nil
    ) {
        self.items = items
        self._selection = selection
        self.label = label
        self.icon = icon
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: MobileTheme.Spacing.xs) {
                ForEach(items) { item in
                    chip(item)
                }
            }
            .padding(.horizontal, MobileTheme.Spacing.lg)
            .padding(.vertical, MobileTheme.Spacing.xs)
        }
        .background(
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(MobileTheme.Colors.border.opacity(0.4), lineWidth: 0.5)
                )
                .padding(.horizontal, MobileTheme.Spacing.md)
        )
        .padding(.horizontal, MobileTheme.Spacing.md)
    }

    @ViewBuilder
    private func chip(_ item: Item) -> some View {
        let isSelected = selection == item
        Button {
            withAnimation(AuroraDesign.Motion.auroraSnap) {
                selection = item
            }
            HapticBus.chipChange()
        } label: {
            HStack(spacing: 6) {
                if let icon, let symbol = icon(item) {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(label(item))
                    .font(MobileTheme.Typography.caption)
                    .fontWeight(.semibold)
            }
            .padding(.horizontal, MobileTheme.Spacing.md)
            .padding(.vertical, 8)
            .foregroundStyle(isSelected ? .white : MobileTheme.Colors.textSecondary)
            .background {
                if isSelected {
                    Capsule(style: .continuous)
                        .fill(MobileTheme.primaryGradient)
                        .matchedGeometryEffect(id: "selection-pill", in: pillNamespace)
                        .shadow(color: MobileTheme.ember.opacity(0.40), radius: 8, y: 4)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
