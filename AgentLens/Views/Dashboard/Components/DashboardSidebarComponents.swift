import AppKit
import SwiftUI
import WebKit
/// Context-aware color palette for sidebar content.
///
/// `DesignSystem.Colors.*` tokens resolve off the system `NSAppearance`, which
/// is correct for opaque surfaces but breaks for sidebar content that composites
/// over a dark Liquid Glass plate in light mode (aurora skin + live backdrop):
/// the tokens pick their light-mode hexes (dark text) and render black-on-black.
/// This resolver flips to guaranteed-legible dark-mode hexes when
/// `sidebarOnDarkGlass` is true, and delegates to the standard tokens otherwise.
struct SidebarSurfaceColors {
    let onDarkGlass: Bool

    /// Primary text — titles, selected labels.
    var textPrimary: Color {
        onDarkGlass ? Color(hex: "E6EDF3") : DesignSystem.Colors.textPrimary
    }

    /// Secondary text — subtitles, session counts.
    var textSecondary: Color {
        onDarkGlass ? Color(hex: "8B949E") : DesignSystem.Colors.textSecondary
    }

    /// Muted text — captions, "Not tracked" labels.
    var textMuted: Color {
        onDarkGlass ? Color(hex: "6E7681") : DesignSystem.Colors.textMuted
    }

    /// Elevated surface fill — the avatar circle and unselected row background.
    var surfaceElevated: Color {
        onDarkGlass ? Color(hex: "1F2630") : DesignSystem.Colors.surfaceElevated
    }

    /// Hairline border for unselected rows.
    var border: Color {
        onDarkGlass ? Color(hex: "30363D") : DesignSystem.Colors.border
    }

    /// Unselected row background fill (pre-opacity).
    var rowFill: Color {
        onDarkGlass ? Color.white : DesignSystem.Colors.surfaceElevated
    }

    /// Opacity for the unselected row background at rest.
    var rowFillOpacityResting: Double { onDarkGlass ? 0.06 : 0.35 }

    /// Opacity for the unselected row background on hover.
    var rowFillOpacityHover: Double { onDarkGlass ? 0.10 : 0.55 }
}
struct SidebarItem: View {
    let provider: AgentProvider?
    let isSelected: Bool
    let primaryMetric: String
    let totalCost: Double
    let sessionCount: Int
    let action: () -> Void

    @Environment(\.sidebarOnDarkGlass) private var onDarkGlass
    @Environment(\.dashboardLiveBackdropActive) private var liveBackdropActive
    @State private var hovering = false

    private var theme: ProviderTheme {
        provider.map { ProviderTheme.theme(for: $0) } ?? ProviderTheme.theme(for: .factory)
    }

    private var surface: SidebarSurfaceColors { SidebarSurfaceColors(onDarkGlass: onDarkGlass) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignSystem.Spacing.md) {
                ZStack {
                    Circle()
                        .fill(isSelected ? theme.primaryColor.opacity(0.18) : surface.surfaceElevated)
                        .frame(width: 34, height: 34)

                    if let provider {
                        ProviderLogoView(provider: provider, size: 22, useFallbackColor: false)
                    } else {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(isSelected ? surface.textPrimary : surface.textSecondary)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(provider?.displayName ?? "All Providers")
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(isSelected ? surface.textPrimary : surface.textSecondary)
                        .lineLimit(1)

                    Text("\(sessionCount) session\(sessionCount == 1 ? "" : "s")")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(surface.textMuted)
                }
                .layoutPriority(1)

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    if provider?.supportLevel == .unsupported && totalCost == 0 {
                        Text("Not tracked")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(surface.textMuted)
                    } else {
                        Text(primaryMetric)
                            .font(DesignSystem.Typography.monoSmall)
                            .foregroundStyle(isSelected ? theme.primaryColor : surface.textMuted)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .allowsTightening(true)
                    }

                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(isSelected ? theme.primaryColor.opacity(0.8) : surface.textMuted)
                }
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.sm)
            .background { sidebarTileBackground(theme: theme, surface: surface, isSelected: isSelected, hovering: hovering, live: liveBackdropActive) }
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md)
                    .stroke(isSelected ? theme.primaryColor.opacity(0.3) : surface.border.opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(DesignSystem.Animation.hover, value: hovering)
    }
}

