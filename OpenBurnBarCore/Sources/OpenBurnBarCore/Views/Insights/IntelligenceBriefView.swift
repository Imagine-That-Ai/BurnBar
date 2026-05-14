import SwiftUI

/// Cross-platform Intelligence Brief — the Editorial Observatory.
///
/// Renders an `InsightAnalysisResult` as a single-column editorial story:
///   1. Hero — eyebrow + window subtitle + display headline + mono meta strip
///      + mercury hairline (shimmers once on appear).
///   2. Top Findings — numbered 01 / 02 / 03, severity bar leading edge,
///      confidence dots, title, why-it-matters, footnote chip citations,
///      action stripe.
///   3. Anomaly Atlas — horizontal "instrument tray", mono z-score top-left.
///   4. Recommendations — ember seal top-right, severity + confidence,
///      title, rationale, action stripe, mono impact arrow.
///   5. Generated Views — `InsightWidgetRenderer` inline with a borderless
///      pin label.
///   6. Follow-up Questions — inline whimsy underlined links separated by ` · `.
///   7. Audit Footer — full-width mercury hairline + monoTiny meta.
///
/// The view is a value-type wrapper around callbacks so platform shells
/// (macOS workspace, iOS/iPadOS, embedded preview surfaces) drop it in
/// identically. State lives with the caller.
public struct IntelligenceBriefView: View {
    public let result: InsightAnalysisResult
    public let onCitationTap: (InsightCitation) -> Void
    public let onFollowUpTap: (InsightFollowUpQuestion) -> Void
    public let onPinWidget: (InsightGeneratedWidget) -> Void
    public let onConfigureModel: (() -> Void)?
    public let onShowAudit: (() -> Void)?

    /// When `true`, structural ScrollViews (vertical outer and horizontal
    /// anomaly atlas) are replaced with plain VStack/HStack so the brief
    /// renders fully in `ImageRenderer`, screenshot exports, and PDF print
    /// surfaces. Live screens always leave this `false` so users can
    /// scroll normally.
    public var snapshotMode: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Cascade-in progress. Sentinel `-1` means the view has not yet
    /// received `onAppear`, so render everything fully visible (this also
    /// covers `ImageRenderer`, snapshot tests, and accessibility traversal).
    /// On first appear we either jump straight to fully visible (reduce
    /// motion) or restart from 0 and animate each section in.
    @State private var visibleSections: Int = -1
    @State private var shimmerPhase: CGFloat = -1
    /// Active cascade-in task. Holding a reference lets `.onDisappear`
    /// cancel pending animations cleanly when the brief is replaced or
    /// dismissed mid-cascade.
    @State private var cascadeTask: Task<Void, Never>?

    public init(
        result: InsightAnalysisResult,
        onCitationTap: @escaping (InsightCitation) -> Void = { _ in },
        onFollowUpTap: @escaping (InsightFollowUpQuestion) -> Void = { _ in },
        onPinWidget: @escaping (InsightGeneratedWidget) -> Void = { _ in },
        onConfigureModel: (() -> Void)? = nil,
        onShowAudit: (() -> Void)? = nil,
        snapshotMode: Bool = false
    ) {
        self.result = result
        self.onCitationTap = onCitationTap
        self.onFollowUpTap = onFollowUpTap
        self.onPinWidget = onPinWidget
        self.onConfigureModel = onConfigureModel
        self.onShowAudit = onShowAudit
        self.snapshotMode = snapshotMode
    }

    @ViewBuilder
    public var body: some View {
        if snapshotMode {
            // Snapshot / embedded path — no enclosing ScrollView so
            // `ImageRenderer`, PDF print, and parent ScrollViews can
            // measure the full editorial column.
            briefStack
                .background(UnifiedDesignSystem.Colors.background)
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                .onAppear { runEntranceMotion() }
                .onDisappear { cancelEntranceMotion() }
        } else {
            ScrollView {
                briefStack
            }
            .background(UnifiedDesignSystem.Colors.background.ignoresSafeArea())
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            .onAppear { runEntranceMotion() }
            .onDisappear { cancelEntranceMotion() }
        }
    }

