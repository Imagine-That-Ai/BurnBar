import SwiftUI

/// Renders when an agent has no recorded signal *and* no scoped canvases.
/// Tells the user exactly which agent is empty and what would change that,
/// instead of the generic "no data yet".
public struct AgentInsightsEmptyStateView: View {
    public let header: AgentInsightsHeader

    public init(header: AgentInsightsHeader) {
        self.header = header
    }

    public var body: some View {
        VStack(spacing: UnifiedDesignSystem.Spacing.md) {
            Image(systemName: emptyIcon)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(UnifiedDesignSystem.Colors.ember)
            Text(title)
                .font(UnifiedDesignSystem.Typography.title)
                .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                .multilineTextAlignment(.center)
            Text(detail)
                .font(UnifiedDesignSystem.Typography.caption)
                .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .padding(UnifiedDesignSystem.Spacing.xl)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.lg)
                .fill(UnifiedDesignSystem.Colors.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.lg)
                        .strokeBorder(UnifiedDesignSystem.Colors.borderSubtle, lineWidth: 0.5)
                )
        )
    }

    private var emptyIcon: String {
        switch header.status {
        case .unconfigured: return "link.circle"
        case .dormant: return "moon.zzz"
        default: return "sparkles.tv"
        }
    }

    private var title: String {
        if let provider = header.provider {
            switch header.status {
            case .unconfigured: return "Connect \(provider.displayName) to see Insights"
            case .dormant: return "\(provider.displayName) is quiet"
            default: return "No saved canvases for \(provider.displayName) yet"
            }
        }
        return "No Insights yet"
    }

    private var detail: String {
        switch header.status {
        case .unconfigured:
            return "Once we see usage from this agent, the brief and KPIs will appear here automatically."
        case .dormant:
            return "We haven't seen activity in over a week. Start a session on this agent or pin a saved canvas to keep it on the radar."
        default:
            return "Try the composer to author a canvas, or pin a template scoped to this agent."
        }
    }
}
