import SwiftUI
import OpenBurnBarCore

// MARK: - Dashboard Layout Switcher
//
// The inline layout switcher — the prototype's top-rail concept switcher. A
// glass segmented control over `DashboardLayout.allCases` that collapses to a
// menu when horizontal space is tight (narrow windows / split divider parked
// left). Bound directly to `settingsManager.dashboardLayout`.

struct DashboardLayoutSwitcher: View {
    @Binding var selection: DashboardLayout

    var body: some View {
        ViewThatFits(in: .horizontal) {
            segmented
            menu
        }
        .animation(DesignSystem.Animation.standard, value: selection)
    }

    // MARK: Segmented (wide)

    private var segmented: some View {
        HStack(spacing: 3) {
            ForEach(DashboardLayout.allCases, id: \.self) { layout in
                segment(layout)
            }
        }
        .padding(4)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().strokeBorder(DesignSystem.Colors.border.opacity(0.4), lineWidth: 0.75))
    }

    private func segment(_ layout: DashboardLayout) -> some View {
        let isSelected = selection == layout
        return Button {
            selection = layout
        } label: {
            HStack(spacing: 5) {
                Image(systemName: layout.symbolName)
                    .font(.system(size: 10, weight: .semibold))
                Text(layout.displayName)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(isSelected ? Color.white : DesignSystem.Colors.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background {
                if isSelected {
                    Capsule().fill(DesignSystem.Colors.primaryGradient)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("\(layout.displayName) layout")
    }

    // MARK: Menu (narrow)

    private var menu: some View {
        Menu {
            ForEach(DashboardLayout.allCases, id: \.self) { layout in
                Button {
                    selection = layout
                } label: {
                    HStack {
                        Label(layout.displayName, systemImage: layout.symbolName)
                        if selection == layout { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: selection.symbolName)
                    .font(.system(size: 10, weight: .semibold))
                Text(selection.displayName)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(DesignSystem.Colors.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(.ultraThinMaterial))
            .overlay(Capsule().strokeBorder(DesignSystem.Colors.border.opacity(0.4), lineWidth: 0.75))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Dashboard layout")
    }
}