    /// Equivalent to `body` with `snapshotMode == true`. Kept as a
    /// dedicated entry point so callers don't have to thread the flag —
    /// any embed that needs the brief to participate in an outer scroll
    /// container (`ImageRenderer`, PDF print, share sheet) can grab this
    /// view directly.
    public var unscrolledBody: some View {
        briefStack
            .background(UnifiedDesignSystem.Colors.background)
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            .onAppear { runEntranceMotion() }
            .onDisappear { cancelEntranceMotion() }
    }

    @ViewBuilder
    private var briefStack: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.xl) {
            heroSection
                .cascadeIn(index: 0, visible: visibleSections, reduceMotion: reduceMotion)

            if !result.findings.isEmpty {
                findingsSection
                    .cascadeIn(index: 1, visible: visibleSections, reduceMotion: reduceMotion)
            }

            if !result.anomalies.isEmpty {
                anomaliesSection
                    .cascadeIn(index: 2, visible: visibleSections, reduceMotion: reduceMotion)
            }

            if !result.recommendations.isEmpty {
                recommendationsSection
                    .cascadeIn(index: 3, visible: visibleSections, reduceMotion: reduceMotion)
            }

            if !result.generatedWidgets.isEmpty {
                generatedSection
                    .cascadeIn(index: 4, visible: visibleSections, reduceMotion: reduceMotion)
            }

            if !result.followUpQuestions.isEmpty {
                followUpSection
                    .cascadeIn(index: 5, visible: visibleSections, reduceMotion: reduceMotion)
            }

            auditFooter
                .cascadeIn(index: 6, visible: visibleSections, reduceMotion: reduceMotion)
        }
        .padding(UnifiedDesignSystem.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Entrance motion

    private func runEntranceMotion() {
        if reduceMotion {
            visibleSections = 7
            shimmerPhase = 1
            return
        }
        // First appear only — re-runs (from .onAppear on every recompose)
        // skip restarting the cascade so scroll-induced view churn doesn't
        // re-trigger animations.
        guard visibleSections < 0 else { return }
        visibleSections = 0
        shimmerPhase = -1
        cascadeTask?.cancel()
        cascadeTask = Task { @MainActor in
            for i in 0..<7 {
                if i > 0 {
                    try? await Task.sleep(nanoseconds: 40_000_000) // 0.04s
                    if Task.isCancelled { return }
                }
                withAnimation(UnifiedDesignSystem.Animation.gentle) {
                    visibleSections = i + 1
                }
            }
        }
        withAnimation(.linear(duration: 3.0)) {
            shimmerPhase = 1
        }
    }

    private func cancelEntranceMotion() {
        cascadeTask?.cancel()
        cascadeTask = nil
    }

    // MARK: - Hero

    @ViewBuilder
    private var heroSection: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text("INTELLIGENCE BRIEF")
                    .font(UnifiedDesignSystem.Typography.caption)
                    .tracking(2.4)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                if let onConfigureModel {
                    Button(action: onConfigureModel) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Configure model")
                }
            }

            Text(IntelligenceBriefFormatting.windowLabel(result.timeWindow))
                .font(UnifiedDesignSystem.Typography.caption)
                .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)

            if !result.executiveSummary.isEmpty {
                Text(result.executiveSummary)
                    .font(.system(.title2, design: .rounded).weight(.semibold))
                    .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                    .lineSpacing(headlineLineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }

            metaStrip

            mercuryHairline
                .padding(.top, UnifiedDesignSystem.Spacing.xs)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(heroAccessibilityLabel)
    }

    private var heroAccessibilityLabel: String {
        var parts: [String] = ["Intelligence Brief"]
        parts.append(IntelligenceBriefFormatting.windowLabel(result.timeWindow))
        parts.append(result.executiveSummary)
        parts.append("Model \(result.modelTag.displayName)")
        parts.append(result.modelTag.egressTier.displayLabel)
        parts.append("Context \(IntelligenceBriefFormatting.contextTokensLabel(result.contextBudget))")
        if let usage = result.tokenUsage {
            parts.append("Cost \(IntelligenceBriefFormatting.tokenCostLabel(usage, cost: result.estimatedCostUSD))")
        }
        return parts.joined(separator: ". ")
    }

    @ViewBuilder
    private var metaStrip: some View {
        let segments = IntelligenceBriefFormatting.metaSegments(for: result)
        Text(segments.joined(separator: "  ·  "))
            .font(UnifiedDesignSystem.Typography.monoSmall)
            .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var mercuryHairline: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(UnifiedDesignSystem.mercuryGradient)
                    .frame(height: 0.5)
                if !reduceMotion {
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    UnifiedDesignSystem.Colors.hermesMercury.opacity(0.0),
                                    UnifiedDesignSystem.Colors.hermesAureate.opacity(0.55),
                                    UnifiedDesignSystem.Colors.hermesMercury.opacity(0.0)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(40, width * 0.18), height: 0.5)
                        .offset(x: shimmerPhase * width)
                        .blendMode(.plusLighter)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: width, height: 0.5, alignment: .leading)
            .clipped()
        }
        .frame(height: 0.5)
        .accessibilityHidden(true)
    }

    // MARK: - Findings

    @ViewBuilder
    private var findingsSection: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.md) {
            sectionEyebrow("TOP FINDINGS")
            VStack(spacing: UnifiedDesignSystem.Spacing.lg) {
                ForEach(Array(result.findings.prefix(3).enumerated()), id: \.element.id) { offset, finding in
                    FindingRow(
                        index: offset + 1,
                        finding: finding,
                        onCitationTap: onCitationTap
                    )
                }
            }
        }
    }

    // MARK: - Anomalies

    @ViewBuilder
    private var anomaliesSection: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.md) {
            sectionEyebrow("ANOMALY ATLAS")
            if snapshotMode {
                // Static two-column wrap for snapshot exports — preserves
                // editorial L→R reading order without depending on a
                // horizontal ScrollView (which `ImageRenderer` collapses).
                let pairs = stride(from: 0, to: result.anomalies.count, by: 2).map { i in
                    (lhs: result.anomalies[i],
                     rhs: i + 1 < result.anomalies.count ? result.anomalies[i + 1] : nil,
                     lhsIndex: i,
                     rhsIndex: i + 1)
                }
                VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.md) {
                    ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                        HStack(alignment: .top, spacing: UnifiedDesignSystem.Spacing.md) {
                            AnomalyInstrumentCard(
                                anomaly: pair.lhs,
                                position: pair.lhsIndex + 1,
                                total: result.anomalies.count,
                                onCitationTap: onCitationTap,
                                fillWidth: true
                            )
                            if let rhs = pair.rhs {
                                AnomalyInstrumentCard(
                                    anomaly: rhs,
                                    position: pair.rhsIndex + 1,
                                    total: result.anomalies.count,
                                    onCitationTap: onCitationTap,
                                    fillWidth: true
                                )
                            } else {
                                Color.clear.frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: UnifiedDesignSystem.Spacing.md) {
                        ForEach(Array(result.anomalies.enumerated()), id: \.element.id) { idx, anomaly in
                            AnomalyInstrumentCard(
                                anomaly: anomaly,
                                position: idx + 1,
                                total: result.anomalies.count,
                                onCitationTap: onCitationTap
                            )
                        }
                    }
                    .padding(.vertical, 1)
                }
                .scrollIndicators(.hidden)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Anomaly Atlas — \(result.anomalies.count) entries left to right")
    }

    // MARK: - Recommendations

    @ViewBuilder
    private var recommendationsSection: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.md) {
            sectionEyebrow("RECOMMENDATIONS")
            VStack(spacing: UnifiedDesignSystem.Spacing.lg) {
                ForEach(result.recommendations) { recommendation in
                    RecommendationRow(
                        recommendation: recommendation,
                        onCitationTap: onCitationTap
                    )
                }
            }
        }
    }

    // MARK: - Generated views

    @ViewBuilder
    private var generatedSection: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.md) {
            sectionEyebrow("GENERATED VIEWS")
            VStack(spacing: UnifiedDesignSystem.Spacing.lg) {
                ForEach(result.generatedWidgets) { generated in
                    GeneratedViewRow(
                        generated: generated,
                        onPin: onPinWidget,
                        onCitationTap: onCitationTap
                    )
                }
            }
        }
    }

    // MARK: - Follow-up

    @ViewBuilder
    private var followUpSection: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.md) {
            sectionEyebrow("FOLLOW-UP QUESTIONS")
            FollowUpInlineLinks(
                questions: result.followUpQuestions,
                onTap: onFollowUpTap
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Follow-up questions")
    }

    // MARK: - Audit footer

    @ViewBuilder
    private var auditFooter: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.sm) {
            Rectangle()
                .fill(UnifiedDesignSystem.mercuryGradient)
                .frame(height: 0.5)
                .accessibilityHidden(true)
            HStack(alignment: .firstTextBaseline, spacing: UnifiedDesignSystem.Spacing.sm) {
                Text(IntelligenceBriefFormatting.auditFooter(result))
                    .font(UnifiedDesignSystem.Typography.monoTiny)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                    .lineLimit(2)
                Spacer(minLength: 0)
                if let onShowAudit {
                    Button("Audit log") { onShowAudit() }
                        .font(UnifiedDesignSystem.Typography.monoTiny)
                        .buttonStyle(.borderless)
                        .foregroundStyle(UnifiedDesignSystem.Colors.hermesAureate)
                        .accessibilityLabel("Open audit log")
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Audit. \(IntelligenceBriefFormatting.auditFooter(result))")
    }

    // MARK: - Section eyebrow

    private func sectionEyebrow(_ title: String) -> some View {
        Text(title)
            .font(UnifiedDesignSystem.Typography.caption)
            .tracking(2.0)
            .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Tuning

    /// 1.4× line-height target for the executive headline. SF Pro Rounded
    /// at title2 (~22pt) has a default line-height near 28pt, so we add ~3pt
    /// of additional leading to hit 1.4× without breaking baseline rhythm.
    private var headlineLineSpacing: CGFloat { 4 }
}

// MARK: - Cascade-in modifier

private struct CascadeInModifier: ViewModifier {
    let index: Int
    let visible: Int
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        // `visible == -1` is the pre-onAppear sentinel: render fully so
        // image renderers / snapshot tests capture content, and so that
        // VoiceOver finds every section before SwiftUI calls onAppear.
        let shown = reduceMotion || visible < 0 || index < visible
        return content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 6)
    }
}

