import SwiftUI

// MARK: - QuotaFilterRail
//
// Sort + view-mode capsule strip. Persists sort/view-mode/show-inactive via
// AppStorage at the workspace level (held by the parent view).

struct QuotaFilterRail: View {
    @Binding var viewMode: QuotaViewMode
    @Binding var sort: QuotaSortMode
    @Binding var showInactive: Bool
    let isRefreshing: Bool
    var onRefreshAll: () -> Void

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            viewModeSegmented
            sortMenu
            showInactiveToggle
            Spacer()
            refreshAllButton
        }
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .padding(.vertical, DesignSystem.Spacing.sm)
    }

    private var viewModeSegmented: some View {
        HStack(spacing: 2) {
            ForEach(QuotaViewMode.allCases) { mode in
                let active = viewMode == mode
                Button {
                    withAnimation(DesignSystem.Animation.snappy) {
                        viewMode = mode
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: mode.systemImage)
                            .font(.system(size: 10, weight: .semibold))
                        Text(mode.label)
                            .font(.system(size: 11, weight: active ? .semibold : .medium, design: .rounded))
                    }
                    .foregroundStyle(
                        active
                            ? DesignSystem.Colors.textPrimary
                            : DesignSystem.Colors.textSecondary.opacity(0.85)
                    )
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4.5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(active
                                  ? AnyShapeStyle(DesignSystem.Colors.primaryGradient.opacity(0.18))
                                  : AnyShapeStyle(Color.clear))
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(active ? DesignSystem.Colors.ember.opacity(0.4) : Color.clear, lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .help(active ? mode.label : "Switch to \(mode.label)")
            }
        }
        .padding(2)
        .background(
            Capsule(style: .continuous).fill(DesignSystem.Colors.surface.opacity(0.55))
        )
        .overlay(
            Capsule(style: .continuous).stroke(DesignSystem.Colors.border.opacity(0.4), lineWidth: 0.5)
        )
    }

    private var sortMenu: some View {
        Menu {
            ForEach(QuotaSortMode.allCases) { mode in
                Button {
                    sort = mode
                } label: {
                    if sort == mode {
                        Label(mode.label, systemImage: "checkmark")
                    } else {
                        Label(mode.label, systemImage: mode.systemImage)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: sort.systemImage)
                    .font(.system(size: 10, weight: .semibold))
                Text("Sort · \(sort.label)")
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(0.7)
            }
            .foregroundStyle(DesignSystem.Colors.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous).fill(DesignSystem.Colors.surface.opacity(0.35))
            )
            .overlay(
                Capsule(style: .continuous).stroke(DesignSystem.Colors.border.opacity(0.55), lineWidth: 0.5)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var showInactiveToggle: some View {
        Button {
            showInactive.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: showInactive ? "eye" : "eye.slash")
                    .font(.system(size: 10, weight: .semibold))
                Text("Inactive plans")
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
            }
            .foregroundStyle(
                showInactive
                    ? DesignSystem.Colors.ember
                    : DesignSystem.Colors.textSecondary
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(showInactive
                          ? DesignSystem.Colors.ember.opacity(0.10)
                          : DesignSystem.Colors.surface.opacity(0.35))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(showInactive
                            ? DesignSystem.Colors.ember.opacity(0.45)
                            : DesignSystem.Colors.border.opacity(0.55),
                            lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .help(showInactive ? "Hide unconfigured providers" : "Show unconfigured providers")
    }

    private var refreshAllButton: some View {
        Button(action: onRefreshAll) {
            HStack(spacing: 6) {
                if isRefreshing {
                    AnimatedMiningPickView()
                        .frame(width: 14, height: 14)
                        .clipShape(.circle)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(isRefreshing ? "Refreshing…" : "Refresh all")
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(DesignSystem.Colors.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(DesignSystem.Colors.primaryGradient.opacity(0.18))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(DesignSystem.Colors.ember.opacity(0.45), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(isRefreshing)
        .help("Refresh every connected provider's quota")
    }
}
