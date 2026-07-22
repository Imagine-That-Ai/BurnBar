import SwiftUI
import OpenBurnBarInsights

// Supporting brief view components, modifiers, and formatting helpers.
// Extracted from IntelligenceBriefView.swift (god-file decomposition) — same module, verbatim.

struct CascadeInModifier: ViewModifier {
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

extension View {
    func cascadeIn(index: Int, visible: Int, reduceMotion: Bool) -> some View {
        modifier(CascadeInModifier(index: index, visible: visible, reduceMotion: reduceMotion))
    }
}

struct BriefingAnswerPanel: View {
    let answer: InsightBriefingAnswer
    let onCitationTap: (InsightCitation) -> Void
    /// Optional "Connect a model" call-to-action callback. Wired by the
    /// hero so users who have no LLM configured can jump straight into
    /// the model picker instead of being stuck reading the local-rules
    /// summary. Rendered only when the answer is explicitly framed as
    /// "no LLM configured" so connected users never see the prompt.
    let onConfigureModel: (() -> Void)?
    /// Optional "Upgrade to BurnBar Pro" call-to-action. Wired by
    /// shells that own the StoreKit / Play-Billing paywall. Only
    /// rendered when the orchestrator marked the answer as
    /// `subscriptionRequiredDisplayName`.
    let onUpgradeToPro: (() -> Void)?

    /// True when the answer is the dedicated "BurnBar Pro required"
    /// disclosure — the user tried to use the hosted route without an
    /// active subscription and the orchestrator landed on local rules.
    private var showsUpgradeToProCTA: Bool {
        guard onUpgradeToPro != nil else { return false }
        return answer.modelDisplayName == InsightBriefingAnswer.subscriptionRequiredDisplayName
    }

    /// True when this answer card is the honest "Data summary · no LLM
    /// configured" surface — the user can only escape it by attaching a
    /// gateway, so we surface the CTA right under the body.
    private var showsConnectModelCTA: Bool {
        guard onConfigureModel != nil else { return false }
        // When the upgrade CTA is being shown, suppress the
        // connect-model CTA — the user already saw the unconfigured
        // state and consciously hit the paywalled hosted route, so
        // the right next step is upgrading (or attaching a different
        // user-owned gateway via the row icon, not a second button).
        if showsUpgradeToProCTA { return false }
        switch answer.source {
        case .localRules:
            return answer.modelDisplayName.localizedCaseInsensitiveContains("no LLM configured")
        case .hostedFallback:
            // The hosted route answered, but the user might prefer to
            // route through their own LLM for privacy + cost control.
            // Always offer the CTA so they can promote their own route.
            return true
        case .modelGateway:
            return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.sm) {
            Text(answer.answer)
                .font(UnifiedDesignSystem.Typography.body)
                .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                // Smooths the per-chunk text growth when a streaming
                // gateway (Hermes) is appending tokens incrementally —
                // each `.delta` chunk mutates `answer.answer`, and this
                // modifier keeps the layout from popping mid-stream.
                // Matches the Android `animateContentSize()` curve.
                .animation(.easeOut(duration: 0.08), value: answer.answer)

            if !answer.bullets.isEmpty {
                FlowLayout(spacing: UnifiedDesignSystem.Spacing.xs) {
                    ForEach(Array(answer.bullets.prefix(4).enumerated()), id: \.offset) { _, bullet in
                        Text(bullet)
                            .font(UnifiedDesignSystem.Typography.monoTiny)
                            .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, UnifiedDesignSystem.Spacing.sm)
                            .padding(.vertical, 4)
                            .overlay(
                                Capsule()
                                    .stroke(UnifiedDesignSystem.Colors.borderSubtle, lineWidth: 0.5)
                            )
                    }
                }
            }

            if !answer.citations.isEmpty {
                FootnoteChipFlow(citations: answer.citations, onTap: onCitationTap)
            }

            if showsUpgradeToProCTA, let onUpgradeToPro {
                Button(action: onUpgradeToPro) {
                    HStack(spacing: 6) {
                        Image(systemName: "crown.fill")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Upgrade to BurnBar Pro")
                            .font(UnifiedDesignSystem.Typography.caption.weight(.semibold))
                    }
                    .padding(.horizontal, UnifiedDesignSystem.Spacing.md)
                    .padding(.vertical, 8)
                    .background(
                        Capsule().fill(UnifiedDesignSystem.Colors.hermesAureate.opacity(0.20))
                    )
                    .overlay(
                        Capsule().strokeBorder(UnifiedDesignSystem.Colors.hermesAureate.opacity(0.65), lineWidth: 0.75)
                    )
                    .foregroundStyle(UnifiedDesignSystem.Colors.hermesAureate)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Upgrade to BurnBar Pro")
                .accessibilityHint("Unlocks the BurnBar-hosted Intelligence Brief AI answers. Subscription required.")
                .padding(.top, 2)
            } else if showsConnectModelCTA, let onConfigureModel {
                Button(action: onConfigureModel) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Connect a model")
                            .font(UnifiedDesignSystem.Typography.caption.weight(.semibold))
                    }
                    .padding(.horizontal, UnifiedDesignSystem.Spacing.md)
                    .padding(.vertical, 8)
                    .background(
                        Capsule().fill(UnifiedDesignSystem.Colors.ember.opacity(0.16))
                    )
                    .overlay(
                        Capsule().strokeBorder(UnifiedDesignSystem.Colors.ember.opacity(0.55), lineWidth: 0.75)
                    )
                    .foregroundStyle(UnifiedDesignSystem.Colors.ember)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Connect a model")
                .accessibilityHint("Opens the Insights model picker so a connected gateway can author the reply.")
                .padding(.top, 2)
            }
        }
        .padding(UnifiedDesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(UnifiedDesignSystem.Colors.surface.opacity(0.68))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(UnifiedDesignSystem.Colors.borderSubtle, lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Answer. \(answer.answer)")
    }
}

struct FindingRow: View {
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

struct AnomalyInstrumentCard: View {
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

struct RecommendationRow: View {
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

struct GeneratedViewRow: View {
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

struct FollowUpInlineLinks: View {
    let questions: [InsightFollowUpQuestion]
    let onTap: (InsightFollowUpQuestion) -> Void

