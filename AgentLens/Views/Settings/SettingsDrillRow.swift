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
    /// When set, a `ProviderQuotaChip` for this provider renders in the
    /// trailing region next to the existing `value` text. Self-hides when
    /// the provider has no quota signal yet, so rows stay clean.
    let quotaProvider: AgentProvider?
    /// Optional asset-catalog image name for a whimsical SVG icon. When
    /// provided, it renders inside the colored squircle instead of the
    /// SF Symbol.
    let customIcon: String?

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
        logoProviders: [AgentProvider] = [],
        quotaProvider: AgentProvider? = nil,
        customIcon: String? = nil
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
        self.quotaProvider = quotaProvider
        self.customIcon = customIcon
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
            .layoutPriority(1)

            Spacer(minLength: DesignSystem.Spacing.sm)

            if let quotaProvider {
                ProviderQuotaChip(provider: quotaProvider)
            }

            if let value, !value.isEmpty {
                Text(value)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(valueTint ?? DesignSystem.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 160, alignment: .trailing)
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
        SettingsIconTile(
            icon: icon,
            iconTint: iconTint,
            customIcon: customIcon
        )
    }
}

// MARK: - Settings Icon Tile

struct SettingsIconTile: View {
    let icon: String
    let iconTint: Color
    let customIcon: String?
    var size: CGFloat = 28
    var symbolSize: CGFloat = 14

    private var cornerRadius: CGFloat {
        size * 0.25
    }

    var body: some View {
        ZStack {
            if let customIcon {
                Image(customIcon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: size, height: size)
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(iconTint)
                Image(systemName: icon)
                    .font(.system(size: symbolSize, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
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

// MARK: - Shared detail-pane states

/// "Still loading" as a card, so a detail pane that is waiting on a listener
/// looks like the rest of the pane instead of an empty screen.
struct SettingsLoadingCard: View {
    let message: String

    var body: some View {
        GlassCard {
            HStack(spacing: DesignSystem.Spacing.sm) {
                ProgressView()
                    .controlSize(.small)
                Text(message)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            .padding(DesignSystem.Spacing.md)
        }
    }
}

/// "Nothing here yet, and here is why" — an empty state always explains what
/// would make it non-empty.
struct SettingsEmptyCard: View {
    let title: String
    let message: String

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text(title)
                    .font(DesignSystem.Typography.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(message)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignSystem.Spacing.md)
        }
    }
}

/// The small aureate capsule the Hermes surfaces use for "This Mac",
/// "Serving", and similar one-word states.
struct HermesPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(DesignSystem.Typography.tiny)
            .foregroundStyle(DesignSystem.Colors.hermesAureate)
            .padding(.horizontal, DesignSystem.Spacing.xs)
            .padding(.vertical, 1)
            .background(
                Capsule().stroke(DesignSystem.Colors.hermesAureate.opacity(0.6), lineWidth: 1)
            )
    }
}
