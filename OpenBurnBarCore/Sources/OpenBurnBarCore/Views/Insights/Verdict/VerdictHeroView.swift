import SwiftUI

/// The always-present verdict hero — the dominant frame on the Insights
/// tab. Layout:
///
/// ```
///   [ stale chip | window chip ]
///   You spent $4.12 yesterday — 28% under your 4-week average.
///   Cache held at 91%.
///   [ provenance chip ]
///   ◯ Spend   ◯ Cache   ◯ Sessions   ▰▱▰▱▱  Yesterday
///   • bullet
///   • bullet
///   [ recommendation card if present ]
/// ```
///
/// The renderer is cross-platform; macOS pins it above the canvas grid,
/// iPad/iPhone scroll it as the first section. State lives with the
/// caller; this view is a value-type composition.
public struct VerdictHeroView: View {

    public var verdict: InsightVerdict
    public var isStale: Bool
    public var isDemo: Bool
    public var onRefresh: (() -> Void)?
    public var onCitationTap: (InsightCitation) -> Void
    public var onAcceptAction: (VerdictAcceptAction) -> Void
    public var onTraceTap: (String) -> Void
    public var onFollowUpTap: (String) -> Void

    public init(
        verdict: InsightVerdict,
        isStale: Bool = false,
        isDemo: Bool = false,
        onRefresh: (() -> Void)? = nil,
        onCitationTap: @escaping (InsightCitation) -> Void = { _ in },
        onAcceptAction: @escaping (VerdictAcceptAction) -> Void = { _ in },
        onTraceTap: @escaping (String) -> Void = { _ in },
        onFollowUpTap: @escaping (String) -> Void = { _ in }
    ) {
        self.verdict = verdict
        self.isStale = isStale
        self.isDemo = isDemo
        self.onRefresh = onRefresh
        self.onCitationTap = onCitationTap
        self.onAcceptAction = onAcceptAction
        self.onTraceTap = onTraceTap
        self.onFollowUpTap = onFollowUpTap
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public var body: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.lg) {
            chipRow
            headlineGroup
            VerdictProvenanceChip(provenance: verdict.provenance, isFallback: isDemo)
            VerdictRingsStrip(rings: verdict.rings)
            if let trace = verdict.sessionTrace {
                VerdictTraceStripView(strip: trace, onTapSession: onTraceTap)
            }
            if !verdict.bullets.isEmpty {
                VerdictBulletList(
                    bullets: verdict.bullets,
                    onCitationTap: onCitationTap,
                    onAcceptAction: { _, action in onAcceptAction(action) }
                )
            }
            if let recommendation = verdict.recommendation {
                recommendationCard(recommendation)
            }
            if !verdict.followUps.isEmpty {
                followUps
            }
        }
        .padding(UnifiedDesignSystem.Spacing.xl)
        .background(heroBackground)
        .overlay(heroBorder)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Subviews

    @ViewBuilder
    private var chipRow: some View {
        HStack(spacing: UnifiedDesignSystem.Spacing.sm) {
            chipPill(text: verdict.window.displayLabel,
                     systemImage: "calendar",
                     tint: UnifiedDesignSystem.Colors.textSecondary)
            if isDemo {
                chipPill(text: "Demo verdict",
                         systemImage: "sparkles",
                         tint: UnifiedDesignSystem.Colors.whimsy)
            } else if isStale {
                Button(action: { onRefresh?() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Stale · Refresh")
                            .font(UnifiedDesignSystem.Typography.tiny)
                    }
                    .padding(.horizontal, UnifiedDesignSystem.Spacing.sm)
                    .padding(.vertical, UnifiedDesignSystem.Spacing.xs)
                    .background(
                        Capsule().fill(UnifiedDesignSystem.Colors.warning.opacity(0.18))
                    )
                    .foregroundStyle(UnifiedDesignSystem.Colors.warning)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Refreshes the verdict in the background.")
            }
            Spacer(minLength: 0)
            confidenceBadge
        }
    }

    private func chipPill(text: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(UnifiedDesignSystem.Typography.tiny)
        }
        .padding(.horizontal, UnifiedDesignSystem.Spacing.sm)
        .padding(.vertical, UnifiedDesignSystem.Spacing.xs)
        .background(Capsule().fill(tint.opacity(0.12)))
        .foregroundStyle(tint)
    }

