import SwiftUI
import OpenBurnBarCore

/// macOS Insights workspace.
///
/// Three regions in a horizontal stack:
///   1. Left sidebar — agent roster (cross-platform `AgentInsightsRosterView`)
///      grouped by capability tier.
///   2. Center — `AgentInsightsView` for the currently selected scope, the
///      same struct that renders on iPhone, iPad, and macOS.
///   3. Right toolbar — affordance to open the legacy canvas workspace
///      ("Open canvas workspace") which keeps the composer + editor flow
///      reachable.
///
/// macOS-only enhancements:
///   * ⌘1–⌘9 keyboard shortcuts jump to the first nine agents in the roster.
///   * ⌘0 jumps to the aggregate "All agents" view.
///   * `.roomy` presentation passed to `AgentInsightsView` unlocks the full
///     KPI row, model lineup band, and wider canvas grid.
struct MacAgentInsightsWorkspace: View {

    let dataStore: DataStore
    let settingsManager: SettingsManager
    let chatController: ChatSessionController?

    @State private var environment: InsightsMacEnvironment?
    @State private var producer: MacAgentInsightsProducer?
    @State private var viewModel: AgentInsightsViewModel?
    @State private var selectedScope: AgentInsightsScope = .aggregate
    @State private var showLegacyWorkspace = false
    @State private var rosterStatus: [AgentProvider: AgentInsightsHeader.Status] = [:]
    @State private var rosterLastSeen: [AgentProvider: Date] = [:]
    @State private var compareScopes: [AgentInsightsScope] = []
    @State private var isComparing = false

    private let shortcutProviders: [AgentProvider] = Array(AgentProvider.allCases.prefix(9))

    var body: some View {
        Group {
            if let environment {
                content(environment: environment)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await prepare() }
        .sheet(isPresented: $showLegacyWorkspace) {
            LegacyWorkspaceSheet(
                dataStore: dataStore,
                settingsManager: settingsManager,
                chatController: chatController,
                isPresented: $showLegacyWorkspace
            )
        }
        .background(keyboardShortcuts)
    }

    private func content(environment: InsightsMacEnvironment) -> some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 320)
                .background(UnifiedDesignSystem.Colors.surface)
            Divider().opacity(0.4)
            if isComparing {
                compareView
            } else {
                scopedDetail
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(UnifiedDesignSystem.Colors.background)
        .navigationTitle(selectedScope.provider?.displayName ?? "All agents")
        .toolbar {
            ToolbarItemGroup {
                Toggle(isOn: $isComparing) {
                    Label("Compare", systemImage: "rectangle.split.3x1")
                }
                .help("Compare up to three agents side-by-side")
                Button {
                    showLegacyWorkspace = true
                } label: {
                    Label("Canvas workspace", systemImage: "rectangle.grid.2x2")
                }
                .help("Open the full canvas editor + composer")
            }
        }
    }

    private var sidebar: some View {
        AgentInsightsRosterView(
            providers: AgentProvider.allCases,
            statusProvider: { rosterStatus[$0] ?? .unconfigured },
            lastSeenProvider: { rosterLastSeen[$0] },
            onSelectProvider: { provider in
                let scope = AgentInsightsScope.agent(provider)
                if isComparing {
                    toggleCompareScope(scope)
                } else {
                    select(scope: scope)
                }
            },
            onSelectAggregate: {
                let scope = AgentInsightsScope.aggregate
                if isComparing {
                    toggleCompareScope(scope)
                } else {
                    select(scope: scope)
                }
            }
        )
    }

