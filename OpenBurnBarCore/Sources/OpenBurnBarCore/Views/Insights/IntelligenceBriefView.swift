import SwiftUI

/// Cross-platform Intelligence Brief — the analysis-first landing surface on
/// every Insights screen.
///
/// Renders an `InsightAnalysisResult` as a structured story:
/// 1. Hero: executive summary + model attribution + budget badge.
/// 2. Findings: top finding cards with severity + confidence + evidence chips.
/// 3. Anomalies: ranked chips (score-sorted).
/// 4. Recommendations: action cards with estimated impact + cited evidence.
/// 5. Generated widgets: inline rendering through `InsightWidgetRenderer`.
/// 6. Follow-up questions: tappable suggestion chips.
///
/// The view is a value-type wrapper around its callbacks so platform shells
/// (macOS 3-pane workspace, iOS/iPadOS navigation stack, embedded preview
/// surfaces) can drop it in identically. No `@StateObject` — state lives
/// with the caller.
public struct IntelligenceBriefView: View {
    public let result: InsightAnalysisResult
    public let onCitationTap: (InsightCitation) -> Void
    public let onFollowUpTap: (InsightFollowUpQuestion) -> Void
    public let onPinWidget: (InsightGeneratedWidget) -> Void
    public let onConfigureModel: (() -> Void)?
    public let onShowAudit: (() -> Void)?

    public init(
        result: InsightAnalysisResult,
        onCitationTap: @escaping (InsightCitation) -> Void = { _ in },
        onFollowUpTap: @escaping (InsightFollowUpQuestion) -> Void = { _ in },
        onPinWidget: @escaping (InsightGeneratedWidget) -> Void = { _ in },
        onConfigureModel: (() -> Void)? = nil,
        onShowAudit: (() -> Void)? = nil
    ) {
        self.result = result
        self.onCitationTap = onCitationTap
        self.onFollowUpTap = onFollowUpTap
        self.onPinWidget = onPinWidget
        self.onConfigureModel = onConfigureModel
        self.onShowAudit = onShowAudit
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.lg) {
                hero
                if !result.findings.isEmpty {
                    sectionHeader("Top findings", systemImage: "sparkles")
                    LazyVStack(spacing: UnifiedDesignSystem.Spacing.sm) {
                        ForEach(result.findings) { finding in
                            FindingCard(
                                finding: finding,
                                onCitationTap: onCitationTap
                            )
                        }
                    }
                }
                if !result.anomalies.isEmpty {
                    sectionHeader("Anomalies", systemImage: "exclamationmark.triangle")
                    AnomalyRow(anomalies: result.anomalies, onCitationTap: onCitationTap)
                }
                if !result.recommendations.isEmpty {
                    sectionHeader("Recommendations", systemImage: "lightbulb")
                    LazyVStack(spacing: UnifiedDesignSystem.Spacing.sm) {
                        ForEach(result.recommendations) { recommendation in
                            RecommendationCard(
                                recommendation: recommendation,
                                onCitationTap: onCitationTap
                            )
                        }
                    }
                }
                if !result.generatedWidgets.isEmpty {
                    sectionHeader("Generated views", systemImage: "rectangle.3.group")
                    LazyVStack(spacing: UnifiedDesignSystem.Spacing.sm) {
                        ForEach(result.generatedWidgets) { generated in
                            GeneratedWidgetRow(
                                generated: generated,
                                onPin: onPinWidget,
                                onCitationTap: onCitationTap
                            )
                        }
                    }
                }
                if !result.followUpQuestions.isEmpty {
                    sectionHeader("Follow-up questions", systemImage: "questionmark.bubble")
                    FollowUpChipsRow(
                        questions: result.followUpQuestions,
                        onTap: onFollowUpTap
                    )
                }
                auditFooter
            }
            .padding(UnifiedDesignSystem.Spacing.lg)
        }
        .background(UnifiedDesignSystem.Colors.surface.ignoresSafeArea())
    }

    // MARK: - Hero

    @ViewBuilder
    private var hero: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.md) {
            HStack(spacing: UnifiedDesignSystem.Spacing.sm) {
                Image(systemName: "sparkles.tv")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(UnifiedDesignSystem.Colors.ember)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Intelligence Brief")
                        .font(UnifiedDesignSystem.Typography.title)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                    Text(IntelligenceBriefFormatting.windowLabel(result.timeWindow))
                        .font(UnifiedDesignSystem.Typography.caption)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                }
                Spacer(minLength: 0)
                if let onConfigureModel {
                    Button(action: onConfigureModel) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Configure model")
                }
            }

            Text(result.executiveSummary)
                .font(UnifiedDesignSystem.Typography.body)
                .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: UnifiedDesignSystem.Spacing.sm) {
                ModelChip(modelTag: result.modelTag)
                BudgetChip(budget: result.contextBudget)
                if let usage = result.tokenUsage {
                    TokenUsageChip(usage: usage, costUSD: result.estimatedCostUSD)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(UnifiedDesignSystem.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.lg, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.lg, style: .continuous)
                        .stroke(UnifiedDesignSystem.Colors.borderSubtle, lineWidth: 0.5)
                )
        )
    }

    // MARK: - Section headers

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        HStack(spacing: UnifiedDesignSystem.Spacing.xs) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
            Text(title)
                .font(UnifiedDesignSystem.Typography.headline)
                .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
            Spacer(minLength: 0)
        }
        .padding(.top, UnifiedDesignSystem.Spacing.xs)
    }

    // MARK: - Footer

    private var auditFooter: some View {
        HStack(spacing: UnifiedDesignSystem.Spacing.xs) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 11, weight: .regular))
            Text(IntelligenceBriefFormatting.auditFooter(result))
                .font(UnifiedDesignSystem.Typography.tiny)
                .lineLimit(2)
            Spacer(minLength: 0)
            if let onShowAudit {
                Button("Audit log") { onShowAudit() }
                    .buttonStyle(.borderless)
                    .font(UnifiedDesignSystem.Typography.tiny)
            }
        }
        .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
        .padding(.top, UnifiedDesignSystem.Spacing.md)
    }
}

