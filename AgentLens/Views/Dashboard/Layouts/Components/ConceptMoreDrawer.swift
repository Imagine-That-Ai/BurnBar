import SwiftUI

// MARK: - Concept "More" Drawer
//
// Collapsible drawer shown beneath each layout concept's hero so the curated
// concepts never *hide* the information-dense lanes (narrative banner, provider
// / model / activity rankings). The caller supplies the content — those lanes
// are `DashboardView` extension views, so they stay with the owning view and
// are injected here via a `@ViewBuilder`.
//
// Collapsed by default: a concept should read as its curated self first, with
// the full detail one click away.

struct ConceptMoreDrawer<Content: View>: View {
    var title: String = "More details"
    var systemImage: String = "rectangle.expand.vertical"
    @ViewBuilder var content: () -> Content

    @State private var expanded = false

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.lg) {
            toggle
            if expanded {
                content()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var toggle: some View {
        Button {
            withAnimation(DesignSystem.Animation.standard) { expanded.toggle() }
        } label: {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                Text(expanded ? "Hide details" : title)
                    .font(DesignSystem.Typography.caption)
                Spacer()
            }
            .foregroundStyle(DesignSystem.Colors.textSecondary)
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.sm)
            .background(Capsule().fill(.ultraThinMaterial))
            .overlay(Capsule().strokeBorder(DesignSystem.Colors.border.opacity(0.35), lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(expanded ? "Hide more details" : "Show more details")
    }
}
