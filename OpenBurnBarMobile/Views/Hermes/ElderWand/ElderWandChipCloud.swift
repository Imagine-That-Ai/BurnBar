import SwiftUI

// MARK: - Elder Wand chip cloud primitives (iOS)
//
// The wrap-style chip cloud the analysis (multi-select) and judge
// (single-select) sections share. The `MercuryBadgePicker` flow layout is
// `private` to its file, so this is a local re-implementation of the same
// minimal wrapping `Layout` (iOS 16+), plus a single chip styled from the
// design system. Kept self-contained so the configurator drops in without
// reaching into other features' internals.

/// Minimal wrapping flow layout for the configurator's chip clouds. Mirrors
/// the Mercury badge flow layout shape so the look matches across surfaces.
struct ElderWandFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth {
                totalHeight += rowHeight + spacing
                rowWidth = size.width + spacing
                rowHeight = size.height
            } else {
                rowWidth += size.width + spacing
                rowHeight = max(rowHeight, size.height)
            }
            totalWidth = max(totalWidth, rowWidth)
        }
        totalHeight += rowHeight
        return CGSize(width: totalWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                proposal: ProposedViewSize(size)
            )
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// One selectable model chip. A per-model color dot (from the design system's
/// `colorForModel`) gives each provider a recognizable accent without pulling
/// in logo views. Selection is conveyed by fill + accent stroke + a checkmark
/// (multi) / dot (single), and announced to VoiceOver via the selected trait.
struct ElderWandModelChip: View {
    let displayName: String
    let modelID: String
    let isSelected: Bool
    /// `true` for the multi-select panel (checkmark glyph), `false` for the
    /// single-select judge (filled dot glyph). Purely cosmetic.
    let isMultiSelect: Bool
    /// Dim + show a "not advertised" tone for saved ids no longer in the roster.
    var isOrphaned: Bool = false
    let action: () -> Void

    private var accent: Color {
        MobileTheme.Colors.colorForModel(modelID.isEmpty ? displayName : modelID)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle()
                    .fill(isOrphaned ? MobileTheme.Colors.textMuted : accent)
                    .frame(width: 8, height: 8)
                Text(displayName)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .lineLimit(1)
                if isSelected {
                    Image(systemName: isMultiSelect ? "checkmark" : "largecircle.fill.circle")
                        .font(.system(size: 11, weight: .bold))
                }
            }
            .foregroundStyle(isSelected ? MobileTheme.Colors.textPrimary : MobileTheme.Colors.textSecondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(MobileTheme.Colors.surfaceElevated.opacity(isSelected ? 0.95 : 0.55))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(
                                isSelected ? accent.opacity(0.85) : MobileTheme.Colors.border.opacity(0.4),
                                lineWidth: isSelected ? 1.2 : 0.6
                            )
                    )
            )
            .opacity(isOrphaned ? 0.6 : 1.0)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(displayName)
        .accessibilityValue(isOrphaned ? "Not advertised" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
