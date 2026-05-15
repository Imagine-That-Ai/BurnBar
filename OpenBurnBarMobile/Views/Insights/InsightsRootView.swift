import SwiftUI
import OpenBurnBarCore
import FirebaseAuth
import FirebaseCore
import FirebaseFirestore

/// Top-level mobile Insights tab content. Adapts to iPhone vs iPad
/// automatically via size classes.
struct InsightsRootView: View {

    @State private var store: InsightsStore?
    let dashboardStore: DashboardStore
    let hermesService: HermesService

    var body: some View {
        Group {
            if let store {
                AdaptiveInsightsLayout(store: store, hermesService: hermesService)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            // Ensure the dashboard store is hydrated before any snapshot is
            // requested — otherwise the synthetic InsightUsageRows would be
            // empty until the user happened to visit another tab first.
            await dashboardStore.load()
            if store == nil {
                let dataSource = MobileInsightDataSource(dashboardStore: dashboardStore)
                if let s = try? InsightsStore(dataSource: dataSource) {
                    store = s
                    // Register the user's Hermes relay as an Insights
                    // gateway as soon as the store is built, so the
                    // first follow-up tap can already stream through
                    // Hermes (instead of falling to local rules until
                    // the next reachability flip).
                    await s.attachHermesIfReachable(via: hermesService)
                }
            } else {
                await store?.refreshSelectedCanvas()
            }
        }
        // Keep the Hermes catalog entry in sync with the relay's
        // reachability — when the user reconnects (or switches relays)
        // re-register so Insights routes through the new connection.
        .onChange(of: hermesService.isReachable) {
            guard let store else { return }
            Task { await store.attachHermesIfReachable(via: hermesService) }
        }
    }
}
private struct AdaptiveInsightsLayout: View {

    @Bindable var store: InsightsStore
    @Bindable var hermesService: HermesService
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var showCanvasList: Bool = false
    @State private var showInspector: Bool = false
    @State private var showTemplateGallery: Bool = false
    @State private var showMissionDetail: Bool = false
    private static let iPhoneNavigationTrayClearance: CGFloat = 96

    var body: some View {
        if sizeClass == .regular {
            iPadLayout
        } else {
            iPhoneLayout
        }
    }

    // MARK: - iPad layout

    private var iPadLayout: some View {
        NavigationSplitView {
            InsightsMobileCanvasList(store: store, showTemplates: $showTemplateGallery)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 320)
        } detail: {
            VStack(spacing: 0) {
                canvasContent
                    .frame(maxHeight: .infinity)
                missionStatusBanner
                composerBar
            }
            .background(UnifiedDesignSystem.Colors.background)
            .navigationTitle(store.currentCanvas?.title ?? "Insights")
            .toolbar { toolbar }
        }
        .sheet(isPresented: $showInspector) {
            InsightsMobileInspectorView(store: store)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showTemplateGallery) {
            InsightsMobileTemplateGallery(store: store, isPresented: $showTemplateGallery)
        }
        .sheet(isPresented: $showMissionDetail) {
            missionDetailSheet
        }
    }

    // MARK: - iPhone layout

