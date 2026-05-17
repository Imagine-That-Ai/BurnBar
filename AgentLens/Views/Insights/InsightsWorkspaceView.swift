import SwiftUI
import OpenBurnBarCore

/// Top-level workspace for the macOS Insights tab.
///
/// Three-pane: canvas library (left) · canvas grid + composer (center) ·
/// inspector (right). Built directly on `InsightWidgetRenderer` from the
/// shared core so the visual grammar is identical on macOS, iPad, and
/// iPhone.
struct InsightsWorkspaceView: View {

    @State private var environment: InsightsMacEnvironment?
    @State private var verdictModel: InsightsMacVerdictModel?
    @State private var showAuditLog = false
    private let dataStore: DataStore
    private let settingsManager: SettingsManager
    private let chatController: ChatSessionController?

    init(dataStore: DataStore,
         settingsManager: SettingsManager,
         chatController: ChatSessionController? = nil) {
        self.dataStore = dataStore
        self.settingsManager = settingsManager
        self.chatController = chatController
    }

    var body: some View {
        Group {
            if let environment {
                content(environment: environment)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            if environment == nil {
                if let env = try? InsightsMacEnvironment(dataStore: dataStore) {
                    environment = env
                    let model = InsightsMacVerdictModel(
                        deviceID: UserDefaults.standard.string(forKey: OpenBurnBarIdentity.deviceIDKey) ?? "device_local",
                        window: .today,
                        dataSource: env.dataSource,
                        digestBuilder: env.digestBuilder
                    )
                    verdictModel = model
                    await model.bootstrap()
                }
            }
        }
    }

    @ViewBuilder
    private func content(environment: InsightsMacEnvironment) -> some View {
        HStack(spacing: 0) {
            InsightsCanvasLibraryView(environment: environment)
            Divider().opacity(0.4)
            VStack(spacing: 0) {
                if let verdictModel, let verdict = verdictModel.verdict {
                    verdictPane(model: verdictModel, verdict: verdict, environment: environment)
                        .padding(.horizontal, UnifiedDesignSystem.Spacing.md)
                        .padding(.top, UnifiedDesignSystem.Spacing.md)
                }
                if let canvas = environment.currentCanvas {
                    canvasArea(environment: environment, canvas: canvas)
                } else {
                    emptyCanvasState(environment: environment)
                }
                Divider().opacity(0.4)
                if environment.composerError != nil {
                    errorBanner(environment: environment)
                }
                InsightsComposerBar(environment: environment)
                    .padding(UnifiedDesignSystem.Spacing.md)
            }
            Divider().opacity(0.4)
            InsightsInspectorView(environment: environment)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(UnifiedDesignSystem.Colors.background)
        .navigationTitle("Insights")
    }

    @ViewBuilder
    private func verdictPane(
        model: InsightsMacVerdictModel,
        verdict: InsightVerdict,
        environment: InsightsMacEnvironment
    ) -> some View {
        VerdictHeroView(
            verdict: verdict,
            isStale: model.isStale,
            isDemo: model.isDemo,
            onRefresh: { model.refresh() },
            onCitationTap: { citation in
                Task { await environment.compose(
                    prompt: IntelligenceBriefCitationPrompt.prompt(for: citation)
                ) }
            },
            onAcceptAction: { action in
                Task { await environment.compose(
                    prompt: "Run the recommended action: \(action.label) "
                        + "(intent: \(action.intent.rawValue))."
                ) }
            },
            onTraceTap: { sessionID in
                Task { await environment.compose(
                    prompt: "Show me the full trace for session \(sessionID)."
                ) }
            },
            onFollowUpTap: { question in
                Task { await environment.compose(prompt: question) }
            }
        )
    }

    @ViewBuilder
    private func canvasArea(environment: InsightsMacEnvironment, canvas: InsightCanvas) -> some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.md) {
            canvasHeader(canvas: canvas, environment: environment)
            ScrollView {
                VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.md) {
                    if let analysis = environment.currentAnalysis {
                        analysisBrief(analysis)
                    }
                    InsightsCanvasGridView(
                        canvas: canvas,
                        selectedWidgetID: environment.selectedWidgetID,
                        onSelectWidget: { id in environment.selectedWidgetID = id },
                        onConfigureWidget: { id in environment.selectedWidgetID = id },
                        onCitationTapped: { _ in /* shell-level handler hooks into routing later */ },
                        onMoveWidget: { id, column, row in
                            Task { await environment.moveWidget(id: id, column: column, row: row) }
                        }
                    )
                }
                .padding(UnifiedDesignSystem.Spacing.md)
            }
        }
    }

    private func analysisBrief(_ analysis: InsightAnalysisResult) -> some View {
        IntelligenceBriefView(
            result: analysis,
            onCitationTap: { citation in
                Task { await environment?.compose(prompt: IntelligenceBriefCitationPrompt.prompt(for: citation)) }
            },
            onFollowUpTap: { question in
                Task { await environment?.compose(prompt: question.question) }
            },
            onPinWidget: { generated in
                Task { await environment?.pinGeneratedWidget(generated) }
            },
            onConfigureModel: nil,
            onShowAudit: { showAuditLog = true },
            snapshotMode: true
        )
    }

    private func canvasHeader(canvas: InsightCanvas, environment: InsightsMacEnvironment) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(canvas.title)
                    .font(UnifiedDesignSystem.Typography.title)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                if let summary = canvas.summary {
                    Text(summary)
                        .font(UnifiedDesignSystem.Typography.caption)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                }
            }
            Spacer()
            Button {
                showAuditLog = true
            } label: {
                Label("Audit", systemImage: "shield.lefthalf.filled")
            }
            .buttonStyle(.bordered)
            .help("View every model investigation that touched your data")
            Button {
                Task { await environment.refreshSelectedCanvasData() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, UnifiedDesignSystem.Spacing.md)
        .padding(.top, UnifiedDesignSystem.Spacing.md)
        .sheet(isPresented: $showAuditLog) {
            InsightsAuditLogView(auditLog: environment.auditLog, isPresented: $showAuditLog)
        }
    }

    private func emptyCanvasState(environment: InsightsMacEnvironment) -> some View {
        VStack(spacing: UnifiedDesignSystem.Spacing.md) {
            Image(systemName: "sparkles.tv")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(UnifiedDesignSystem.Colors.ember)
            Text("No canvas yet")
                .font(UnifiedDesignSystem.Typography.title)
            Text("Start from a template or ask the composer below.")
                .font(UnifiedDesignSystem.Typography.caption)
                .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorBanner(environment: InsightsMacEnvironment) -> some View {
        HStack(spacing: UnifiedDesignSystem.Spacing.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(UnifiedDesignSystem.Colors.error)
            Text(environment.composerError ?? "")
                .font(UnifiedDesignSystem.Typography.caption)
            Spacer()
            Button("Dismiss") { environment.composerError = nil }
                .buttonStyle(.borderless)
                .font(UnifiedDesignSystem.Typography.caption)
        }
        .padding(UnifiedDesignSystem.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md)
                .fill(UnifiedDesignSystem.Colors.error.opacity(0.08))
        )
        .padding(.horizontal, UnifiedDesignSystem.Spacing.md)
        .padding(.top, UnifiedDesignSystem.Spacing.sm)
    }
}
