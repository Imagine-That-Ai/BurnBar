import SwiftUI

/// Header band for an Insights page.
///
/// Renders the provider identity (logo, name, status, last-seen,
/// top-three model lineup) at the top of every per-agent Insights
/// surface. The same component renders on every platform; `roomy`
/// presentation widens the band and adds the model lineup row,
/// `compact` keeps the lineup as a compact chip so the band fits
/// above the iPhone fold.
public struct AgentInsightsHeaderView: View {
    public let header: AgentInsightsHeader
    public let presentation: AgentInsightsView.Presentation
    public var onTap: (() -> Void)?

    public init(
        header: AgentInsightsHeader,
        presentation: AgentInsightsView.Presentation,
        onTap: (() -> Void)? = nil
    ) {
        self.header = header
        self.presentation = presentation
        self.onTap = onTap
    }

    public var body: some View {
        let band = bandContents
        if let onTap {
            Button(action: onTap) { band }
                .buttonStyle(.plain)
                .accessibilityLabel("\(header.title) Insights. \(statusAccessibilityLabel)")
                .accessibilityHint("Double tap to pick a different agent.")
        } else {
            band
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(header.title) Insights. \(statusAccessibilityLabel)")
        }
    }

    private var bandContents: some View {
        HStack(alignment: .center, spacing: UnifiedDesignSystem.Spacing.md) {
            identityIcon
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: UnifiedDesignSystem.Spacing.sm) {
                    Text(header.title)
                        .font(presentation == .roomy
                              ? UnifiedDesignSystem.Typography.display
                              : UnifiedDesignSystem.Typography.title)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                    statusBadge
                }
                if let subtitle = header.subtitle {
                    Text(subtitle)
                        .font(UnifiedDesignSystem.Typography.caption)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                        .lineLimit(2)
                }
                lastSeenLine
                if presentation == .roomy {
                    modelLineupRow
                }
            }
            Spacer(minLength: 0)
            if presentation == .compact {
                compactLineupChip
            }
        }
        .padding(headerPadding)
        .background(
            RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.lg)
                .fill(UnifiedDesignSystem.Colors.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.lg)
                        .strokeBorder(borderTint, lineWidth: 0.75)
                )
        )
    }

    @ViewBuilder
    private var identityIcon: some View {
        if let provider = header.provider {
            UnifiedProviderLogoView(provider: provider, size: presentation == .roomy ? 64 : 44)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: presentation == .roomy ? 14 : 10, style: .continuous)
                    .fill(UnifiedDesignSystem.Colors.ember.opacity(0.12))
                Image(systemName: header.symbolName)
                    .font(.system(size: presentation == .roomy ? 28 : 22, weight: .semibold))
                    .foregroundStyle(UnifiedDesignSystem.Colors.ember)
            }
            .frame(width: presentation == .roomy ? 64 : 44,
                   height: presentation == .roomy ? 64 : 44)
        }
    }

    private var headerPadding: EdgeInsets {
        let vertical: CGFloat = presentation == .roomy
            ? UnifiedDesignSystem.Spacing.lg
            : UnifiedDesignSystem.Spacing.md
        return EdgeInsets(
            top: vertical,
            leading: UnifiedDesignSystem.Spacing.lg,
            bottom: vertical,
            trailing: UnifiedDesignSystem.Spacing.lg
        )
    }

    private var statusBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(header.status.displayLabel)
                .font(UnifiedDesignSystem.Typography.tiny)
                .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule(style: .continuous)
                .fill(statusColor.opacity(0.12))
        )
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var lastSeenLine: some View {
        if let lastSeen = header.lastSeen {
            Text("Last seen \(lastSeen.formatted(.relative(presentation: .named)))")
                .font(UnifiedDesignSystem.Typography.tiny)
                .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
        } else if header.status == .unconfigured {
            Text("No signal recorded for this agent yet.")
                .font(UnifiedDesignSystem.Typography.tiny)
                .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
        }
    }

    @ViewBuilder
    private var modelLineupRow: some View {
        if !header.modelLineup.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "circle.hexagongrid.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                Text(header.modelLineup.joined(separator: " · "))
                    .font(UnifiedDesignSystem.Typography.monoTiny)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.top, 2)
        }
    }

    @ViewBuilder
    private var compactLineupChip: some View {
        if let top = header.modelLineup.first {
            Text(top)
                .font(UnifiedDesignSystem.Typography.monoTiny)
                .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(UnifiedDesignSystem.Colors.surfaceElevated)
                )
        }
    }

    private var statusColor: Color {
        switch header.status {
        case .active: return UnifiedDesignSystem.Colors.success
        case .idle: return UnifiedDesignSystem.Colors.amber
        case .dormant: return UnifiedDesignSystem.Colors.textMuted
        case .unconfigured: return UnifiedDesignSystem.Colors.textMuted
        }
    }

    private var borderTint: Color {
        if let provider = header.provider {
            return UnifiedDesignSystem.Colors.primary(for: provider).opacity(0.25)
        }
        return UnifiedDesignSystem.Colors.borderSubtle
    }

    private var statusAccessibilityLabel: String {
        switch header.status {
        case .active: return "Active in the last 24 hours."
        case .idle: return "Idle but active this week."
        case .dormant: return "Dormant for over a week."
        case .unconfigured: return "Not connected yet."
        }
    }
}