    private var iPhoneLayout: some View {
        NavigationStack {
            VStack(spacing: 0) {
                canvasContent
                    .frame(maxHeight: .infinity)
                missionStatusBanner
                composerBar
                    .padding(.bottom, Self.iPhoneNavigationTrayClearance)
            }
            .background(UnifiedDesignSystem.Colors.background)
            .navigationTitle(store.currentCanvas?.title ?? "Insights")
            .toolbar { toolbar }
        }
        .sheet(isPresented: $showCanvasList) {
            InsightsMobileCanvasList(store: store, showTemplates: $showTemplateGallery)
                .presentationDetents([.fraction(0.5), .large])
        }
        .sheet(isPresented: $showInspector) {
            InsightsMobileInspectorView(store: store)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showTemplateGallery) {
            InsightsMobileTemplateGallery(store: store, isPresented: $showTemplateGallery)
        }
        .sheet(isPresented: $showMissionDetail) {
            missionDetailSheet
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                showCanvasList = true
            } label: {
                Image(systemName: "rectangle.stack")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                Task { await store.refreshSelectedCanvas() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showInspector = true
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
        }
    }

    @ViewBuilder
    private var canvasContent: some View {
        if let analysis = store.currentAnalysis {
            ZStack(alignment: .top) {
                IntelligenceBriefView(
                    result: analysis,
                    onCitationTap: { citation in
                        // Convert a citation tap into a natural-language
                        // follow-up prompt — the composer already routes
                        // those into a new analysis turn with the cited
                        // entity scoped into the snapshot filter.
                        Task {
                            await store.compose(prompt: IntelligenceBriefCitationPrompt.prompt(for: citation))
                        }
                    },
                    onFollowUpTap: { question in
                        Task { await store.compose(prompt: question.question) }
                    },
                    onMissionLaunchTap: { question, missionKind, _, options in
                        store.dispatchMission(
                            question,
                            missionKind: missionKind,
                            requestedRuntime: options.requestedRuntime,
                            targetProject: options.targetProject,
                            depth: options.depth,
                            approvalMode: options.approvalMode,
                            commandsAllowed: options.commandsAllowed,
                            fileEditsAllowed: options.fileEditsAllowed,
                            via: hermesService
                        )
                    },
                    onPinWidget: { generated in
                        Task { await store.pinGeneratedWidget(generated) }
                    },
                    onConfigureModel: { showInspector = true },
                    onShowAudit: nil
                )
                .scrollDismissesKeyboard(.interactively)

                // Inline status banner — the user always sees the
                // engine acknowledging the tap, completing, or
                // failing. Without this banner, follow-up taps look
                // like no-ops because the engine work is fast and the
                // resulting hero change is subtle.
                InsightsComposerStatusBanner(store: store)
                    .padding(.horizontal, UnifiedDesignSystem.Spacing.md)
                    .padding(.top, UnifiedDesignSystem.Spacing.sm)
            }
        } else if store.currentCanvas != nil {
            // Fallback for a canvas without a generated analysis (rare —
            // refreshSelectedCanvas always populates analysis on success).
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            InsightsMobileEmptyState(store: store, showTemplates: $showTemplateGallery)
        }
    }

    private var composerBar: some View {
        InsightsMobileComposerBar(store: store)
            .padding(UnifiedDesignSystem.Spacing.md)
            .background(.thinMaterial)
    }

    @ViewBuilder
    private var missionStatusBanner: some View {
        switch store.missionStatus {
        case .idle:
            EmptyView()
        case .dispatched(let title, let runtime):
            missionBanner(
                icon: "paperplane.circle.fill",
                tone: UnifiedDesignSystem.Colors.success,
                title: "Mission dispatched to \(runtime)",
                detail: "\(title). Waiting for the Mac agent listener to claim it.",
                feedLines: []
            )
            .onTapGesture { showMissionDetail = true }
        case .tracking(let mission):
            let status = mission.displayStatus
            let isFailed = status == "failed" || status == "agent_launch_failed" || status == "unauthorized"
            let isComplete = status == "completed"
            missionBanner(
                icon: isFailed ? "exclamationmark.triangle.fill" : (isComplete ? "checkmark.circle.fill" : "dot.radiowaves.left.and.right"),
                tone: isFailed ? UnifiedDesignSystem.Colors.warning : (isComplete ? UnifiedDesignSystem.Colors.success : UnifiedDesignSystem.Colors.whimsy),
                title: missionBannerTitle(for: mission),
                detail: missionBannerDetail(for: mission),
                feedLines: mission.events.suffix(4).map { event in
                    "\(event.phase): \(event.message)"
                }
            )
            .onTapGesture { showMissionDetail = true }
        case .failed(let title, let message):
            missionBanner(
                icon: "exclamationmark.triangle.fill",
                tone: UnifiedDesignSystem.Colors.warning,
                title: "Mission was not dispatched",
                detail: "\(title): \(message)",
                feedLines: []
            )
        }
    }

    private func missionBannerTitle(for mission: CLIAgentMissionSnapshot) -> String {
        switch mission.displayStatus {
        case "pending", "queued":
            return "Mission queued for \(mission.runtimeLabel)"
        case "accepted":
            return "Mission accepted by \(mission.runtimeLabel)"
        case "starting":
            return "Mission starting on \(mission.runtimeLabel)"
        case "mac_offline":
            return "Mac offline for \(mission.runtimeLabel)"
        case "running":
            return "Mission running on \(mission.runtimeLabel)"
        case "waiting_for_approval":
            return "Mission waiting for approval on \(mission.runtimeLabel)"
        case "completed":
            return "Mission completed on \(mission.runtimeLabel)"
        case "failed":
            return "Mission failed on \(mission.runtimeLabel)"
        case "canceled", "cancelled":
            return "Mission canceled on \(mission.runtimeLabel)"
        case "unauthorized":
            return "Mac not trusted for \(mission.runtimeLabel)"
        case "agent_launch_failed":
            return "Agent launch failed on \(mission.runtimeLabel)"
        default:
            return "Mission \(mission.displayStatus) on \(mission.runtimeLabel)"
        }
    }

    private func missionBannerDetail(for mission: CLIAgentMissionSnapshot) -> String {
        if mission.status == "failed", let error = mission.errorMessage?.nilIfEmpty {
            return error
        }
        if mission.status == "completed", let result = mission.resultPreview?.nilIfEmpty {
            return result
        }
        return mission.displayLiveSummary?.nilIfEmpty ?? mission.title
    }

    private func missionBanner(icon: String, tone: Color, title: String, detail: String, feedLines: [String]) -> some View {
        HStack(alignment: .top, spacing: UnifiedDesignSystem.Spacing.sm) {
            Image(systemName: icon)
                .foregroundStyle(tone)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(UnifiedDesignSystem.Typography.caption.weight(.semibold))
                    .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                Text(detail)
                    .font(UnifiedDesignSystem.Typography.tiny)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                    .lineLimit(3)
                if !feedLines.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(feedLines, id: \.self) { line in
                            Text(line)
                                .font(UnifiedDesignSystem.Typography.monoTiny)
                                .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                                .lineLimit(2)
                        }
                    }
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
            Button("Dismiss") { store.dismissMissionStatus() }
                .font(UnifiedDesignSystem.Typography.tiny)
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, UnifiedDesignSystem.Spacing.md)
        .padding(.vertical, UnifiedDesignSystem.Spacing.sm)
        .background(.thinMaterial)
    }