// MARK: - Subviews

private struct FindingCard: View {
    let finding: InsightFinding
    let onCitationTap: (InsightCitation) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.xs) {
            HStack(spacing: UnifiedDesignSystem.Spacing.xs) {
                SeverityChip(severity: finding.severity)
                ConfidenceChip(confidence: finding.confidence)
                Spacer(minLength: 0)
            }
            Text(finding.title)
                .font(UnifiedDesignSystem.Typography.headline)
                .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(finding.whyItMatters)
                .font(UnifiedDesignSystem.Typography.body)
                .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if !finding.evidence.isEmpty {
                CitationChipRow(citations: finding.evidence, onTap: onCitationTap)
            }
            if !finding.recommendedAction.isEmpty {
                ActionStripe(action: finding.recommendedAction)
            }
        }
        .padding(UnifiedDesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md, style: .continuous)
                        .stroke(UnifiedDesignSystem.Colors.borderSubtle, lineWidth: 0.5)
                )
        )
    }
}

private struct AnomalyRow: View {
    let anomalies: [InsightAnomaly]
    let onCitationTap: (InsightCitation) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: UnifiedDesignSystem.Spacing.sm) {
                ForEach(anomalies) { anomaly in
                    AnomalyChip(anomaly: anomaly, onCitationTap: onCitationTap)
                }
            }
            .padding(.horizontal, 1)
        }
    }
}

private struct AnomalyChip: View {
    let anomaly: InsightAnomaly
    let onCitationTap: (InsightCitation) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(UnifiedDesignSystem.Colors.warning)
                Text(anomaly.title)
                    .font(UnifiedDesignSystem.Typography.caption)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                    .lineLimit(2)
            }
            Text(anomaly.detail)
                .font(UnifiedDesignSystem.Typography.tiny)
                .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                .lineLimit(3)
            HStack(spacing: 4) {
                Text(String(format: "z %.1f", anomaly.score))
                    .font(UnifiedDesignSystem.Typography.tiny)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                ConfidenceChip(confidence: anomaly.confidence)
            }
        }
        .padding(UnifiedDesignSystem.Spacing.sm)
        .frame(maxWidth: 220, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md, style: .continuous)
                        .stroke(UnifiedDesignSystem.Colors.borderSubtle, lineWidth: 0.5)
                )
        )
        .onTapGesture {
            if let first = anomaly.evidence.first {
                onCitationTap(first)
            }
        }
    }
}

private struct RecommendationCard: View {
    let recommendation: InsightRecommendation
    let onCitationTap: (InsightCitation) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.xs) {
            HStack(spacing: UnifiedDesignSystem.Spacing.xs) {
                Image(systemName: "lightbulb.fill")
                    .foregroundStyle(UnifiedDesignSystem.Colors.whimsy)
                    .font(.system(size: 12, weight: .semibold))
                SeverityChip(severity: recommendation.severity)
                ConfidenceChip(confidence: recommendation.confidence)
                Spacer(minLength: 0)
            }
            Text(recommendation.title)
                .font(UnifiedDesignSystem.Typography.headline)
                .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(recommendation.rationale)
                .font(UnifiedDesignSystem.Typography.body)
                .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ActionStripe(action: recommendation.recommendedAction)
            if let impact = recommendation.estimatedImpact {
                Label(impact, systemImage: "arrow.up.right.circle.fill")
                    .font(UnifiedDesignSystem.Typography.caption)
                    .foregroundStyle(UnifiedDesignSystem.Colors.success)
            }
            if !recommendation.evidence.isEmpty {
                CitationChipRow(citations: recommendation.evidence, onTap: onCitationTap)
            }
        }
        .padding(UnifiedDesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md, style: .continuous)
                        .stroke(UnifiedDesignSystem.Colors.borderSubtle, lineWidth: 0.5)
                )
        )
    }
}

