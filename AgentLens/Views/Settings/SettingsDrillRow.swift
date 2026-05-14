import SwiftUI
import OpenBurnBarCore

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
    let logoProviders: [AgentProvider]

    init(
        icon: String,
        iconTint: Color,
        title: String,
        subtitle: String? = nil,
        value: String? = nil,
        valueTint: Color? = nil,
        badge: String? = nil,
        badgeTint: Color? = nil,
        logoProvider: AgentProvider? = nil,
        logoProviders: [AgentProvider] = []
    ) {
        self.icon = icon
        self.iconTint = iconTint
        self.title = title
        self.subtitle = subtitle
        self.value = value
        self.valueTint = valueTint
        self.badge = badge
        self.badgeTint = badgeTint
        if let logoProvider {
            self.logoProviders = [logoProvider]
        } else {
            self.logoProviders = logoProviders
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: DesignSystem.Spacing.md) {
            leadingMark

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

    @ViewBuilder
    private var leadingMark: some View {
        if logoProviders.isEmpty {
            iconSquircle
        } else if logoProviders.count == 1, let provider = logoProviders.first {
            ProviderLogoView(provider: provider, size: 28, useFallbackColor: true)
                .accessibilityHidden(true)
        } else {
            SettingsProviderLogoStack(providers: logoProviders, size: 24, maxVisible: 5)
                .accessibilityHidden(true)
        }
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

// MARK: - Provider Logo Stack

struct SettingsProviderLogoStack: View {
    let providers: [AgentProvider]
    var size: CGFloat = 24
    var maxVisible: Int = 5

    private var visibleProviders: [AgentProvider] {
        Array(providers.prefix(maxVisible))
    }

    var body: some View {
        HStack(spacing: -size * 0.28) {
            ForEach(visibleProviders) { provider in
                ProviderLogoView(provider: provider, size: size, useFallbackColor: true)
                    .background(
                        RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
                            .fill(DesignSystem.Colors.background)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
                            .stroke(DesignSystem.Colors.border.opacity(0.72), lineWidth: 0.8)
                    )
            }
        }
        .frame(width: stackWidth, height: size, alignment: .leading)
    }

    private var stackWidth: CGFloat {
        guard visibleProviders.count > 1 else { return size }
        return size + CGFloat(visibleProviders.count - 1) * size * 0.72
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