/// Sidebar row plate. Over a live pixel backdrop the fill becomes a real
/// `.ultraThinMaterial` plate so the animated backdrop refracts through the
/// tile instead of the tile reading as an opaque black/gray box; without a live
/// backdrop it keeps the previous solid surface fill exactly.
@ViewBuilder
func sidebarTileBackground(
    theme: ProviderTheme,
    surface: SidebarSurfaceColors,
    isSelected: Bool,
    hovering: Bool,
    live: Bool
) -> some View {
    let shape = RoundedRectangle(cornerRadius: DesignSystem.Radius.md)
    if live {
        ZStack {
            shape.fill(.ultraThinMaterial)
            if isSelected {
                shape.fill(theme.primaryColor.opacity(0.16))
            } else if hovering {
                shape.fill(Color.white.opacity(0.06))
            }
        }
    } else {
        shape.fill(isSelected
                   ? theme.primaryColor.opacity(0.08)
                   : surface.rowFill.opacity(hovering ? surface.rowFillOpacityHover : surface.rowFillOpacityResting))
    }
}

// MARK: - Model Sidebar Item

struct ModelSidebarItem: View {
    let summary: ModelSummary
    let isSelected: Bool
    let action: () -> Void

    @Environment(SettingsManager.self) private var settingsManager
    @Environment(\.sidebarOnDarkGlass) private var onDarkGlass
    @Environment(\.dashboardLiveBackdropActive) private var liveBackdropActive

    @State private var hovering = false

    private var theme: ProviderTheme { ProviderTheme.theme(forModel: summary.modelName) }
    private var surface: SidebarSurfaceColors { SidebarSurfaceColors(onDarkGlass: onDarkGlass) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignSystem.Spacing.md) {
                ZStack {
                    Circle()
                        .fill(isSelected ? theme.primaryColor.opacity(0.18) : surface.surfaceElevated)
                        .frame(width: 34, height: 34)

                    ModelProviderLogoView(
                        modelKey: summary.modelName,
                        size: 22,
                        fallbackSymbolColor: isSelected ? theme.primaryColor : surface.textSecondary
                    )
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.displayName)
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(isSelected ? surface.textPrimary : surface.textSecondary)
                        .lineLimit(1)

                    Text("\(summary.sessionCount) session\(summary.sessionCount == 1 ? "" : "s")")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(surface.textMuted)
                }
                .layoutPriority(1)

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(settingsManager.formatUsageMetric(cost: summary.totalCost, tokens: summary.totalTokens))
                        .font(DesignSystem.Typography.monoSmall)
                        .foregroundStyle(isSelected ? theme.primaryColor : surface.textMuted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .allowsTightening(true)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(isSelected ? theme.primaryColor.opacity(0.8) : surface.textMuted)
                }
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.sm)
            .background { sidebarTileBackground(theme: theme, surface: surface, isSelected: isSelected, hovering: hovering, live: liveBackdropActive) }
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md)
                    .stroke(isSelected ? theme.primaryColor.opacity(0.3) : surface.border.opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(DesignSystem.Animation.hover, value: hovering)
    }
}

// MARK: - Workspace nav (main pane)

struct DashboardWorkspaceNavButton: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let accent: Color
    let isSelected: Bool
    var trailingBadge: String?
    var isCompact: Bool = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: DesignSystem.Spacing.sm) {
                ZStack {
                    Circle()
                        .fill(isSelected ? accent.opacity(0.18) : DesignSystem.Colors.surfaceElevated)
                        .frame(width: 30, height: 30)

                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isSelected ? accent : DesignSystem.Colors.textSecondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        Text(title)
                            .font(DesignSystem.Typography.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(isSelected ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary)
                            .lineLimit(1)

                        if let trailingBadge {
                            Text(trailingBadge)
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.amber)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(DesignSystem.Colors.amber.opacity(0.15))
                                .clipShape(Capsule())
                            }
                    }

                    if !isCompact {
                        Text(subtitle)
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .multilineTextAlignment(.leading)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .allowsTightening(true)
                    }
                }
                .layoutPriority(1)
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.sm)
            .frame(
                minWidth: isCompact ? 106 : 150,
                idealWidth: isCompact ? 116 : 176,
                maxWidth: isCompact ? 132 : 220,
                alignment: .leading
            )
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(isSelected ? accent.opacity(0.08) : DesignSystem.Colors.surfaceElevated.opacity(hovering ? 0.55 : 0.35))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .stroke(isSelected ? accent.opacity(0.3) : DesignSystem.Colors.border.opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(DesignSystem.Animation.hover, value: hovering)
    }
}

// MARK: - Stat Card
