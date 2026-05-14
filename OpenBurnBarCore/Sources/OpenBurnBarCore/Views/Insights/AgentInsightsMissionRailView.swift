import SwiftUI

/// Horizontal rail of mission candidates ranked High → Low.
///
/// Each card surfaces the lens, priority badge, title, summary, and
/// expected impact line. Tapping fires the host platform's mission
/// dispatch flow.
public struct AgentInsightsMissionRailView: View {
    public let missions: [InsightMissionCandidate]
    public let presentation: AgentInsightsView.Presentation
    public var onTap: ((InsightMissionCandidate) -> Void)?

    public init(
        missions: [InsightMissionCandidate],
        presentation: AgentInsightsView.Presentation,
        onTap: ((InsightMissionCandidate) -> Void)? = nil
    ) {
        self.missions = missions
        self.presentation = presentation
        self.onTap = onTap
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.sm) {
            HStack(spacing: 6) {
                Image(systemName: "target")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                Text("Missions")
                    .font(UnifiedDesignSystem.Typography.tiny)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                Spacer(minLength: 0)
                Text("\(missions.count)")
                    .font(UnifiedDesignSystem.Typography.tiny)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: UnifiedDesignSystem.Spacing.md) {
                    ForEach(missions) { mission in
                        MissionCard(mission: mission, presentation: presentation, onTap: onTap)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

private struct MissionCard: View {
    let mission: InsightMissionCandidate
    let presentation: AgentInsightsView.Presentation
    let onTap: ((InsightMissionCandidate) -> Void)?

    private var width: CGFloat {
        presentation == .roomy ? 320 : 260
    }

    var body: some View {
        Button {
            onTap?(mission)
        } label: {
            VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.sm) {
                HStack(spacing: 6) {
                    priorityBadge
                    lensBadge
                    Spacer(minLength: 0)
                    effortBadge
                }
                Text(mission.title)
                    .font(UnifiedDesignSystem.Typography.headline)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(mission.summary)
                    .font(UnifiedDesignSystem.Typography.caption)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                if !mission.expectedImpact.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.right.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(UnifiedDesignSystem.Colors.ember)
                        Text(mission.expectedImpact)
                            .font(UnifiedDesignSystem.Typography.monoTiny)
                            .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
            }
            .padding(UnifiedDesignSystem.Spacing.md)
            .frame(width: width, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md)
                    .fill(UnifiedDesignSystem.Colors.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md)
                            .strokeBorder(priorityBorder, lineWidth: 0.75)
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(mission.priority.rawValue.capitalized) priority mission: \(mission.title). \(mission.summary)")
        .accessibilityHint("Double tap to dispatch this mission.")
    }

    private var priorityBadge: some View {
        Text(priorityLabel)
            .font(UnifiedDesignSystem.Typography.tiny)
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(priorityColor)
            )
    }

    private var lensBadge: some View {
        Text(lensLabel)
            .font(UnifiedDesignSystem.Typography.tiny)
            .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .stroke(UnifiedDesignSystem.Colors.borderSubtle, lineWidth: 0.5)
            )
    }

    private var effortBadge: some View {
        Text(effortLabel)
            .font(UnifiedDesignSystem.Typography.tiny)
            .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
    }

    private var priorityLabel: String {
        switch mission.priority {
        case .critical: return "Critical"
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        }
    }

    private var priorityColor: Color {
        switch mission.priority {
        case .critical: return UnifiedDesignSystem.Colors.error
        case .high: return UnifiedDesignSystem.Colors.ember
        case .medium: return UnifiedDesignSystem.Colors.amber
        case .low: return UnifiedDesignSystem.Colors.textMuted
        }
    }

    private var priorityBorder: Color {
        switch mission.priority {
        case .critical: return UnifiedDesignSystem.Colors.error.opacity(0.4)
        case .high: return UnifiedDesignSystem.Colors.ember.opacity(0.3)
        case .medium: return UnifiedDesignSystem.Colors.amber.opacity(0.3)
        case .low: return UnifiedDesignSystem.Colors.borderSubtle
        }
    }

    private var lensLabel: String {
        switch mission.lens {
        case .accretion: return "Accretion"
        case .diligence: return "Diligence"
        case .techDebt: return "Tech debt"
        case .routing: return "Routing"
        case .quota: return "Quota"
        case .focus: return "Focus"
        }
    }

    private var effortLabel: String {
        switch mission.effort {
        case .small: return "S"
        case .medium: return "M"
        case .large: return "L"
        }
    }
}
