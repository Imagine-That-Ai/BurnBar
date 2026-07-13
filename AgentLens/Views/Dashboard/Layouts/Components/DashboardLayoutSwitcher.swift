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