private struct GeneratedWidgetRow: View {
    let generated: InsightGeneratedWidget
    let onPin: (InsightGeneratedWidget) -> Void
    let onCitationTap: (InsightCitation) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.xs) {
            HStack(spacing: UnifiedDesignSystem.Spacing.xs) {
                Image(systemName: generated.widget.kind.symbolName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                Text(generated.widget.title)
                    .font(UnifiedDesignSystem.Typography.headline)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                Spacer(minLength: 0)
                Button {
                    onPin(generated)
                } label: {
                    Label("Pin to canvas", systemImage: "pin.fill")
                        .font(UnifiedDesignSystem.Typography.tiny)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Pin to canvas")
            }
            InsightWidgetRenderer(widget: generated.widget)
                .frame(minHeight: 140)
            if !generated.citations.isEmpty {
                CitationChipRow(citations: generated.citations, onTap: onCitationTap)
            }
            if !generated.reason.isEmpty {
                Text(generated.reason)
                    .font(UnifiedDesignSystem.Typography.tiny)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(UnifiedDesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md, style: .continuous)
                        .stroke(UnifiedDesignSystem.Colors.borderSubtle, lineWidth: 0.5)
                )
        )
    }
}

private struct FollowUpChipsRow: View {
    let questions: [InsightFollowUpQuestion]
    let onTap: (InsightFollowUpQuestion) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: UnifiedDesignSystem.Spacing.xs) {
                ForEach(questions) { question in
                    Button {
                        onTap(question)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "questionmark.bubble.fill")
                                .font(.system(size: 11, weight: .medium))
                            Text(question.question)
                                .font(UnifiedDesignSystem.Typography.caption)
                                .lineLimit(2)
                        }
                        .padding(.horizontal, UnifiedDesignSystem.Spacing.sm)
                        .padding(.vertical, UnifiedDesignSystem.Spacing.xs)
                        .background(
                            Capsule()
                                .fill(UnifiedDesignSystem.Colors.whimsy.opacity(0.12))
                        )
                        .foregroundStyle(UnifiedDesignSystem.Colors.whimsy)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(question.rationale ?? "Ask this follow-up")
                }
            }
        }
    }
}

// MARK: - Chips

private struct ModelChip: View {
    let modelTag: InsightModelTag

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: modelTag.egressTier.symbolName)
                .font(.system(size: 10, weight: .medium))
            Text(modelTag.displayName)
                .font(UnifiedDesignSystem.Typography.caption)
            Text("·")
                .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
            Text(modelTag.egressTier.displayLabel)
                .font(UnifiedDesignSystem.Typography.tiny)
                .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
        }
        .padding(.horizontal, UnifiedDesignSystem.Spacing.sm)
        .padding(.vertical, UnifiedDesignSystem.Spacing.xs)
        .background(
            Capsule()
                .fill(UnifiedDesignSystem.Colors.textSecondary.opacity(0.10))
        )
        .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
    }
}

private struct BudgetChip: View {
    let budget: InsightContextBudgetReport

    var body: some View {
        let label = IntelligenceBriefFormatting.budgetLabel(budget)
        return HStack(spacing: 4) {
            Image(systemName: "tray.full")
                .font(.system(size: 10, weight: .medium))
            Text(label)
                .font(UnifiedDesignSystem.Typography.tiny)
        }
        .padding(.horizontal, UnifiedDesignSystem.Spacing.sm)
        .padding(.vertical, UnifiedDesignSystem.Spacing.xs)
        .background(
            Capsule()
                .fill(UnifiedDesignSystem.Colors.textSecondary.opacity(0.08))
        )
        .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
        .accessibilityLabel("Context budget \(label)")
    }
}

private struct TokenUsageChip: View {
    let usage: InsightTokenUsage
    let costUSD: Double?

    var body: some View {
        let label = IntelligenceBriefFormatting.tokenUsageLabel(usage, cost: costUSD)
        return HStack(spacing: 4) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 10, weight: .medium))
            Text(label)
                .font(UnifiedDesignSystem.Typography.tiny)
        }
        .padding(.horizontal, UnifiedDesignSystem.Spacing.sm)
        .padding(.vertical, UnifiedDesignSystem.Spacing.xs)
        .background(
            Capsule()
                .fill(UnifiedDesignSystem.Colors.success.opacity(0.10))
        )
        .foregroundStyle(UnifiedDesignSystem.Colors.success)
    }
}