    @ViewBuilder
    private var missionDetailSheet: some View {
        switch store.missionStatus {
        case .tracking(let mission):
            MissionLiveDetailView(
                mission: mission,
                onApprovalResponse: { approve in
                    store.respondToMissionApproval(requestID: mission.id, approve: approve)
                }
            )
                .presentationDetents([.medium, .large])
        case .dispatched(let title, let runtime):
            MissionQueuedDetailView(
                title: title,
                runtime: runtime,
                detail: "Waiting for the signed-in Mac agent listener to claim this mission."
            )
            .presentationDetents([.medium])
        case .failed(let title, let message):
            MissionQueuedDetailView(title: title, runtime: "Mac agent fleet", detail: message)
                .presentationDetents([.medium])
        case .idle:
            EmptyView()
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct MissionLiveDetailView: View {
    let mission: CLIAgentMissionSnapshot
    let onApprovalResponse: (Bool) -> Void
    @State private var activeFilters: Set<MissionEventFilter> = Set(MissionEventFilter.allCases)

    private var visibleEvents: [CLIAgentMissionEvent] {
        mission.events.filter { event in
            activeFilters.contains(MissionEventFilter(event: event))
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.lg) {
                    VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.xs) {
                        Text(mission.title)
                            .font(UnifiedDesignSystem.Typography.title)
                            .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                        Text(mission.displayLiveSummary?.nilIfEmpty ?? mission.displayStatus.capitalized)
                            .font(UnifiedDesignSystem.Typography.caption)
                            .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: UnifiedDesignSystem.Spacing.sm) {
                            MissionDetailChip(label: mission.displayStatus.uppercased(), systemImage: mission.isTerminal ? "checkmark.circle" : "dot.radiowaves.left.and.right")
                            MissionDetailChip(label: mission.runtimeLabel, systemImage: "desktopcomputer")
                            MissionDetailChip(label: mission.currentStepLabel, systemImage: "arrow.triangle.2.circlepath")
                            if let tool = mission.activeToolName {
                                MissionDetailChip(label: tool, systemImage: "hammer")
                            }
                            if let artifact = mission.latestArtifactLabel {
                                MissionDetailChip(label: artifact, systemImage: "doc.text")
                            }
                        }
                    }

                    if mission.isWaitingForApproval {
                        MissionDetailSection(title: mission.approvalTitle?.nilIfEmpty ?? "Approval Required") {
                            VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.sm) {
                                Text(mission.approvalMessage?.nilIfEmpty ?? "The Mac is waiting for approval before continuing this mission.")
                                    .font(UnifiedDesignSystem.Typography.caption)
                                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                                HStack(spacing: UnifiedDesignSystem.Spacing.sm) {
                                    Button {
                                        onApprovalResponse(true)
                                    } label: {
                                        Label("Approve", systemImage: "checkmark.circle.fill")
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(UnifiedDesignSystem.Colors.success)

                                    Button(role: .destructive) {
                                        onApprovalResponse(false)
                                    } label: {
                                        Label("Reject", systemImage: "xmark.octagon")
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                    }

                    if let sessionID = mission.sessionID?.nilIfEmpty {
                        MissionDetailSection(title: "Session") {
                            Text(sessionID)
                                .font(UnifiedDesignSystem.Typography.monoTiny)
                                .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                                .textSelection(.enabled)
                        }
                    }

                    MissionDetailSection(title: "Live Timeline") {
                        if mission.events.isEmpty {
                            Text("Waiting for the Mac agent to report progress.")
                                .font(UnifiedDesignSystem.Typography.caption)
                                .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                        } else {
                            MissionEventFilterBar(activeFilters: $activeFilters)
                            VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.sm) {
                                ForEach(visibleEvents) { event in
                                    MissionTimelineRow(event: event)
                                }
                            }
                        }
                    }

                    if let result = mission.resultPreview?.nilIfEmpty {
                        MissionDetailSection(title: "Result") {
                            Text(result)
                                .font(UnifiedDesignSystem.Typography.caption)
                                .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                                .textSelection(.enabled)
                        }
                    }

                    if let error = mission.errorMessage?.nilIfEmpty {
                        MissionDetailSection(title: "Failure") {
                            Text(error)
                                .font(UnifiedDesignSystem.Typography.caption)
                                .foregroundStyle(UnifiedDesignSystem.Colors.warning)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(UnifiedDesignSystem.Spacing.lg)
            }
            .background(UnifiedDesignSystem.Colors.background)
            .navigationTitle("Mission Live")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private enum MissionEventFilter: String, CaseIterable, Identifiable {
    case llm
    case tools
    case errors
    case approvals
    case artifacts
    case status

    var id: String { rawValue }

    init(event: CLIAgentMissionEvent) {
        if event.isError || event.kind == "error" || event.phase == "failed" {
            self = .errors
        } else if event.kind == "tool_call" || event.kind == "tool_result" || event.phase == "tool_use" {
            self = .tools
        } else if event.kind == "approval_request" || event.phase.contains("approval") {
            self = .approvals
        } else if event.kind == "artifact" || event.kind == "changed_file" || event.artifactPath != nil || event.changedFilePath != nil {
            self = .artifacts
        } else if event.kind == "llm_response" || event.kind == "assistant_message" || event.kind == "final_answer" || event.phase == "assistant_response" {
            self = .llm
        } else {
            self = .status
        }
    }

    var label: String {
        switch self {
        case .llm: return "LLM"
        case .tools: return "Tools"
        case .errors: return "Errors"
        case .approvals: return "Approvals"
        case .artifacts: return "Artifacts"
        case .status: return "Status"
        }
    }
}

private struct MissionEventFilterBar: View {
    @Binding var activeFilters: Set<MissionEventFilter>

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: UnifiedDesignSystem.Spacing.xs) {
                ForEach(MissionEventFilter.allCases) { filter in
                    Button {
                        if activeFilters.contains(filter), activeFilters.count > 1 {
                            activeFilters.remove(filter)
                        } else {
                            activeFilters.insert(filter)
                        }
                    } label: {
                        Text(filter.label)
                            .font(UnifiedDesignSystem.Typography.monoTiny.weight(.semibold))
                            .foregroundStyle(activeFilters.contains(filter) ? Color.white : UnifiedDesignSystem.Colors.textSecondary)
                            .padding(.horizontal, UnifiedDesignSystem.Spacing.sm)
                            .padding(.vertical, 6)
                            .background(activeFilters.contains(filter) ? UnifiedDesignSystem.Colors.ember : UnifiedDesignSystem.Colors.surface)
                            .clipShape(RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.sm))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct MissionQueuedDetailView: View {
    let title: String
    let runtime: String
    let detail: String

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.lg) {
                Text(title)
                    .font(UnifiedDesignSystem.Typography.title)
                MissionDetailChip(label: runtime, systemImage: "desktopcomputer")
                Text(detail)
                    .font(UnifiedDesignSystem.Typography.caption)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                Spacer()
            }
            .padding(UnifiedDesignSystem.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(UnifiedDesignSystem.Colors.background)
            .navigationTitle("Mission Live")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct MissionDetailChip: View {
    let label: String
    let systemImage: String

    var body: some View {
        Label(label, systemImage: systemImage)
            .font(UnifiedDesignSystem.Typography.tiny.weight(.semibold))
            .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
            .padding(.horizontal, UnifiedDesignSystem.Spacing.sm)
            .padding(.vertical, 6)
            .background(UnifiedDesignSystem.Colors.surface)
            .clipShape(RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.sm))
    }
}

private struct MissionDetailSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.sm) {
            Text(title)
                .font(UnifiedDesignSystem.Typography.caption.weight(.semibold))
                .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
            content
        }
    }
}

private struct MissionTimelineRow: View {
    let event: CLIAgentMissionEvent

    var body: some View {
        HStack(alignment: .top, spacing: UnifiedDesignSystem.Spacing.sm) {
            Image(systemName: iconName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: UnifiedDesignSystem.Spacing.xs) {
                    Text((event.title?.nilIfEmpty ?? event.phase.replacingOccurrences(of: "_", with: " ")).uppercased())
                        .font(UnifiedDesignSystem.Typography.monoTiny.weight(.semibold))
                        .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                    if let runtime = event.runtime?.nilIfEmpty {
                        Text(runtime)
                            .font(UnifiedDesignSystem.Typography.monoTiny)
                            .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                    }
                }
                Text(event.displayMessage)
                    .font(event.prefersMonospace ? UnifiedDesignSystem.Typography.monoTiny : UnifiedDesignSystem.Typography.caption)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(event.prefersMonospace ? 10 : 0)
                    .background {
                        if event.prefersMonospace {
                            RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.sm)
                                .fill(UnifiedDesignSystem.Colors.surface.opacity(0.72))
                        }
                    }
                if event.messageTruncated {
                    Text("Showing redacted mobile payload capped at \(event.messageLength ?? event.displayMessage.count) chars.")
                        .font(UnifiedDesignSystem.Typography.monoTiny)
                        .foregroundStyle(UnifiedDesignSystem.Colors.warning)
                }
                if event.toolName?.nilIfEmpty != nil || event.artifactPath?.nilIfEmpty != nil || event.changedFilePath?.nilIfEmpty != nil {
                    HStack(spacing: UnifiedDesignSystem.Spacing.xs) {
                        if let toolName = event.toolName?.nilIfEmpty {
                            MissionDetailChip(label: toolName, systemImage: "hammer")
                        }
                        if let artifactPath = event.artifactPath?.nilIfEmpty {
                            MissionDetailChip(label: artifactPath, systemImage: "doc.text")
                        }
                        if let changedFilePath = event.changedFilePath?.nilIfEmpty {
                            MissionDetailChip(label: changedFilePath, systemImage: "pencil.and.list.clipboard")
                        }
                    }
                }
                Text(event.timestamp)
                    .font(UnifiedDesignSystem.Typography.monoTiny)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
            }
        }
    }

    private var iconName: String {
        switch event.phase {
        case "agent_launch_failed": return "xmark.octagon.fill"
        case "tool_use", "tool_result": return "hammer"
        case "assistant_response": return "text.bubble"
        case "completed": return "checkmark.circle.fill"
        case "failed": return "exclamationmark.triangle.fill"
        default: return "circle.dotted"
        }
    }

    private var iconColor: Color {
        if event.isError { return UnifiedDesignSystem.Colors.warning }
        switch event.phase {
        case "completed": return UnifiedDesignSystem.Colors.success
        case "failed": return UnifiedDesignSystem.Colors.warning
        case "tool_use", "tool_result": return UnifiedDesignSystem.Colors.ember
        default: return UnifiedDesignSystem.Colors.whimsy
        }
    }
}

private extension CLIAgentMissionEvent {
    var displayMessage: String {
        fullMessage?.nilIfEmpty ?? message
    }

    var prefersMonospace: Bool {
        kind == "tool_call"
            || kind == "tool_result"
            || kind == "llm_response"
            || kind == "assistant_message"
            || kind == "final_answer"
            || displayMessage.contains("\n")
    }
}

@Observable
@MainActor
final class MobileMissionActivityCenter {
    enum ActivityState: Equatable, Sendable {
        case idle
        case tracking(CLIAgentMissionSnapshot)
        case failed(String)
    }

    var state: ActivityState = .idle
    private var authHandle: AuthStateDidChangeListenerHandle?
    private var missionListRegistration: ListenerRegistration?
    private var missionObservation: CLIAgentMissionObservation?
    private var observedMissionID: String?
    private var dismissedMissionIDs: Set<String> = []

    func start() {
        guard authHandle == nil else { return }
        guard FirebaseApp.app() != nil else { return }
        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                self?.restartListListener(uid: user?.uid)
            }
        }
        restartListListener(uid: Auth.auth().currentUser?.uid)
    }

    func dismissCurrent() {
        if case .tracking(let mission) = state {
            dismissedMissionIDs.insert(mission.id)
        }
        missionObservation?.cancel()
        missionObservation = nil
        observedMissionID = nil
        state = .idle
    }

    func respondToApproval(approve: Bool) {
        guard case .tracking(let mission) = state else { return }
        Task {
            do {
                try await CLIAgentMissionDispatcher.shared.respondToApproval(
                    requestID: mission.id,
                    approve: approve
                )
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    private func restartListListener(uid: String?) {
        missionListRegistration?.remove()
        missionListRegistration = nil
        missionObservation?.cancel()
        missionObservation = nil
        observedMissionID = nil
        guard let uid else {
            state = .idle
            return
        }

        missionListRegistration = Firestore.firestore()
            .collection("users").document(uid)
            .collection("cli_agent_mission_requests")
            .order(by: "createdAt", descending: true)
            .limit(to: 6)
            .addSnapshotListener { [weak self] snapshot, error in
                Task { @MainActor in
                    if let error {
                        self?.state = .failed(error.localizedDescription)
                        return
                    }
                    let missions = snapshot?.documents.compactMap {
                        CLIAgentMissionSnapshot(documentID: $0.documentID, data: $0.data())
                    } ?? []
                    self?.selectMission(from: missions)
                }
            }
    }

    private func selectMission(from missions: [CLIAgentMissionSnapshot]) {
        let visible = missions.filter { !dismissedMissionIDs.contains($0.id) }
        guard let mission = visible.first(where: { !$0.isTerminal }) ?? visible.first else {
            state = .idle
            return
        }
        guard mission.id != observedMissionID else { return }
        missionObservation?.cancel()
        observedMissionID = mission.id
        do {
            missionObservation = try CLIAgentMissionDispatcher.shared.observe(
                requestID: mission.id,
                onUpdate: { [weak self] snapshot in
                    self?.state = .tracking(snapshot)
                },
                onError: { [weak self] message in
                    self?.state = .failed(message)
                }
            )
            state = .tracking(mission)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

}

struct MobileMissionActivityOverlay: View {
    @Bindable var center: MobileMissionActivityCenter
    @State private var showMissionDetail = false

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                switch center.state {
                case .idle:
                    EmptyView()
                case .tracking(let mission):
                    missionButton(for: mission)
                case .failed:
                    alertButton
                }
            }
        }
        .sheet(isPresented: $showMissionDetail) {
            switch center.state {
            case .tracking(let mission):
                MissionLiveDetailView(
                    mission: mission,
                    onApprovalResponse: { approve in center.respondToApproval(approve: approve) }
                )
                .presentationDetents([.medium, .large])
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Dismiss") {
                            center.dismissCurrent()
                            showMissionDetail = false
                        }
                    }
                }
            case .failed(let message):
                MissionQueuedDetailView(title: "Mission listener", runtime: "Mobile", detail: message)
                    .presentationDetents([.medium])
            case .idle:
                EmptyView()
            }
        }
    }

    private func missionButton(for mission: CLIAgentMissionSnapshot) -> some View {
        let state = orbState(for: mission)
        return Button {
            showMissionDetail = true
        } label: {
            ZStack {
                // Glow when active
                if state.isActive {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    state.accent.opacity(0.30),
                                    state.accent.opacity(0.0)
                                ],
                                center: .center,
                                startRadius: 16,
                                endRadius: 36
                            )
                        )
                        .frame(width: 72, height: 72)
                        .blur(radius: 5)
                }

                // Disc
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 48, height: 48)
                    .overlay(
                        Circle()
                            .stroke(state.accent.opacity(state.isActive ? 0.75 : 0.25), lineWidth: state.isActive ? 1.5 : 0.8)
                    )
                    .shadow(
                        color: state.isActive ? state.accent.opacity(0.20) : Color.black.opacity(0.20),
                        radius: state.isActive ? 12 : 8,
                        x: 0,
                        y: state.isActive ? 4 : 3
                    )

                // Center
                if state.isActive, let label = state.label {
                    VStack(spacing: 0) {
                        Image(systemName: state.icon)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(state.accent)
                        Text(label)
                            .font(.system(size: 7, weight: .bold, design: .monospaced))
                            .foregroundStyle(state.accent.opacity(0.92))
                            .lineLimit(1)
                    }
                } else {
                    Image(systemName: state.icon)
                        .font(.system(size: 16, weight: .light))
                        .foregroundStyle(state.isActive ? state.accent : UnifiedDesignSystem.Colors.textSecondary.opacity(0.6))
                }
            }
            .frame(width: 48, height: 48)
        }
        .accessibilityLabel("Open live mission window. \(state.label ?? state.icon)")
        .padding(.trailing, 18)
    }

    private func orbState(for mission: CLIAgentMissionSnapshot) -> OrbState {
        if mission.isTerminal {
            return OrbState(accent: UnifiedDesignSystem.Colors.success, icon: "checkmark.circle.fill", label: nil, isActive: false)
        }

        let latest = mission.events.last
        let accent = missionAccentColor(mission)

        guard let event = latest else {
            return OrbState(accent: accent, icon: "dot.radiowaves.left.and.right", label: nil, isActive: true)
        }

        let kind = event.kind
        if kind == "tool_call" || kind == "tool_use" {
            let name = event.toolName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? event.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Tool"
            return OrbState(accent: accent, icon: "hammer.fill", label: name, isActive: true)
        }
        if kind == "llm_response" || kind == "assistant_message" || kind == "final_answer" {
            return OrbState(accent: accent, icon: "quote.bubble.fill", label: "LLM", isActive: true)
        }
        if kind == "approval_request" || kind == "approval" {
            return OrbState(accent: UnifiedDesignSystem.Colors.hermesAureate, icon: "hand.raised.fill", label: "Approve", isActive: true)
        }
        if kind == "error" {
            return OrbState(accent: UnifiedDesignSystem.Colors.ember, icon: "exclamationmark.triangle.fill", label: "Error", isActive: true)
        }
        return OrbState(accent: accent, icon: "sparkles", label: nil, isActive: true)
    }

    private struct OrbState {
        let accent: Color
        let icon: String
        let label: String?
        let isActive: Bool
    }

    private func missionAccentColor(_ mission: CLIAgentMissionSnapshot) -> Color {
        let latest = mission.events.last
        guard let event = latest else { return UnifiedDesignSystem.Colors.amber }
        if event.isError || event.kind == "error" { return UnifiedDesignSystem.Colors.ember }
        if event.kind == "approval_request" || event.phase.contains("approval") { return UnifiedDesignSystem.Colors.hermesAureate }
        if event.kind == "tool_call" || event.phase == "tool_use" { return UnifiedDesignSystem.Colors.amber }
        if event.kind == "llm_response" || event.phase == "assistant_response" { return UnifiedDesignSystem.Colors.whimsy }
        return UnifiedDesignSystem.Colors.amber
    }

    private var alertButton: some View {
        Button {
            showMissionDetail = true
        } label: {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 48, height: 48)
                    .overlay(
                        Circle()
                            .stroke(UnifiedDesignSystem.Colors.ember.opacity(0.75), lineWidth: 1.5)
                    )
                    .shadow(color: UnifiedDesignSystem.Colors.ember.opacity(0.20), radius: 12, x: 0, y: 4)

                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(UnifiedDesignSystem.Colors.ember)
            }
            .frame(width: 48, height: 48)
        }
        .accessibilityLabel("Mission alert")
        .padding(.trailing, 18)
    }
}