private extension View {
    func cascadeIn(index: Int, visible: Int, reduceMotion: Bool) -> some View {
        modifier(CascadeInModifier(index: index, visible: visible, reduceMotion: reduceMotion))
    }
}

// MARK: - Finding row

private struct FindingRow: View {
    let index: Int
    let finding: InsightFinding
    let onCitationTap: (InsightCitation) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: UnifiedDesignSystem.Spacing.md) {
            // Severity bar: 3pt full height on leading edge.
            Rectangle()
                .fill(severityColor)
                .frame(width: 3)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.sm) {
                HStack(alignment: .firstTextBaseline, spacing: UnifiedDesignSystem.Spacing.sm) {
                    Text(String(format: "%02d", index))
                        .font(UnifiedDesignSystem.Typography.monoSmall)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                        .accessibilityLabel("Finding \(index)")
                    Text(severityLabel(finding.severity).uppercased())
                        .font(UnifiedDesignSystem.Typography.monoTiny)
                        .foregroundStyle(severityColor)
                        .tracking(1.4)
                    Spacer(minLength: 0)
                    ConfidenceDots(confidence: finding.confidence)
                }

                Text(finding.title)
                    .font(UnifiedDesignSystem.Typography.headline)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)

                if !finding.whyItMatters.isEmpty {
                    Text(finding.whyItMatters)
                        .font(UnifiedDesignSystem.Typography.body)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                        .lineSpacing(bodyLineSpacing)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !finding.evidence.isEmpty {
                    FootnoteChipFlow(citations: finding.evidence, onTap: onCitationTap)
                }

                if !finding.recommendedAction.isEmpty {
                    ActionStripe(text: finding.recommendedAction)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        "Finding \(String(format: "%02d", index)). \(severityLabel(finding.severity)) severity. \(finding.title). \(finding.whyItMatters)"
    }

    private var severityColor: Color {
        switch finding.severity {
        case .info: return UnifiedDesignSystem.Colors.textMuted
        case .low: return UnifiedDesignSystem.Colors.whimsy
        case .medium: return UnifiedDesignSystem.Colors.warning
        case .high: return UnifiedDesignSystem.Colors.ember
        case .critical: return UnifiedDesignSystem.Colors.error
        }
    }

    private var bodyLineSpacing: CGFloat { 4 }

    private func severityLabel(_ severity: InsightSeverity) -> String {
        switch severity {
        case .info: return "Info"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .critical: return "Critical"
        }
    }
}

