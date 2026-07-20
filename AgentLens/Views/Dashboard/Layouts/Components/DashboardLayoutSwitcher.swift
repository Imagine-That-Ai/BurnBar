import SwiftUI
import OpenBurnBarCore

enum DashboardLayoutMetrics {
    static let contentMaxWidth: CGFloat = 1_360
}

// MARK: - Dashboard Layout Switcher
//
// The inline layout switcher — the prototype's top-rail concept switcher. A
// glass segmented control over `DashboardLayout.allCases` that collapses to a
// menu when horizontal space is tight (narrow windows / split divider parked
// left). Bound directly to `settingsManager.dashboardLayout`.

struct DashboardLayoutSwitcher: View {
    @Binding var selection: DashboardLayout
    var scale: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false
    @Namespace private var selectionAnimation

    var body: some View {
        HStack(spacing: 3) {
            if isExpanded {
                ForEach(DashboardLayout.allCases, id: \.self) { layout in
                    segment(layout)
                        .transition(
                            .asymmetric(
                                insertion: .scale(scale: 0.88, anchor: .leading).combined(with: .opacity),
                                removal: .opacity
                            )
                        )
                }
            } else {
                collapsedSelection
                    .transition(.scale(scale: 0.94, anchor: .leading).combined(with: .opacity))
            }
        }
        .padding(4 * scale)
        .background(Capsule().fill(DesignSystem.Colors.surface.opacity(0.34)))
        .overlay(Capsule().strokeBorder(DesignSystem.Colors.border.opacity(0.36), lineWidth: 0.65))
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .snappy(duration: 0.28), value: isExpanded)
        .animation(DesignSystem.Animation.standard, value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Dashboard layout")
    }

    private var collapsedSelection: some View {
        Button {
            withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .snappy(duration: 0.28)) {
                isExpanded = true
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: selection.symbolName)
                    .font(.system(size: 10 * scale, weight: .semibold))
                Text(selection.displayName)
                    .font(.system(size: 12 * scale, weight: .semibold, design: .rounded))
                Image(systemName: "chevron.right")
                    .font(.system(size: 8 * scale, weight: .bold))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            .foregroundStyle(DesignSystem.Colors.textPrimary)
            .padding(.horizontal, 12 * scale)
            .padding(.vertical, 6 * scale)
            .background {
                Capsule()
                    .fill(DesignSystem.Colors.ember.opacity(0.16))
                    .matchedGeometryEffect(id: "layoutSelection", in: selectionAnimation)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Show dashboard layouts")
        .accessibilityHint("Expands the layout choices")
    }

    private func segment(_ layout: DashboardLayout) -> some View {
        let isSelected = selection == layout
        return Button {
            withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .snappy(duration: 0.28)) {
                selection = layout
                isExpanded = false
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: layout.symbolName)
                    .font(.system(size: 10 * scale, weight: .semibold))
                Text(layout.displayName)
                    .font(.system(size: 12 * scale, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(isSelected ? Color.white : DesignSystem.Colors.textSecondary)
            .padding(.horizontal, 12 * scale)
            .padding(.vertical, 6 * scale)
            .background {
                if isSelected {
                    Capsule()
                        .fill(DesignSystem.Colors.primaryGradient)
                        .matchedGeometryEffect(id: "layoutSelection", in: selectionAnimation)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("\(layout.displayName) layout")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Dashboard Layout Shelf

/// Full-width dashboard chrome with a centered content rail. The backdrop stays
/// full-bleed, while the controls and the concept layouts share one visual edge.
struct DashboardLayoutShelf: View {
    @Binding var selection: DashboardLayout
    let rangeLabel: String
    let isRefreshing: Bool
    let canRefresh: Bool
    let lastRefresh: Date?
    let onRefresh: () -> Void

    private var refreshLabel: String {
        if isRefreshing { return "Refreshing spend…" }
        guard let lastRefresh else { return "Not refreshed yet" }
        return "Updated \(lastRefresh.formatted(date: .omitted, time: .shortened))"
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            wideContent
            compactContent
        }
        .frame(maxWidth: DashboardLayoutMetrics.contentMaxWidth)
        .padding(.horizontal, DesignSystem.Spacing.xl)
        .padding(.vertical, DesignSystem.Spacing.md)
        .frame(maxWidth: .infinity)
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(DesignSystem.Colors.borderSubtle.opacity(0.72))
                        .frame(height: 0.75)
                }
        }
        .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
    }

    private var wideContent: some View {
        HStack(spacing: DesignSystem.Spacing.xl) {
            shelfIdentity
                .frame(maxWidth: .infinity, alignment: .leading)

            layoutSwitcher
                .frame(maxWidth: .infinity, alignment: .center)

            shelfActions
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var compactContent: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            shelfIdentity
                .frame(maxWidth: .infinity, alignment: .leading)

            layoutSwitcher
            refreshButton(showTitle: false)
        }
    }

    private var shelfIdentity: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Circle()
                .fill(isRefreshing ? DesignSystem.Colors.ember : DesignSystem.Colors.success)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text("Overview")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(isRefreshing ? "Live spend" : refreshLabel)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Overview")
        .accessibilityValue(refreshLabel)
    }

    private var shelfActions: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            VStack(alignment: .trailing, spacing: 1) {
                Text(rangeLabel.uppercased())
                    .font(DesignSystem.Typography.tiny)
                    .fontWeight(.semibold)
                    .tracking(0.8)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                Text(refreshLabel)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineLimit(1)
            }

            refreshButton(showTitle: true)
        }
    }

    private var layoutSwitcher: some View {
        DashboardLayoutSwitcher(selection: $selection)
            .accessibilityIdentifier(OBBAccessibilityID.dashboardLayoutSwitcher)
    }

    private func refreshButton(showTitle: Bool) -> some View {
        Button(action: onRefresh) {
            HStack(spacing: DesignSystem.Spacing.xs) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11, weight: .semibold))
                    .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                    .animation(
                        isRefreshing
                            ? .linear(duration: 0.8).repeatForever(autoreverses: false)
                            : .default,
                        value: isRefreshing
                    )
                if showTitle {
                    Text(isRefreshing ? "Refreshing" : "Refresh")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                }
            }
            .foregroundStyle(isRefreshing ? DesignSystem.Colors.ember : DesignSystem.Colors.textSecondary)
            .padding(.horizontal, showTitle ? 9 : 7)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                    .fill(DesignSystem.Colors.surfaceElevated.opacity(0.42))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                    .strokeBorder(DesignSystem.Colors.border.opacity(0.35), lineWidth: 0.6)
            )
        }
        .buttonStyle(.plain)
        .disabled(!canRefresh || isRefreshing)
        .help(isRefreshing ? "Refreshing token spend" : "Refresh token spend")
        .accessibilityLabel(isRefreshing ? "Refreshing token spend" : "Refresh token spend")
        .accessibilityHint("Mines session logs and updates the dashboard.")
    }
}