// MARK: - Empty state

private struct InsightsMobileEmptyState: View {
    @Bindable var store: InsightsStore
    @Binding var showTemplates: Bool

    var body: some View {
        VStack(spacing: UnifiedDesignSystem.Spacing.md) {
            Image(systemName: "sparkles.tv")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(UnifiedDesignSystem.Colors.ember)
            Text("Start with a template")
                .font(UnifiedDesignSystem.Typography.title)
            Text("Or just ask the composer below — we'll author a canvas from your data.")
                .font(UnifiedDesignSystem.Typography.caption)
                .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
            Button("Browse templates") { showTemplates = true }
                .buttonStyle(.borderedProminent)
                .tint(UnifiedDesignSystem.Colors.ember)
        }
        .padding(UnifiedDesignSystem.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Canvas list

private struct InsightsMobileCanvasList: View {
    @Bindable var store: InsightsStore
    @Binding var showTemplates: Bool

    var body: some View {
        List {
            Section("Canvases") {
                ForEach(store.canvases) { canvas in
                    Button {
                        store.selectedCanvasID = canvas.id
                        Task { await store.refreshSelectedCanvas(autoSwitchEmptyDefaultCanvas: false) }
                    } label: {
                        HStack {
                            Image(systemName: canvas.symbolName)
                                .foregroundStyle(UnifiedDesignSystem.Colors.ember)
                            VStack(alignment: .leading) {
                                Text(canvas.title)
                                if let summary = canvas.summary {
                                    Text(summary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    Task {
                        for idx in offsets {
                            let id = store.canvases[idx].id
                            store.selectedCanvasID = id
                            await store.deleteCurrentCanvas()
                        }
                    }
                }
            }
            Section {
                Button("New from template") { showTemplates = true }
            }
        }
        .navigationTitle("Canvases")
    }
}

// MARK: - Composer bar

private struct InsightsMobileComposerBar: View {
    @Bindable var store: InsightsStore
    @State private var prompt: String = ""
    @FocusState private var promptFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.xs) {
            HStack(spacing: UnifiedDesignSystem.Spacing.sm) {
                TextField("Ask anything…", text: $prompt, axis: .horizontal)
                    .textFieldStyle(.plain)
                    .focused($promptFocused)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .padding(.vertical, 6)
                    .padding(.horizontal, UnifiedDesignSystem.Spacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md)
                            .fill(UnifiedDesignSystem.Colors.surface)
                    )
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("Done") { promptFocused = false }
                                .font(UnifiedDesignSystem.Typography.caption)
                        }
                    }
                Button {
                    send()
                } label: {
                    if store.isComposing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "paperplane.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(UnifiedDesignSystem.Colors.ember)
                .disabled(prompt.isEmpty || store.isComposing)
                .accessibilityLabel("Send")
            }
            if let error = store.composerError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(UnifiedDesignSystem.Colors.error)
            }
        }
    }

    private func send() {
        let p = prompt
        guard !p.isEmpty, !store.isComposing else { return }
        prompt = ""
        promptFocused = false
        Task { await store.compose(prompt: p) }
    }
}

// MARK: - Inspector

private struct InsightsMobileInspectorView: View {
    @Bindable var store: InsightsStore

    var body: some View {
        NavigationStack {
            Form {
                // Model + privacy is the most-changed control surface
                // for the brief, so it leads the inspector. Both
                // controls are bound to the same `InsightsStore` state
                // that the brief reads back out in its meta strip, so
                // changing them here is immediately reflected on the
                // brief without a round-trip.
                Section {
                    Picker(selection: Binding(
                        get: { store.selectedModelTag.modelID },
                        set: { newID in
                            guard let model = store.modelCatalog.first(where: { $0.id == newID }) else { return }
                            store.selectedModelTag = .init(
                                providerKey: model.providerKey,
                                modelID: model.id,
                                displayName: model.displayName,
                                egressTier: model.egressTier
                            )
                        }
                    )) {
                        ForEach(store.modelCatalog) { model in
                            Label {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(model.displayName)
                                    Text(model.egressTier.displayLabel)
                                        .font(.caption2)
                                        .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                                }
                            } icon: {
                                Image(systemName: model.egressTier.symbolName)
                            }
                            .tag(model.id)
                        }
                    } label: {
                        Label("Model", systemImage: store.selectedModelTag.egressTier.symbolName)
                    }
                    .pickerStyle(.navigationLink)

                    Toggle(isOn: $store.privacyMode) {
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Local-only models")
                                Text("Restrict to engines that never leave this device")
                                    .font(.caption2)
                                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                            }
                        } icon: {
                            Image(systemName: "lock.shield.fill")
                        }
                    }
                } header: {
                    Text("Model & privacy")
                } footer: {
                    Text("Currently running on \(store.selectedModelTag.displayName) · \(store.selectedModelTag.egressTier.displayLabel).")
                        .font(.caption)
                }

                if let canvas = store.currentCanvas {
                    Section("Canvas") {
                        Text(canvas.title)
                        Picker("Window", selection: Binding(
                            get: { canvas.filter.window },
                            set: { newWindow in
                                Task {
                                    var updated = canvas
                                    updated.filter.window = newWindow
                                    await store.updateCanvas(updated)
                                    await store.refreshSelectedCanvas(autoSwitchEmptyDefaultCanvas: false)
                                }
                            }
                        )) {
                            ForEach(predefinedWindows, id: \.id) { window in
                                Text(window.displayName).tag(window)
                            }
                        }
                        Picker("Theme", selection: Binding(
                            get: { canvas.theme },
                            set: { newTheme in
                                Task {
                                    var updated = canvas
                                    updated.theme = newTheme
                                    await store.updateCanvas(updated)
                                }
                            }
                        )) {
                            ForEach(InsightTheme.allCases) { theme in
                                Text(theme.displayName).tag(theme)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Brief options")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var predefinedWindows: [InsightTimeWindow] {
        [.today, .last24h, .last7d, .last30d, .last90d, .last365d, .allTime]
    }
}

// MARK: - Templates

private struct InsightsMobileTemplateGallery: View {
    @Bindable var store: InsightsStore
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            List(MobileInsightsTemplates.all) { template in
                Button {
                    Task {
                        await store.createCanvas(from: template)
                        isPresented = false
                    }
                } label: {
                    HStack {
                        Image(systemName: template.symbolName)
                            .foregroundStyle(UnifiedDesignSystem.Colors.ember)
                        VStack(alignment: .leading) {
                            Text(template.title)
                            Text(template.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Templates")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { isPresented = false }
                }
            }
        }
    }
}

// MARK: - Composer status banner

/// Inline banner that shows the live state of the most recent
/// `InsightsStore.compose(prompt:)` call. Renders four states:
///
/// * `.idle` — invisible (no UI noise when nothing is happening).
/// * `.running` — coral-tinted pill with a spinner + "Asking X via
///   {model}" text. Tells the user the tap registered.
/// * `.succeeded` — short-lived green confirmation that auto-dismisses
///   so the brief returns to its quiet editorial mode.
/// * `.failed` — error pill with the underlying error message, the
///   model that was attempted, and a Retry / Dismiss pair.
///
/// This is the single source of truth for "did my tap do anything?"
/// across follow-up links, citation taps, and the inline composer.
private struct InsightsComposerStatusBanner: View {
    @Bindable var store: InsightsStore
    @State private var autoDismissTask: Task<Void, Never>?

    var body: some View {
        Group {
            switch store.composerStatus {
            case .idle:
                EmptyView()
            case .running(let prompt, let model, let egress):
                runningPill(prompt: prompt, model: model, egress: egress)
            case .succeeded(let prompt, let model):
                succeededPill(prompt: prompt, model: model)
                    .onAppear { scheduleAutoDismiss() }
                    .onDisappear { autoDismissTask?.cancel() }
            case .failed(let prompt, let model, let message):
                failedPill(prompt: prompt, model: model, message: message)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: store.composerStatus)
    }

    private func runningPill(prompt: String, model: String, egress: String) -> some View {
        HStack(spacing: UnifiedDesignSystem.Spacing.sm) {
            ProgressView()
                .controlSize(.small)
                .tint(UnifiedDesignSystem.Colors.ember)
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.runningTitle(model: model))
                    .font(UnifiedDesignSystem.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                Text("\"\(prompt)\" · \(egress)")
                    .font(UnifiedDesignSystem.Typography.tiny)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, UnifiedDesignSystem.Spacing.md)
        .padding(.vertical, UnifiedDesignSystem.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md, style: .continuous)
                .fill(UnifiedDesignSystem.Colors.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md, style: .continuous)
                .strokeBorder(UnifiedDesignSystem.Colors.ember.opacity(0.45), lineWidth: 0.75)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(Self.runningTitle(model: model)): \(prompt)")
    }

    /// Honest pill text: local rules summarize, LLMs answer. Avoids the
    /// misleading "Asking via Local rules" framing where no LLM is involved.
    private static func runningTitle(model: String) -> String {
        isLocalRulesModel(model) ? "Summarizing data · no LLM configured" : "Asking via \(model)"
    }

    private static func succeededTitle(model: String) -> String {
        isLocalRulesModel(model) ? "Data summary ready" : "Answered by \(model)"
    }

    private static func isLocalRulesModel(_ display: String) -> Bool {
        display.localizedCaseInsensitiveContains("Local rules")
    }

    private func succeededPill(prompt: String, model: String) -> some View {
        HStack(spacing: UnifiedDesignSystem.Spacing.sm) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(UnifiedDesignSystem.Colors.success)
            Text(Self.succeededTitle(model: model))
                .font(UnifiedDesignSystem.Typography.caption)
                .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
            Spacer(minLength: 0)
            Button("Dismiss") {
                autoDismissTask?.cancel()
                store.dismissComposerStatus()
            }
            .buttonStyle(.plain)
            .font(UnifiedDesignSystem.Typography.tiny)
            .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
        }
        .padding(.horizontal, UnifiedDesignSystem.Spacing.md)
        .padding(.vertical, UnifiedDesignSystem.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md, style: .continuous)
                .fill(UnifiedDesignSystem.Colors.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md, style: .continuous)
                .strokeBorder(UnifiedDesignSystem.Colors.success.opacity(0.45), lineWidth: 0.75)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(Self.succeededTitle(model: model)). \(prompt)")
    }

    private func failedPill(prompt: String, model: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.xs) {
            HStack(spacing: UnifiedDesignSystem.Spacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(UnifiedDesignSystem.Colors.error)
                Text("\(model) couldn't answer")
                    .font(UnifiedDesignSystem.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                Spacer(minLength: 0)
            }
            Text("\"\(prompt)\"")
                .font(UnifiedDesignSystem.Typography.tiny)
                .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                .lineLimit(2)
            Text(message)
                .font(UnifiedDesignSystem.Typography.tiny)
                .foregroundStyle(UnifiedDesignSystem.Colors.error)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: UnifiedDesignSystem.Spacing.sm) {
                Button {
                    Task { await store.retryComposerStatus() }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .labelStyle(.titleAndIcon)
                        .font(UnifiedDesignSystem.Typography.tiny)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(UnifiedDesignSystem.Colors.ember)
                Button("Dismiss") { store.dismissComposerStatus() }
                    .buttonStyle(.plain)
                    .font(UnifiedDesignSystem.Typography.tiny)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, UnifiedDesignSystem.Spacing.md)
        .padding(.vertical, UnifiedDesignSystem.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md, style: .continuous)
                .fill(UnifiedDesignSystem.Colors.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md, style: .continuous)
                .strokeBorder(UnifiedDesignSystem.Colors.error.opacity(0.55), lineWidth: 0.75)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(model) couldn't answer \(prompt). \(message). Tap Retry to try again.")
    }

    private func scheduleAutoDismiss() {
        autoDismissTask?.cancel()
        autoDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_400_000_000) // 2.4s
            guard !Task.isCancelled,
                  case .succeeded = store.composerStatus else { return }
            store.dismissComposerStatus()
        }
    }
}
