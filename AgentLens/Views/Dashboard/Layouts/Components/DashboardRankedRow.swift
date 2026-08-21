import OpenBurnBarKernel
import OpenBurnBarUI
import SwiftUI

// MARK: - Ranked row
//
// One row of a ranked table: rank, mark, name, a quiet subtitle, a share bar,
// and the number. `Ledger`, `Atlas`, and `Cockpit` all render ranked lists, and
// before this existed each drew its own — which meant a provider's spend sat in
// a different column, at a different weight, in every layout that showed it.
//
// The row is deliberately *not* a card. It is a row inside a `DashboardSection`
// plate, separated from its neighbours by a `DashboardSectionRule`. That is the
// difference between a table and a mosaic.

struct DashboardRankedItem: Identifiable {
    let id: String
    let rank: Int
    let title: String
    var subtitle: String?
    let value: String
    /// 0...1 fraction of the list total this row represents.
    var share: Double = 0
    var accent: Color = DesignSystem.Colors.ember
    /// Drives the logo chip. `nil` renders a plain accent dot instead.
    var provider: AgentProvider?
    /// Signed change against a comparison basis the caller names.
    var delta: Double?
}

struct DashboardRankedRow: View {
    let item: DashboardRankedItem
    /// Show the numeric rank gutter. Off for lists where order is not the point.
    var showsRank: Bool = true
    /// Show the spend-share bar under the row.
    var showsShare: Bool = true
    var logoSize: CGFloat = 20
    var onSelect: (() -> Void)?

    @Environment(\.backdropInk) private var ink

    var body: some View {
        Group {
            if let onSelect {
                Button(action: onSelect) { rowBody }
                    .buttonStyle(.plain)
            } else {
                rowBody
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title), \(item.value)")
    }

    private var rowBody: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                if showsRank {
                    Text(item.rank.formatted())
                        .font(DesignSystem.Typography.monoSmall)
                        .foregroundStyle(ink.subtle)
                        .frame(width: 18, alignment: .trailing)
                        .accessibilityHidden(true)
                }
                mark
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(ink.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let subtitle = item.subtitle {
                        Text(subtitle)
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(ink.subtle)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: DesignSystem.Spacing.sm)
                if let delta = item.delta {
                    DashboardDeltaChip(delta: delta)
                }
                Text(item.value)
                    .font(DesignSystem.Typography.monoSmall)
                    .foregroundStyle(ink.primary)
                    .lineLimit(1)
            }
            if showsShare {
                shareBar
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var mark: some View {
        if let provider = item.provider {
            ProviderLogoView(provider: provider, size: logoSize, useFallbackColor: true)
        } else {
            Circle()
                .fill(item.accent)
                .frame(width: 8, height: 8)
                .frame(width: logoSize, alignment: .center)
        }
    }

    private var shareBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(ink.hairline)
                Capsule()
                    .fill(item.accent)
                    .frame(width: geo.size.width * CGFloat(max(0, min(1, item.share))))
            }
        }
        .frame(height: 3)
        .padding(.leading, showsRank ? 18 + DesignSystem.Spacing.sm : 0)
        .accessibilityHidden(true)
    }
}

// MARK: - Delta chip

/// A signed change, coloured by direction rather than by sentiment.
///
/// Deliberately *not* green-good / red-bad: on a spend dashboard "up" is not a
/// win, so the chip only says which way the number moved and leaves the judgment
/// to the reader. Rising spend gets the app's warm ramp, falling spend the cool
/// one, and a flat window gets neither.
struct DashboardDeltaChip: View {
    /// Signed fraction, e.g. `0.18` for +18%.
    let delta: Double

    @Environment(\.backdropInk) private var ink

    private var isFlat: Bool { abs(delta) < 0.005 }

    private var tint: Color {
        if isFlat { return ink.subtle }
        return delta > 0 ? DesignSystem.Colors.amber : DesignSystem.Colors.success
    }

    private var symbol: String {
        if isFlat { return "minus" }
        return delta > 0 ? "arrow.up.right" : "arrow.down.right"
    }

    private var label: String {
        isFlat ? "flat" : String(format: "%+.0f%%", delta * 100)
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .bold))
            Text(label)
                .font(DesignSystem.Typography.tiny)
                .fontWeight(.semibold)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(0.14)))
        .accessibilityLabel(isFlat ? "unchanged" : "\(Int((delta * 100).rounded())) percent")
    }
}

// MARK: - Ranked table

/// A ranked list rendered as rows separated by rules, with an empty state.
///
/// Exists so a layout writes `DashboardRankedTable(items: conceptProviderRows)`
/// instead of re-deriving `ForEach` + interleaved dividers + the empty case,
/// which is where the four existing layouts each drifted apart.
struct DashboardRankedTable: View {
    let items: [DashboardRankedItem]
    var showsRank: Bool = true
    var showsShare: Bool = true
    var limit: Int?
    var emptyMessage: String = "Nothing in this window yet."
    var onSelect: ((DashboardRankedItem) -> Void)?

    @Environment(\.backdropInk) private var ink

    private var visible: [DashboardRankedItem] {
        guard let limit else { return items }
        return Array(items.prefix(limit))
    }

    var body: some View {
        if visible.isEmpty {
            Text(emptyMessage)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(ink.subtle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, DesignSystem.Spacing.sm)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { DashboardSectionRule() }
                    DashboardRankedRow(
                        item: item,
                        showsRank: showsRank,
                        showsShare: showsShare,
                        onSelect: onSelect.map { select in { select(item) } }
                    )
                }
            }
        }
    }
}