// MARK: - Anomaly instrument card

private struct AnomalyInstrumentCard: View {
    let anomaly: InsightAnomaly
    let position: Int
    let total: Int
    let onCitationTap: (InsightCitation) -> Void
    /// When `true`, the card grows to fill the available width (used by
    /// the snapshot-mode wrapping grid). When `false`, the canonical
    /// 220pt fixed-width form for the horizontal anomaly atlas is used.
    var fillWidth: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text(zScoreText)
                    .font(UnifiedDesignSystem.Typography.monoSmall)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                Spacer(minLength: 0)
                ConfidenceDots(confidence: anomaly.confidence)
            }
            Text(anomaly.title)
                .font(UnifiedDesignSystem.Typography.caption.weight(.semibold))
                .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(anomaly.detail)
                .font(UnifiedDesignSystem.Typography.tiny)
                .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                .lineSpacing(2)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(width: fillWidth ? nil : 220, alignment: .leading)
        .frame(maxWidth: fillWidth ? .infinity : nil, alignment: .leading)
        .padding(UnifiedDesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md, style: .continuous)
                .stroke(UnifiedDesignSystem.Colors.borderSubtle, lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if let first = anomaly.evidence.first {
                onCitationTap(first)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Anomaly \(position) of \(total). \(zScoreVoice). \(anomaly.title). \(anomaly.detail)")
        .accessibilityAddTraits(anomaly.evidence.isEmpty ? [] : .isButton)
    }

    private var zScoreText: String { String(format: "z %.1f", anomaly.score) }
    private var zScoreVoice: String { String(format: "z-score %.1f", anomaly.score) }
}