    private var confidenceBadge: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(i < confidenceDotCount
                          ? UnifiedDesignSystem.Colors.ember
                          : UnifiedDesignSystem.Colors.borderSubtle)
                    .frame(width: 5, height: 5)
            }
            Text("Confidence")
                .font(UnifiedDesignSystem.Typography.tiny)
                .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
        }
    }

    private var confidenceDotCount: Int {
        switch verdict.confidence {
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        }
    }

    @ViewBuilder
    private var headlineGroup: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.sm) {
            Text(verdict.headline)
                .font(UnifiedDesignSystem.Typography.display)
                .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                .multilineTextAlignment(.leading)
                .accessibilityAddTraits(.isHeader)
            if let subhead = verdict.subhead {
                Text(subhead)
                    .font(UnifiedDesignSystem.Typography.title)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                    .multilineTextAlignment(.leading)
            }
        }
    }

    @ViewBuilder
    private func recommendationCard(_ rec: VerdictRecommendation) -> some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.sm) {
            HStack(spacing: UnifiedDesignSystem.Spacing.xs) {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(UnifiedDesignSystem.Colors.ember)
                Text(rec.headline)
                    .font(UnifiedDesignSystem.Typography.headline)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                Spacer(minLength: 0)
                Text(rec.expectedImpact)
                    .font(UnifiedDesignSystem.Typography.monoSmall)
                    .foregroundStyle(UnifiedDesignSystem.Colors.ember)
            }
            Text(rec.rationale)
                .font(UnifiedDesignSystem.Typography.body)
                .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
            HStack(spacing: UnifiedDesignSystem.Spacing.xs) {
                ForEach(rec.citations) { cite in
                    Button(action: { onCitationTap(cite) }) {
                        Text(cite.label)
                            .font(UnifiedDesignSystem.Typography.tiny)
                            .padding(.horizontal, UnifiedDesignSystem.Spacing.xs)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(UnifiedDesignSystem.Colors.borderSubtle.opacity(0.6))
                            )
                            .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
                Button(action: { onAcceptAction(rec.acceptAction) }) {
                    HStack(spacing: 4) {
                        Text(rec.acceptAction.label)
                            .font(UnifiedDesignSystem.Typography.caption)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .padding(.horizontal, UnifiedDesignSystem.Spacing.sm)
                    .padding(.vertical, UnifiedDesignSystem.Spacing.xs)
                    .foregroundStyle(.white)
                    .background(
                        Capsule().fill(UnifiedDesignSystem.Colors.ember)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(UnifiedDesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md)
                .fill(UnifiedDesignSystem.Colors.ember.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md)
                        .stroke(UnifiedDesignSystem.Colors.ember.opacity(0.25), lineWidth: 1)
                )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Recommendation: \(rec.headline). \(rec.rationale). Impact: \(rec.expectedImpact).")
    }

    private var followUps: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.xs) {
            Text("Ask next")
                .font(UnifiedDesignSystem.Typography.tiny)
                .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                .textCase(.uppercase)
            ForEach(verdict.followUps, id: \.self) { question in
                Button(action: { onFollowUpTap(question) }) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .semibold))
                        Text(question)
                            .font(UnifiedDesignSystem.Typography.caption)
                    }
                    .foregroundStyle(UnifiedDesignSystem.Colors.whimsy)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var heroBackground: some View {
        RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.lg)
            .fill(UnifiedDesignSystem.Colors.surfaceElevated)
    }

    private var heroBorder: some View {
        RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.lg)
            .stroke(verdict.moodSwatch.color.opacity(0.25), lineWidth: 1)
    }
}
