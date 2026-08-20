import SwiftUI
import OpenBurnBarRecap
import OpenBurnBarInsights
import OpenBurnBarKernel

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
    public let onMissionLaunchTap: (InsightFollowUpQuestion, String, String, InsightMissionLaunchOptions) -> Void
    public let onPinWidget: (InsightGeneratedWidget) -> Void
    public let onConfigureModel: (() -> Void)?
    /// Optional callback wired by shells that know how to open the
    /// BurnBar Pro paywall (StoreKit sheet on iOS/macOS, Play Billing
    /// flow on Android). The brief surfaces this CTA only when the
    /// orchestrator marked the answer as "BurnBar Pro required" —
    /// connected users never see it.
    public let onUpgradeToPro: (() -> Void)?
    public let onShowAudit: (() -> Void)?

    /// When `true`, structural ScrollViews (vertical outer and horizontal
    /// anomaly atlas) are replaced with plain VStack/HStack so the brief
    /// renders fully in `ImageRenderer`, screenshot exports, and PDF print
    /// surfaces. Live screens always leave this `false` so users can
    /// scroll normally.
    public var snapshotMode: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("useWebsiteBackground") private var useWebsiteBackground: Bool = false
    @AppStorage("useKernelBackdrop") private var useKernelBackdrop: Bool = false
    /// Cascade-in progress. Sentinel `-1` means the view has not yet
    /// received `onAppear`, so render everything fully visible (this also
    /// covers `ImageRenderer`, snapshot tests, and accessibility traversal).
    /// On first appear we either jump straight to fully visible (reduce
    /// motion) or restart from 0 and animate each section in.
    @State private var visibleSections: Int = -1
    @State private var shimmerPhase: CGFloat = -1
    @State private var expandedMissionID: UUID?
    /// Active cascade-in task. Holding a reference lets `.onDisappear`
    /// cancel pending animations cleanly when the brief is replaced or
    /// dismissed mid-cascade.
    @State private var cascadeTask: Task<Void, Never>?

    public init(
        result: InsightAnalysisResult,
        onCitationTap: @escaping (InsightCitation) -> Void = { _ in },
        onFollowUpTap: @escaping (InsightFollowUpQuestion) -> Void = { _ in },
        onMissionLaunchTap: ((InsightFollowUpQuestion, String, String, InsightMissionLaunchOptions) -> Void)? = nil,
        onPinWidget: @escaping (InsightGeneratedWidget) -> Void = { _ in },
        onConfigureModel: (() -> Void)? = nil,
        onUpgradeToPro: (() -> Void)? = nil,
        onShowAudit: (() -> Void)? = nil,
        snapshotMode: Bool = false
    ) {
        self.result = result
        self.onCitationTap = onCitationTap
        self.onFollowUpTap = onFollowUpTap
        self.onMissionLaunchTap = onMissionLaunchTap ?? { question, _, _, _ in onFollowUpTap(question) }
        self.onPinWidget = onPinWidget
        self.onConfigureModel = onConfigureModel
        self.onUpgradeToPro = onUpgradeToPro
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
                .background(usesLiveBackground ? Color.clear : UnifiedDesignSystem.Colors.background)
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                .onAppear { runEntranceMotion() }
                .onDisappear { cancelEntranceMotion() }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    briefStack
                }
                .background(
                    Group {
                        if usesLiveBackground {
                            Color.clear
                        } else {
                            UnifiedDesignSystem.Colors.background
                        }
                    }
                    .ignoresSafeArea()
                )
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                .onAppear { runEntranceMotion() }
                .onDisappear { cancelEntranceMotion() }
                // Whenever a new prompt-driven answer arrives, scroll
                // the hero (which carries the eyebrow "ANSWERED BY …",
                // the question line, and the tailored summary) back
                // into view. This is the *elegant* way to wire
                // "follow-up tap → visible reply": no extra card, no
                // duplicate slab — just the hero, now centered.
                .onChange(of: result.briefingAnswer?.id) { _, newID in
                    guard newID != nil else { return }
                    withAnimation(.easeInOut(duration: 0.45)) {
                        proxy.scrollTo(Self.heroAnchorID, anchor: .top)
                    }
                }
            }
        }
    }

    private var usesLiveBackground: Bool {
        useWebsiteBackground || useKernelBackdrop
    }

    /// Stable `ScrollView` anchor for the hero so the brief can scroll
    /// itself back to "the answer" when a follow-up tap or composer
    /// submission produces a new `briefingAnswer`.
    fileprivate static let heroAnchorID = "intelligence-brief-hero"

    private struct AnomalySnapshotPair: Identifiable {
        let id: Int
        let lhs: InsightAnomaly
        let rhs: InsightAnomaly?
        let lhsIndex: Int
        let rhsIndex: Int
    }

    private var anomalySnapshotPairs: [AnomalySnapshotPair] {
        stride(from: 0, to: result.anomalies.count, by: 2).map { index in
            AnomalySnapshotPair(
                id: index,
                lhs: result.anomalies[index],
                rhs: index + 1 < result.anomalies.count ? result.anomalies[index + 1] : nil,
                lhsIndex: index,
                rhsIndex: index + 1
            )
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
                .id(Self.heroAnchorID)
                .cascadeIn(index: 0, visible: visibleSections, reduceMotion: reduceMotion)

            MissionLaunchpad { action, options in
                onMissionLaunchTap(action.followUpQuestion, action.kind.firestoreValue, options.requestedRuntime, options)
            }
            .cascadeIn(index: 1, visible: visibleSections, reduceMotion: reduceMotion)

            if !result.findings.isEmpty {
                findingsSection
                    .cascadeIn(index: 2, visible: visibleSections, reduceMotion: reduceMotion)
            }

            if !result.missionCandidates.isEmpty {
                missionsSection
                    .cascadeIn(index: 3, visible: visibleSections, reduceMotion: reduceMotion)
            }

            if !result.anomalies.isEmpty {
                anomaliesSection
                    .cascadeIn(index: 4, visible: visibleSections, reduceMotion: reduceMotion)
            }

            if !result.recommendations.isEmpty {
                recommendationsSection
                    .cascadeIn(index: 5, visible: visibleSections, reduceMotion: reduceMotion)
            }

            if !result.generatedWidgets.isEmpty {
                generatedSection
                    .cascadeIn(index: 6, visible: visibleSections, reduceMotion: reduceMotion)
            }

            if !result.followUpQuestions.isEmpty {
                followUpSection
                    .cascadeIn(index: 7, visible: visibleSections, reduceMotion: reduceMotion)
            }

            auditFooter
                .cascadeIn(index: 8, visible: visibleSections, reduceMotion: reduceMotion)
        }
        .padding(UnifiedDesignSystem.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Entrance motion

    private func runEntranceMotion() {
        if reduceMotion {
            visibleSections = 9
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
            for i in 0..<9 {
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
            heroEyebrowRow

            Text(IntelligenceBriefFormatting.windowLabel(result.timeWindow))
                .font(UnifiedDesignSystem.Typography.caption)
                .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)

            // When the brief is answering a user question, surface
            // the question itself as a small italic line above the
            // headline so the user *sees* their prompt being replied
            // to. Without this the hero looks like a generic brief.
            if let answer = result.briefingAnswer {
                Text("Q · \(answer.question)")
                    .font(UnifiedDesignSystem.Typography.caption)
                    .italic()
                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !result.executiveSummary.isEmpty {
                heroAnswerRow
            }

            if let answer = result.briefingAnswer {
                BriefingAnswerPanel(
                    answer: answer,
                    onCitationTap: onCitationTap,
                    onConfigureModel: onConfigureModel,
                    onUpgradeToPro: onUpgradeToPro
                )
            }

            metaStrip

            if result.briefingAnswer?.isFallback == true {
                fallbackBadge
            }

            mercuryHairline
                .padding(.top, UnifiedDesignSystem.Spacing.xs)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(heroAccessibilityLabel)
    }

    /// The eyebrow at the top of the hero. When the brief is replying
    /// to a user prompt this becomes the explicit "ANSWERED BY …"
    /// chip — the only signal the user needs to know that *this whole
    /// hero* is the reply, not a generic recap.
    @ViewBuilder
    private var heroEyebrowRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let answer = result.briefingAnswer {
                Image(systemName: heroEyebrowSymbol(for: answer))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(heroEyebrowColor(for: answer))
                Text(heroEyebrowText(for: answer).uppercased())
                    .font(UnifiedDesignSystem.Typography.caption)
                    .tracking(1.8)
                    .foregroundStyle(heroEyebrowColor(for: answer))
                    .accessibilityAddTraits(.isHeader)
            } else {
                Text("INTELLIGENCE BRIEF")
                    .font(UnifiedDesignSystem.Typography.caption)
                    .tracking(2.4)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                    .accessibilityAddTraits(.isHeader)
            }
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
    }

    /// The big answer line. When we have a lead provider in the
    /// findings, render its logo to the left of the summary so the
    /// hero gains visual identity at a glance — the brand mark
    /// telegraphs "this brief is about Claude Code" before the user
    /// reads a single word.
    @ViewBuilder
    private var heroAnswerRow: some View {
        HStack(alignment: .top, spacing: UnifiedDesignSystem.Spacing.md) {
            if let provider = heroLeadProvider {
                UnifiedProviderLogoView(provider: provider, size: 44)
                    .accessibilityHidden(true)
            }
            Text(result.executiveSummary)
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                .lineSpacing(headlineLineSpacing)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        }
    }

    /// "Showing local fallback" warning chip — only renders when the
    /// gateway call failed and we degraded to rules. Sits below the
    /// metaStrip so it's discoverable without competing with the
    /// answer text.
    @ViewBuilder
    private var fallbackBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
            Text("Showing local fallback")
                .font(UnifiedDesignSystem.Typography.tiny)
                .tracking(0.6)
        }
        .foregroundStyle(UnifiedDesignSystem.Colors.warning)
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            Capsule().fill(UnifiedDesignSystem.Colors.warning.opacity(0.12))
        )
        .overlay(
            Capsule().strokeBorder(UnifiedDesignSystem.Colors.warning.opacity(0.4), lineWidth: 0.5)
        )
    }

    /// The provider whose evidence anchors the lead finding, used as
    /// the hero's visual anchor. Falls back through finding evidence
    /// then top-level result citations, and resolves the first
    /// `.agent(provider:)` citation that maps to a known
    /// `AgentProvider` enum case. Returns `nil` when no agent
    /// citations are present (rare — only synthetic digests).
    private var heroLeadProvider: AgentProvider? {
        let candidates = (result.findings.first?.evidence ?? []) + result.citations
        for citation in candidates {
            if case .agent(let provider) = citation.kind,
               let resolved = AgentProvider(rawValue: provider) {
                return resolved
            }
        }
        return nil
    }

    private func heroEyebrowSymbol(for answer: InsightBriefingAnswer) -> String {
        if answer.isFallback { return "exclamationmark.triangle.fill" }
        switch answer.source {
        case .modelGateway:   return "sparkles"
        case .hostedFallback: return "cloud.fill"
        case .localRules:     return "lock.shield.fill"
        }
    }

    private func heroEyebrowColor(for answer: InsightBriefingAnswer) -> Color {
        if answer.isFallback { return UnifiedDesignSystem.Colors.warning }
        switch answer.source {
        case .modelGateway:   return UnifiedDesignSystem.Colors.ember
        case .hostedFallback: return UnifiedDesignSystem.Colors.hermesAureate
        case .localRules:     return UnifiedDesignSystem.Colors.whimsy
        }
    }

    private func heroEyebrowText(for answer: InsightBriefingAnswer) -> String {
        switch answer.source {
        case .modelGateway: return "Answered by \(answer.modelDisplayName)"
        case .hostedFallback:
            // BurnBar's hosted fallback fired — surface it honestly so
            // the user understands their own route wasn't used and
            // can connect one if they want privacy / their own quota.
            return "Answered by \(answer.modelDisplayName) · hosted fallback"
        case .localRules:
            // Don't claim to "answer" when there's no LLM behind it —
            // the local rule engine only summarizes the digest.
            return "Data summary · \(answer.modelDisplayName)"
        }
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

    // MARK: - Missions

    @ViewBuilder
    private var missionsSection: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.md) {
            sectionEyebrow("MISSION BOARD")
            VStack(spacing: UnifiedDesignSystem.Spacing.md) {
                ForEach(result.missionCandidates) { mission in
                    MissionCandidateRow(
                        mission: mission,
                        isExpanded: expandedMissionID == mission.id,
                        onToggle: {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                                expandedMissionID = expandedMissionID == mission.id ? nil : mission.id
                            }
                        },
                        onLaunch: {
                            onMissionLaunchTap(
                                mission.launchQuestion,
                                mission.launchMissionKind,
                                InsightMissionRuntimeTarget.auto.firestoreValue,
                                InsightMissionLaunchOptions(
                                    requestedRuntime: InsightMissionRuntimeTarget.auto.firestoreValue,
                                    targetProject: mission.projectDisplayName ?? mission.projectID,
                                    depth: InsightMissionDepth.standard.rawValue,
                                    approvalMode: InsightMissionApprovalMode.existingPolicy.rawValue,
                                    commandsAllowed: false,
                                    fileEditsAllowed: false
                                )
                            )
                        },
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
                anomalySnapshotGrid
            } else {
                anomalyScrollTray
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Anomaly Atlas — \(result.anomalies.count) entries left to right")
    }

    // Static two-column wrap for snapshot exports. This preserves editorial
    // left-to-right reading order without a horizontal ScrollView, which
    // ImageRenderer collapses.
    private var anomalySnapshotGrid: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.md) {
            ForEach(anomalySnapshotPairs) { pair in
                anomalySnapshotRow(pair)
            }
        }
    }

    private func anomalySnapshotRow(_ pair: AnomalySnapshotPair) -> some View {
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

    private var anomalyScrollTray: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: UnifiedDesignSystem.Spacing.md) {
                ForEach(Array(result.anomalies.enumerated()), id: \.element.id) { index, anomaly in
                    AnomalyInstrumentCard(
                        anomaly: anomaly,
                        position: index + 1,
                        total: result.anomalies.count,
                        onCitationTap: onCitationTap
                    )
                }
            }
            .padding(.vertical, 1)
        }
        .scrollIndicators(.hidden)
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