    @ViewBuilder
    private var scopedDetail: some View {
        if let viewModel {
            AgentInsightsView(
                viewModel: viewModel,
                presentation: .roomy,
                actions: actions(for: viewModel)
            )
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var compareView: some View {
        if compareScopes.isEmpty {
            VStack(spacing: UnifiedDesignSystem.Spacing.md) {
                Image(systemName: "rectangle.split.3x1")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(UnifiedDesignSystem.Colors.ember)
                Text("Pick up to three agents to compare")
                    .font(UnifiedDesignSystem.Typography.title)
                Text("Click any agent in the roster to add it to the compare matrix.")
                    .font(UnifiedDesignSystem.Typography.caption)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: UnifiedDesignSystem.Spacing.md) {
                    ForEach(compareScopes, id: \.self) { scope in
                        compareColumn(scope: scope)
                    }
                }
                .padding(UnifiedDesignSystem.Spacing.md)
            }
        }
    }

    private func compareColumn(scope: AgentInsightsScope) -> some View {
        Group {
            if let producer {
                CompareAgentColumn(scope: scope, producer: producer, onRemove: {
                    compareScopes.removeAll { $0 == scope }
                })
                .frame(width: 360)
            }
        }
    }

    private func toggleCompareScope(_ scope: AgentInsightsScope) {
        if let idx = compareScopes.firstIndex(of: scope) {
            compareScopes.remove(at: idx)
        } else if compareScopes.count < 3 {
            compareScopes.append(scope)
        }
    }

    private func actions(for viewModel: AgentInsightsViewModel) -> AgentInsightsView.Actions {
        AgentInsightsView.Actions(
            onMissionTap: { _ in showLegacyWorkspace = true },
            onCanvasTap: { canvas in
                environment?.selectedCanvasID = canvas.id
                showLegacyWorkspace = true
            },
            onShowInspector: { showLegacyWorkspace = true },
            onShowAudit: { showLegacyWorkspace = true },
            onConfigureModel: { showLegacyWorkspace = true },
            onPickAgent: nil,
            onFollowUpTap: { _ in showLegacyWorkspace = true },
            onMissionLaunchTap: nil,
            onCitationTap: { _ in showLegacyWorkspace = true },
            onPinWidget: { _ in showLegacyWorkspace = true }
        )
    }

    private func select(scope: AgentInsightsScope) {
        guard scope != selectedScope || viewModel == nil else { return }
        selectedScope = scope
        if let viewModel {
            Task { await viewModel.setScope(scope) }
        } else if let producer {
            viewModel = AgentInsightsViewModel(scope: scope, producer: producer)
        }
    }

    @MainActor
    private func prepare() async {
        if environment == nil {
            if let env = try? InsightsMacEnvironment(dataStore: dataStore) {
                environment = env
                let producer = MacAgentInsightsProducer(environment: env)
                self.producer = producer
                viewModel = AgentInsightsViewModel(scope: selectedScope, producer: producer)
            }
        }
        await refreshRoster()
    }

    @MainActor
    private func refreshRoster() async {
        guard let producer else { return }
        var status: [AgentProvider: AgentInsightsHeader.Status] = [:]
        var lastSeen: [AgentProvider: Date] = [:]
        for provider in AgentProvider.allCases {
            let scope = AgentInsightsScope.agent(provider)
            if let bundle = try? await producer.bundle(for: scope) {
                status[provider] = bundle.header.status
                lastSeen[provider] = bundle.header.lastSeen
            }
        }
        rosterStatus = status
        rosterLastSeen = lastSeen
    }

    // MARK: - Keyboard shortcuts

    private var keyboardShortcuts: some View {
        VStack(spacing: 0) {
            ForEach(0..<shortcutProviders.count, id: \.self) { idx in
                Button("") {
                    select(scope: .agent(shortcutProviders[idx]))
                }
                .keyboardShortcut(KeyEquivalent(Character("\(idx + 1)")), modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            }
            Button("") {
                select(scope: .aggregate)
            }
            .keyboardShortcut("0", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
    }
}

// MARK: - Compare column

private struct CompareAgentColumn: View {
    let scope: AgentInsightsScope
    let producer: MacAgentInsightsProducer
    let onRemove: () -> Void

    @State private var viewModel: AgentInsightsViewModel?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(scope.provider?.displayName ?? "All agents")
                    .font(UnifiedDesignSystem.Typography.title)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                Spacer()
                Button {
                    onRemove()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove from compare")
            }
            .padding(.horizontal, UnifiedDesignSystem.Spacing.md)
            .padding(.top, UnifiedDesignSystem.Spacing.md)
            Divider().opacity(0.3)
            Group {
                if let viewModel {
                    AgentInsightsView(
                        viewModel: viewModel,
                        presentation: .compact,
                        actions: AgentInsightsView.Actions()
                    )
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 200)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.lg)
                .fill(UnifiedDesignSystem.Colors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.lg)
                .strokeBorder(UnifiedDesignSystem.Colors.borderSubtle, lineWidth: 0.5)
        )
        .task {
            if viewModel == nil {
                viewModel = AgentInsightsViewModel(scope: scope, producer: producer)
            }
        }
    }
}

// MARK: - Legacy workspace sheet

private struct LegacyWorkspaceSheet: View {
    let dataStore: DataStore
    let settingsManager: SettingsManager
    let chatController: ChatSessionController?
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Canvas workspace")
                    .font(UnifiedDesignSystem.Typography.title)
                Spacer()
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(UnifiedDesignSystem.Spacing.md)
            Divider().opacity(0.4)
            InsightsWorkspaceView(
                dataStore: dataStore,
                settingsManager: settingsManager,
                chatController: chatController
            )
            .frame(minWidth: 1100, minHeight: 700)
        }
        .frame(minWidth: 1100, minHeight: 760)
    }
}