    var body: some View {
        FlowLayout(spacing: UnifiedDesignSystem.Spacing.xs) {
            ForEach(Array(questions.enumerated()), id: \.element.id) { offset, question in
                if offset > 0 {
                    Text("·")
                        .font(UnifiedDesignSystem.Typography.body)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                        .accessibilityHidden(true)
                }
                FollowUpLinkButton(question: question, onTap: onTap)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A single underlined whimsy-coloured link styled to read inline with
/// the surrounding paragraph but driven by a real `Button` so iOS
/// reliably fires the tap (the previous `AttributedString.link` +
/// `OpenURLAction` approach silently swallowed taps inside a
/// `ScrollView`).
struct FollowUpLinkButton: View {
    let question: InsightFollowUpQuestion
    let onTap: (InsightFollowUpQuestion) -> Void

    var body: some View {
        Button {
            onTap(question)
        } label: {
            Text(question.question)
                .font(UnifiedDesignSystem.Typography.body)
                .foregroundStyle(UnifiedDesignSystem.Colors.whimsy)
                .underline(true, color: UnifiedDesignSystem.Colors.whimsy.opacity(0.55))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Follow-up: \(question.question)")
        .accessibilityHint("Asks the composer")
    }
}

struct FootnoteChipFlow: View {
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
                            .font(.system(size: 12, weight: .medium))
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

struct ActionStripe: View {
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

struct ConfidenceDots: View {
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

extension InsightCitation.Kind {
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
        case .benchmark: return "chart.line.uptrend.xyaxis"
        }
    }
}

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
        case .benchmark(let source, let modelID, let taskCategory):
            return "Explain the \(citation.label) benchmark row: source \(source), model \(modelID), task \(taskCategory). Compare it to the models I actually used, including cost, rank, freshness, and whether switching would make sense."
        }
    }
}
