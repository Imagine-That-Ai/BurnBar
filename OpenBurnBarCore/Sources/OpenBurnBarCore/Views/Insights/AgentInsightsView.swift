import SwiftUI

/// Cross-platform Insights surface for a single agent (or the aggregate).
///
/// The same struct renders on iPhone, iPad, macOS, and is the source of
/// truth for what an Insights page looks like. macOS and iPad pass
/// `.roomy` to unlock the wider layout (multi-column KPI strip, wider
/// canvas grid); iPhone (and narrow split-view detail) uses `.compact`.
///
/// View-owned state stays inside the view-model. The view itself is a
/// value-type wrapper around the bundle + tap callbacks so platform
/// shells drop it in identically.
public struct AgentInsightsView: View {
    @Bindable public var viewModel: AgentInsightsViewModel
    public var presentation: Presentation
    public var actions: Actions

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    public init(
        viewModel: AgentInsightsViewModel,
        presentation: Presentation = .automatic,
        actions: Actions = Actions()
    ) {
        self.viewModel = viewModel
        self.presentation = presentation
        self.actions = actions
    }

    public enum Presentation: Equatable, Sendable {
        case compact
        case roomy
        case automatic
    }

    public struct Actions {
        public var onMissionTap: ((InsightMissionCandidate) -> Void)?
        public var onCanvasTap: ((InsightCanvas) -> Void)?
        public var onShowInspector: (() -> Void)?
        public var onShowAudit: (() -> Void)?
        public var onConfigureModel: (() -> Void)?
        public var onPickAgent: (() -> Void)?
        public var onFollowUpTap: ((InsightFollowUpQuestion) -> Void)?
        public var onMissionLaunchTap: ((InsightFollowUpQuestion) -> Void)?
        public var onCitationTap: ((InsightCitation) -> Void)?
        public var onPinWidget: ((InsightGeneratedWidget) -> Void)?

        public init(
            onMissionTap: ((InsightMissionCandidate) -> Void)? = nil,
            onCanvasTap: ((InsightCanvas) -> Void)? = nil,
            onShowInspector: (() -> Void)? = nil,
            onShowAudit: (() -> Void)? = nil,
            onConfigureModel: (() -> Void)? = nil,
            onPickAgent: (() -> Void)? = nil,
            onFollowUpTap: ((InsightFollowUpQuestion) -> Void)? = nil,
            onMissionLaunchTap: ((InsightFollowUpQuestion) -> Void)? = nil,
            onCitationTap: ((InsightCitation) -> Void)? = nil,
            onPinWidget: ((InsightGeneratedWidget) -> Void)? = nil
        ) {
            self.onMissionTap = onMissionTap
            self.onCanvasTap = onCanvasTap
            self.onShowInspector = onShowInspector
            self.onShowAudit = onShowAudit
            self.onConfigureModel = onConfigureModel
            self.onPickAgent = onPickAgent
            self.onFollowUpTap = onFollowUpTap
            self.onMissionLaunchTap = onMissionLaunchTap
            self.onCitationTap = onCitationTap
            self.onPinWidget = onPinWidget
        }
    }

    public var body: some View {
        Group {
            if let bundle = viewModel.bundle {
                content(bundle: bundle)
            } else if viewModel.loadState == .failed {
                errorState
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(UnifiedDesignSystem.Colors.background)
        .task { await viewModel.load() }
    }

    // MARK: - Effective presentation

    private var effectivePresentation: Presentation {
        switch presentation {
        case .compact, .roomy: return presentation
        case .automatic:
            #if os(macOS)
            return .roomy
            #else
            return horizontalSizeClass == .regular ? .roomy : .compact
            #endif
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(bundle: AgentInsightsBundle) -> some View {
        let layout = effectivePresentation
        ScrollView {
            VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.lg) {
                AgentInsightsHeaderView(
                    header: bundle.header,
                    presentation: layout,
                    onTap: actions.onPickAgent
                )
                AgentInsightsKPIStripView(
                    strip: bundle.kpis,
                    presentation: layout
                )
                if let brief = bundle.brief {
                    IntelligenceBriefView(
                        result: brief,
                        onCitationTap: { actions.onCitationTap?($0) },
                        onFollowUpTap: { actions.onFollowUpTap?($0) },
                        onMissionLaunchTap: { actions.onMissionLaunchTap?($0) },
                        onPinWidget: { actions.onPinWidget?($0) },
                        onConfigureModel: actions.onConfigureModel,
                        onShowAudit: actions.onShowAudit,
                        snapshotMode: true
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !bundle.missions.isEmpty {
                    AgentInsightsMissionRailView(
                        missions: bundle.missions,
                        presentation: layout,
                        onTap: actions.onMissionTap
                    )
                }
                if !bundle.canvases.isEmpty {
                    AgentInsightsCanvasGridView(
                        canvases: bundle.canvases,
                        presentation: layout,
                        onTap: actions.onCanvasTap
                    )
                }
                if bundle.isEmpty {
                    AgentInsightsEmptyStateView(header: bundle.header)
                }
                if let onShowAudit = actions.onShowAudit, !bundle.auditTrail.isEmpty {
                    auditAffordance(count: bundle.auditTrail.count, action: onShowAudit)
                }
                refreshFooter
            }
            .padding(.horizontal, UnifiedDesignSystem.Spacing.md)
            .padding(.vertical, UnifiedDesignSystem.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .refreshable { await viewModel.refresh() }
    }

    private func auditAffordance(count: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: UnifiedDesignSystem.Spacing.sm) {
                Image(systemName: "shield.lefthalf.filled")
                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                Text("\(count) audit entr\(count == 1 ? "y" : "ies")")
                    .font(UnifiedDesignSystem.Typography.caption)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                    .font(.system(size: 11, weight: .semibold))
            }
            .padding(UnifiedDesignSystem.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md)
                    .fill(UnifiedDesignSystem.Colors.surface)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show \(count) audit entries")
    }

    @ViewBuilder
    private var refreshFooter: some View {
        if let bundle = viewModel.bundle {
            HStack {
                Spacer()
                Text("Generated \(bundle.generatedAt.formatted(.relative(presentation: .named)))")
                    .font(UnifiedDesignSystem.Typography.tiny)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                Spacer()
            }
            .padding(.top, UnifiedDesignSystem.Spacing.sm)
        }
    }

    private var errorState: some View {
        VStack(spacing: UnifiedDesignSystem.Spacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(UnifiedDesignSystem.Colors.error)
            Text("Couldn't load Insights")
                .font(UnifiedDesignSystem.Typography.title)
            if let message = viewModel.errorMessage {
                Text(message)
                    .font(UnifiedDesignSystem.Typography.caption)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                    .multilineTextAlignment(.center)
            }
            Button("Retry") {
                Task { await viewModel.load() }
            }
            .buttonStyle(.borderedProminent)
            .tint(UnifiedDesignSystem.Colors.ember)
        }
        .padding(UnifiedDesignSystem.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