private struct SeverityChip: View {
    let severity: InsightSeverity

    var body: some View {
        let (color, label) = palette
        return Text(label.uppercased())
            .font(UnifiedDesignSystem.Typography.tiny)
            .fontWeight(.bold)
            .padding(.horizontal, UnifiedDesignSystem.Spacing.xs)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(color.opacity(0.12))
            )
            .foregroundStyle(color)
    }

    private var palette: (Color, String) {
        switch severity {
        case .info: return (UnifiedDesignSystem.Colors.textMuted, "info")
        case .low: return (UnifiedDesignSystem.Colors.whimsy, "low")
        case .medium: return (UnifiedDesignSystem.Colors.warning, "medium")
        case .high: return (UnifiedDesignSystem.Colors.ember, "high")
        case .critical: return (UnifiedDesignSystem.Colors.error, "critical")
        }
    }
}

private struct ConfidenceChip: View {
    let confidence: InsightConfidence

    var body: some View {
        Text("•••".prefix(confidenceDots))
            .font(UnifiedDesignSystem.Typography.tiny)
            .fontWeight(.bold)
            .foregroundStyle(UnifiedDesignSystem.Colors.whimsy)
            .padding(.horizontal, UnifiedDesignSystem.Spacing.xs)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(UnifiedDesignSystem.Colors.whimsy.opacity(0.10))
            )
            .accessibilityLabel("Confidence \(confidence.rawValue)")
    }

    private var confidenceDots: Int {
        switch confidence {
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        }
    }
}

private struct CitationChipRow: View {
    let citations: [InsightCitation]
    let onTap: (InsightCitation) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(citations.prefix(6), id: \.id) { citation in
                    Button {
                        onTap(citation)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: citation.kind.symbolName)
                                .font(.system(size: 9, weight: .medium))
                            Text(citation.label)
                                .font(UnifiedDesignSystem.Typography.tiny)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, UnifiedDesignSystem.Spacing.xs)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(UnifiedDesignSystem.Colors.textSecondary.opacity(0.08))
                        )
                        .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Open evidence")
                }
            }
        }
    }
}

private struct ActionStripe: View {
    let action: String

    var body: some View {
        HStack(alignment: .top, spacing: UnifiedDesignSystem.Spacing.xs) {
            Image(systemName: "arrow.right.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(UnifiedDesignSystem.Colors.whimsy)
                .padding(.top, 1)
            Text(action)
                .font(UnifiedDesignSystem.Typography.caption)
                .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, UnifiedDesignSystem.Spacing.sm)
        .padding(.vertical, UnifiedDesignSystem.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.sm, style: .continuous)
                .fill(UnifiedDesignSystem.Colors.whimsy.opacity(0.08))
        )
    }
}

// MARK: - Citation kind glyph

private extension InsightCitation.Kind {
    var symbolName: String {
        switch self {
        case .session: return "bubble.left.and.bubble.right"
        case .model: return "cpu"
        case .agent: return "person.crop.circle"
        case .project: return "folder"
        case .day: return "calendar"
        case .anomaly: return "exclamationmark.triangle"
        case .query: return "magnifyingglass"
        case .quota: return "gauge"
        }
    }
}

// MARK: - Formatting

public enum IntelligenceBriefFormatting {
    public static func windowLabel(_ window: InsightTimeWindow) -> String {
        switch window {
        case .today: return "Today"
        case .last24h: return "Last 24 hours"
        case .last7d: return "Last 7 days"
        case .last30d: return "Last 30 days"
        case .last90d: return "Last 90 days"
        case .last365d: return "Last 365 days"
        case .allTime: return "All time"
        case .custom(let start, let end):
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            return "\(formatter.string(from: start)) – \(formatter.string(from: end))"
        }
    }

    public static func budgetLabel(_ budget: InsightContextBudgetReport) -> String {
        let kb = max(1, budget.encodedBytes / 1024)
        let tokens = budget.estimatedPromptTokens
        var label = "~\(kb) KB · ~\(tokens) tokens"
        if !budget.truncatedDataSources.isEmpty {
            label += " · trimmed"
        }
        return label
    }

    public static func tokenUsageLabel(_ usage: InsightTokenUsage, cost: Double?) -> String {
        let total = usage.totalTokens
        if let cost {
            return "\(total) tokens · \(currency(cost))"
        }
        return "\(total) tokens"
    }

    public static func auditFooter(_ result: InsightAnalysisResult) -> String {
        let prefix = result.auditID.map { "Audit \($0.uuidString.prefix(8))" } ?? "Local run"
        let hash = result.resultHash.prefix(8)
        return "\(prefix) · result \(hash) · \(result.modelTag.egressTier.displayLabel)"
    }

    private static func currency(_ value: Double) -> String {
        String(format: "$%.4f", value)
    }
}