// MARK: - Recommendation row

private struct RecommendationRow: View {
    let recommendation: InsightRecommendation
    let onCitationTap: (InsightCitation) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: UnifiedDesignSystem.Spacing.md) {
            VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.sm) {
                HStack(alignment: .firstTextBaseline, spacing: UnifiedDesignSystem.Spacing.sm) {
                    Text(severityLabel.uppercased())
                        .font(UnifiedDesignSystem.Typography.monoTiny)
                        .tracking(1.4)
                        .foregroundStyle(severityColor)
                    Text("·")
                        .font(UnifiedDesignSystem.Typography.monoTiny)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                    ConfidenceDots(confidence: recommendation.confidence)
                    Spacer(minLength: 0)
                }

                Text(recommendation.title)
                    .font(UnifiedDesignSystem.Typography.headline)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(recommendation.rationale)
                    .font(UnifiedDesignSystem.Typography.body)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)

                if !recommendation.recommendedAction.isEmpty {
                    ActionStripe(text: recommendation.recommendedAction)
                }

                if let impact = recommendation.estimatedImpact, !impact.isEmpty {
                    let (icon, tint) = impactPresentation(for: impact)
                    HStack(spacing: UnifiedDesignSystem.Spacing.xs) {
                        Image(systemName: icon)
                            .font(UnifiedDesignSystem.Typography.monoSmall)
                            .foregroundStyle(tint)
                        Text(impact)
                            .font(UnifiedDesignSystem.Typography.monoSmall)
                            .foregroundStyle(tint)
                    }
                    .accessibilityLabel("Estimated impact: \(impact)")
                }

                if !recommendation.evidence.isEmpty {
                    FootnoteChipFlow(citations: recommendation.evidence, onTap: onCitationTap)
                }
            }

            // Ember seal: solid dot top-right.
            Text("●")
                .font(UnifiedDesignSystem.Typography.monoSmall)
                .foregroundStyle(UnifiedDesignSystem.Colors.ember)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        "Recommendation. \(severityLabel) severity. \(recommendation.title). \(recommendation.rationale)"
    }

    private var severityLabel: String {
        switch recommendation.severity {
        case .info: return "Info"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .critical: return "Critical"
        }
    }

    private var severityColor: Color {
        switch recommendation.severity {
        case .info: return UnifiedDesignSystem.Colors.textMuted
        case .low: return UnifiedDesignSystem.Colors.whimsy
        case .medium: return UnifiedDesignSystem.Colors.warning
        case .high: return UnifiedDesignSystem.Colors.ember
        case .critical: return UnifiedDesignSystem.Colors.error
        }
    }

    /// Choose the arrow glyph + tint based on the sign embedded in the
    /// impact string. Recommendations skew toward cost reduction so the
    /// default direction is down-and-right (savings, green). If the
    /// string contains a positive sign (`+$5`) we point up-and-right and
    /// switch to the ember warning tint — surfacing that a recommendation
    /// is asking the user to *spend* more.
    private func impactPresentation(for impact: String) -> (icon: String, tint: Color) {
        let lower = impact.lowercased()
        let isGain = lower.contains("+") && !lower.contains("−") && !lower.contains("-")
        if isGain {
            return ("arrow.up.right", UnifiedDesignSystem.Colors.ember)
        }
        return ("arrow.down.right", UnifiedDesignSystem.Colors.success)
    }
}

