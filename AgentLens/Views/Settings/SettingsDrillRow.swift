import SwiftUI

// MARK: - iOS-Style Drill-Down Row

/// A reusable row that mimics the iOS Settings drill-down pattern:
/// a colored squircle icon, a primary label, an optional descriptive
/// subtitle, an optional value/status accessory, and a trailing chevron.
///
/// Designed to be the child of a `NavigationLink` inside a settings landing
/// view. The wrapping `NavigationLink` paints the highlight and supplies the
/// chevron when it lives inside a `List`, so the row only paints its own
/// content.
struct SettingsDrillRow: View {
    let icon: String
    let iconTint: Color
    let title: String
    let subtitle: String?
    let value: String?
    let valueTint: Color?
    let badge: String?
    let badgeTint: Color?

    init(
        icon: String,
        iconTint: Color,
        title: String,
        subtitle: String? = nil,
        value: String? = nil,
        valueTint: Color? = nil,
        badge: String? = nil,
        badgeTint: Color? = nil
    ) {
        self.icon = icon
        self.iconTint = iconTint
        self.title = title
        self.subtitle = subtitle
        self.value = value
        self.valueTint = valueTint
        self.badge = badge
        self.badgeTint = badgeTint
    }

    var body: some View {
        HStack(alignment: .center, spacing: DesignSystem.Spacing.md) {
            iconSquircle

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: DesignSystem.Spacing.xs) {
                    Text(title)
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .lineLimit(1)

                    if let badge {
                        Text(badge)
                            .font(DesignSystem.Typography.tiny)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background((badgeTint ?? DesignSystem.Colors.blaze).opacity(0.14))
                            .foregroundStyle(badgeTint ?? DesignSystem.Colors.blaze)
                            .clipShape(Capsule())
                    }
                }

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: DesignSystem.Spacing.sm)

            if let value, !value.isEmpty {
                Text(value)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(valueTint ?? DesignSystem.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, DesignSystem.Spacing.xs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var iconSquircle: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(iconTint)
                .frame(width: 28, height: 28)
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - iOS-Style Section Card

/// A focused subscreen container used by drill-down destinations. Provides
/// the title, an optional explanatory blurb, and a vertical scroll area for
/// section content. Mirrors the iOS detail screen layout (title at top,
/// grouped content cards below).
///
/// Pass `searchRoute` so the Settings search router can scroll to a specific
/// anchor when the user deep-links from the sidebar search field.
struct SettingsDetailContainer<Content: View>: View {
    let title: String
    let subtitle: String?
    let searchRoute: SettingsPageRoute?
    @ViewBuilder var content: Content

    init(
        title: String,
        subtitle: String? = nil,
        searchRoute: SettingsPageRoute? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.searchRoute = searchRoute
        self.content = content()
    }

    var body: some View {
        Group {
            if let searchRoute {
                SettingsDeepLinkScrollContainer(route: searchRoute) { _ in
                    scrollBody
                }
            } else {
                scrollBody
            }
        }
        .background(DesignSystem.Colors.background)
        .scrollContentBackground(.hidden)
        .navigationTitle(title)
    }

    private var scrollBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                if let subtitle {
                    Text(subtitle)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                content
            }
            .padding(DesignSystem.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