// MARK: - Generated view row

private struct GeneratedViewRow: View {
    let generated: InsightGeneratedWidget
    let onPin: (InsightGeneratedWidget) -> Void
    let onCitationTap: (InsightCitation) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.sm) {
            // `InsightWidgetChrome` already owns the widget title and
            // freshness pill, so we render only the renderer here and
            // place the Pin affordance under the chrome (next to the
            // editorial sidenote + citations). This avoids overlapping
            // the chrome's own freshness pill / configure menu.
            InsightWidgetRenderer(widget: generated.widget, onCitationTapped: onCitationTap)

            HStack(alignment: .firstTextBaseline, spacing: UnifiedDesignSystem.Spacing.sm) {
                if !generated.reason.isEmpty {
                    Text(generated.reason)
                        .font(UnifiedDesignSystem.Typography.tiny)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button {
                    onPin(generated)
                } label: {
                    Label("Pin", systemImage: "pin")
                        .labelStyle(.titleAndIcon)
                        .font(UnifiedDesignSystem.Typography.tiny)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Pin \(generated.widget.title)")
            }

            if !generated.citations.isEmpty {
                FootnoteChipFlow(citations: generated.citations, onTap: onCitationTap)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Generated view: \(generated.widget.title)")
    }
}

// MARK: - Follow-up inline links

private struct FollowUpInlineLinks: View {
    let questions: [InsightFollowUpQuestion]
    let onTap: (InsightFollowUpQuestion) -> Void

    var body: some View {
        Text(attributedQuestions)
            .font(UnifiedDesignSystem.Typography.body)
            .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == "obb-followup",
                      let host = url.host,
                      let idx = Int(host),
                      idx >= 0, idx < questions.count
                else {
                    return .systemAction
                }
                onTap(questions[idx])
                return .handled
            })
            .accessibilityElement(children: .contain)
    }

    private var attributedQuestions: AttributedString {
        var result = AttributedString()
        for (idx, question) in questions.enumerated() {
            var segment = AttributedString(question.question)
            segment.foregroundColor = UnifiedDesignSystem.Colors.whimsy
            segment.underlineStyle = .single
            segment.link = URL(string: "obb-followup://\(idx)")
            result.append(segment)
            if idx < questions.count - 1 {
                var separator = AttributedString("  ·  ")
                separator.foregroundColor = UnifiedDesignSystem.Colors.textMuted
                result.append(separator)
            }
        }
        return result
    }
}

// MARK: - Footnote chip flow

private struct FootnoteChipFlow: View {
    let citations: [InsightCitation]
    let onTap: (InsightCitation) -> Void

    var body: some View {
        FlowLayout(spacing: UnifiedDesignSystem.Spacing.xs) {
            ForEach(citations.prefix(8), id: \.id) { citation in
                Button {
                    onTap(citation)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: citation.kind.symbolName)
                            .font(.system(size: 9, weight: .medium))
                        Text(citation.label)
                            .font(UnifiedDesignSystem.Typography.monoTiny)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, UnifiedDesignSystem.Spacing.sm)
                    .padding(.vertical, 3)
                    .overlay(
                        Capsule()
                            .stroke(UnifiedDesignSystem.Colors.borderSubtle, lineWidth: 0.5)
                    )
                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Citation: \(citation.label)")
                .accessibilityHint("Open evidence")
            }
        }
    }
}

// MARK: - Action stripe

private struct ActionStripe: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: UnifiedDesignSystem.Spacing.sm) {
            Text("→")
                .font(UnifiedDesignSystem.Typography.monoSmall)
                .foregroundStyle(UnifiedDesignSystem.Colors.hermesAureate)
                .accessibilityHidden(true)
            Text(text)
                .font(UnifiedDesignSystem.Typography.body)
                .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Action: \(text)")
    }
}

// MARK: - Confidence dots

private struct ConfidenceDots: View {
    let confidence: InsightConfidence

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { idx in
                Circle()
                    .fill(idx < filled
                          ? UnifiedDesignSystem.Colors.hermesAureate
                          : UnifiedDesignSystem.Colors.borderSubtle)
                    .frame(width: 4, height: 4)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Confidence \(confidence.rawValue)")
    }

    private var filled: Int {
        switch confidence {
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        }
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

    /// Editorial meta strip — `model · egress · context tokens · cost`.
    /// Returns the segments in order so callers can join them with the
    /// canonical `  ·  ` separator (used by the hero strip and the a11y
    /// label). Cost is included only when `tokenUsage` exists.
    public static func metaSegments(for result: InsightAnalysisResult) -> [String] {
        var segments: [String] = []
        segments.append(result.modelTag.displayName)
        segments.append(result.modelTag.egressTier.displayLabel)
        segments.append(contextTokensLabel(result.contextBudget))
        if let usage = result.tokenUsage {
            segments.append(tokenCostLabel(usage, cost: result.estimatedCostUSD))
        }
        return segments
    }

    /// `~1280 tokens · ~5 KB` style context summary used in the hero strip.
    public static func contextTokensLabel(_ budget: InsightContextBudgetReport) -> String {
        let tokens = budget.estimatedPromptTokens
        let kb = max(1, budget.encodedBytes / 1024)
        var label = "~\(tokens) tokens · ~\(kb) KB"
        if !budget.truncatedDataSources.isEmpty {
            label += " · trimmed"
        }
        return label
    }

    /// Cost-first label for the hero strip's last segment: `$0.0234` or
    /// `1600 tokens` when no cost is available.
    public static func tokenCostLabel(_ usage: InsightTokenUsage, cost: Double?) -> String {
        if let cost {
            return currency(cost)
        }
        return "\(usage.totalTokens) tokens"
    }

    private static func currency(_ value: Double) -> String {
        String(format: "$%.4f", value)
    }
}

/// Turns a `InsightCitation` tap into a natural-language follow-up prompt
/// so the composer pipeline can route the user back into the data behind
/// the chip without needing a bespoke citation router. Used by every
/// mobile/macOS surface that hosts `IntelligenceBriefView`.
public enum IntelligenceBriefCitationPrompt {
    public static func prompt(for citation: InsightCitation) -> String {
        switch citation.kind {
        case .session(let id, let provider):
            let providerSuffix = provider.map { " (\($0))" } ?? ""
            return "Open session \(id)\(providerSuffix) and summarize what drove its cost."
        case .model(let id):
            return "Drill into \(citation.label) (\(id)) — show me cost trend, cache hit rate, and top sessions."
        case .agent(let provider):
            return "Break down \(citation.label) (\(provider)) usage this window — sessions, cost, and top models."
        case .project(let name):
            return "Show me everything from project \(name): cost, model mix, anomalies, and active sessions."
        case .day(let date):
            return "Zoom into \(date) (\(citation.label)) — every provider's spend, top sessions, and any anomalies."
        case .anomaly(let id):
            return "Investigate anomaly \(id) (\(citation.label)) — what triggered it and is it still active?"
        case .query(let text):
            return "Re-run the query \"\(text)\" behind \(citation.label) and explain the result row by row."
        case .quota(let provider, let bucket):
            return "Detail the \(citation.label) quota signal: \(provider) bucket \(bucket) — headroom, refresh cadence, and projected throttling."
        }
    }
}
