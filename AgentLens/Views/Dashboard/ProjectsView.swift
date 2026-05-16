import Charts
import OpenBurnBarCore
import SwiftUI

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Merged Project Model

struct ProjectReentryControl: Identifiable, Equatable {
    let cadence: BurnBarControllerReviewCadence
    let title: String
    let isEnabled: Bool

    var id: BurnBarControllerReviewCadence { cadence }
}

struct ProjectReviewHistoryIndicator: Identifiable, Equatable {
    let cadence: BurnBarControllerReviewCadence
    let reviewedAt: Date

    var id: String { "\(cadence.rawValue)-\(reviewedAt.timeIntervalSinceReferenceDate)" }
}

struct MergedProject: Identifiable {
    let id: String
    let slug: String
    let displayName: String
    let registeredProject: BurnBarReviewProjectSnapshot?
    let totalCost: Double
    let totalTokens: Int
    let sessionCount: Int
    let providers: [AgentProvider]

    var isRegistered: Bool { registeredProject != nil }
    var cadenceLabel: String? {
        guard let p = registeredProject else { return nil }
        switch p.preferredCadence {
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        case .adHoc: return "Ad hoc"
        }
    }
    var automationMode: BurnBarControllerProjectAutomationMode? { registeredProject?.automationMode }
    var pendingQuestionCount: Int { registeredProject?.pendingQuestionCount ?? 0 }
    var openFollowupCount: Int { registeredProject?.openFollowupCount ?? 0 }
    var activeMissionCount: Int { registeredProject?.activeMissionCount ?? 0 }
    var needsAttention: Bool { registeredProject?.needsOperatorAttention ?? false }

    var attentionSummary: String? {
        var parts: [String] = []
        if pendingQuestionCount > 0 { parts.append("\(pendingQuestionCount) question\(pendingQuestionCount == 1 ? "" : "s")") }
        if activeMissionCount > 0 { parts.append("\(activeMissionCount) mission\(activeMissionCount == 1 ? "" : "s")") }
        if openFollowupCount > 0 { parts.append("\(openFollowupCount) followup\(openFollowupCount == 1 ? "" : "s")") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    func reentryReviewControls(daemonIsHealthy: Bool) -> [ProjectReentryControl] {
        guard isRegistered else { return [] }
        return [
            ProjectReentryControl(
                cadence: .daily,
                title: "Run Daily Check-In",
                isEnabled: daemonIsHealthy
            ),
            ProjectReentryControl(
                cadence: .weekly,
                title: "Run Weekly Review",
                isEnabled: daemonIsHealthy
            )
        ]
    }

    var reviewHistoryIndicators: [ProjectReviewHistoryIndicator] {
        guard let project = registeredProject else { return [] }
        var indicators: [ProjectReviewHistoryIndicator] = []
        if let latestWeekly = project.latestWeeklyReviewAt {
            indicators.append(
                ProjectReviewHistoryIndicator(cadence: .weekly, reviewedAt: latestWeekly)
            )
        }
        if let latestDaily = project.latestDailyReviewAt {
            indicators.append(
                ProjectReviewHistoryIndicator(cadence: .daily, reviewedAt: latestDaily)
            )
        }
        return indicators
    }
}

// MARK: - Projects View (List → Hub)

struct ProjectsView: View {
    let dataStore: DataStore
    let settingsManager: SettingsManager
    @Bindable var operatingLayer: OpenBurnBarOperatingLayer
    let chatController: ChatSessionController

    @State private var daemonManager: OpenBurnBarDaemonManager
    @State private var openProject: MergedProject?
    @State private var draft: ControllerProjectDraft?
    @State private var feedback: String?
    @State private var listAppeared = false

    init(
        dataStore: DataStore,
        settingsManager: SettingsManager,
        operatingLayer: OpenBurnBarOperatingLayer,
        chatController: ChatSessionController,
        daemonManager: OpenBurnBarDaemonManager = .shared
    ) {
        self.dataStore = dataStore
        self.settingsManager = settingsManager
        self._operatingLayer = Bindable(operatingLayer)
        self.chatController = chatController
        _daemonManager = State(initialValue: daemonManager)
    }

    private var daemonIsHealthy: Bool {
        if case .healthy = daemonManager.status { return true }
        return false
    }

    // MARK: - Merge data sources

    private var mergedProjects: [MergedProject] {
        // Usage by project
        var usageByProject: [String: (cost: Double, tokens: Int, count: Int, providers: Set<AgentProvider>)] = [:]
        for usage in dataStore.usages {
            let key = usage.projectName
            let existing = usageByProject[key] ?? (0, 0, 0, [])
            usageByProject[key] = (
                existing.cost + usage.cost,
                existing.tokens + usage.totalTokens,
                existing.count + 1,
                existing.providers.union([usage.provider])
            )
        }

        // Registered projects
        var merged: [String: MergedProject] = [:]
        for project in daemonManager.controllerProjects {
            let slug = project.projectSlug
            let usage = usageByProject[slug] ?? usageByProject[project.displayName]
            merged[slug] = MergedProject(
                id: slug,
                slug: slug,
                displayName: project.displayName,
                registeredProject: project,
                totalCost: usage?.cost ?? 0,
                totalTokens: usage?.tokens ?? 0,
                sessionCount: usage?.count ?? 0,
                providers: usage.map { Array($0.providers).sorted { $0.rawValue < $1.rawValue } } ?? []
            )
            usageByProject.removeValue(forKey: slug)
            usageByProject.removeValue(forKey: project.displayName)
        }

        // Unregistered usage-only projects
        for (name, usage) in usageByProject {
            merged[name] = MergedProject(
                id: name,
                slug: name,
                displayName: name,
                registeredProject: nil,
                totalCost: usage.cost,
                totalTokens: usage.tokens,
                sessionCount: usage.count,
                providers: Array(usage.providers).sorted { $0.rawValue < $1.rawValue }
            )
        }

        // Sort: attention first, then by cost descending, then by slug ascending (deterministic tie-break)
        return merged.values.sorted { lhs, rhs in
            if lhs.needsAttention != rhs.needsAttention { return lhs.needsAttention }
            if lhs.totalCost != rhs.totalCost { return lhs.totalCost > rhs.totalCost }
            return lhs.slug.localizedCaseInsensitiveCompare(rhs.slug) == .orderedAscending
        }
    }

    // MARK: - Body

    var body: some View {
        Group {
            if let project = openProject {
                ProjectHubView(
                    project: project,
                    dataStore: dataStore,
                    operatingLayer: operatingLayer,
                    daemonManager: daemonManager,
                    settingsManager: settingsManager,
                    chatController: chatController,
                    onBack: {
                        withAnimation(DesignSystem.Animation.standard) {
                            openProject = nil
                        }
                    },
                    onEditSetup: {
                        draft = ControllerProjectDraft(project: project.registeredProject)
                    },
                    onLaunchReview: { cadence in
                        Task { await launchReview(projectSlug: project.slug, cadence: cadence, origin: .projects) }
                    },
                    onRegister: {
                        var newDraft = ControllerProjectDraft()
                        newDraft.displayName = project.displayName
                        newDraft.projectSlug = project.slug
                        draft = newDraft
                    }
                )
                .id("project-hub-\(project.slug)")
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .trailing).combined(with: .opacity)
                ))
            } else {
                projectListView
                    .id("project-list")
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            }
        }
        .animation(DesignSystem.Animation.standard, value: openProject?.slug)
        .background(DesignSystem.Colors.background)
        .task { await refreshControllerProjectsIfNeeded() }
        .sheet(item: $draft) { draft in
            ControllerProjectEditorSheet(
                draft: draft,
                onCancel: { self.draft = nil },
                onSave: { updatedDraft in
                    Task { await saveControllerProject(updatedDraft) }
                }
            )
        }
    }

    // MARK: - List View

    private var projectListView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
                // Header
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        Text("Projects")
                            .font(DesignSystem.Typography.title)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)

                        HStack(spacing: DesignSystem.Spacing.md) {
                            Text("\(mergedProjects.count) project\(mergedProjects.count == 1 ? "" : "s")")
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)

                            let attentionCount = mergedProjects.filter(\.needsAttention).count
                            if attentionCount > 0 {
                                Text("\(attentionCount) need attention")
                                    .font(DesignSystem.Typography.caption)
                                    .foregroundStyle(DesignSystem.Colors.amber)
                            }
                        }
                    }

                    Spacer()

                    if daemonIsHealthy {
                        Button {
                            draft = ControllerProjectDraft()
                        } label: {
                            HStack(spacing: DesignSystem.Spacing.xs) {
                                Image(systemName: "plus")
                                    .font(.system(size: 11, weight: .semibold))
                                Text("Add Project")
                                    .font(DesignSystem.Typography.caption)
                            }
                            .foregroundStyle(DesignSystem.Colors.whimsy)
                            .padding(.horizontal, DesignSystem.Spacing.md)
                            .padding(.vertical, DesignSystem.Spacing.sm)
                            .background(
                                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                                    .fill(DesignSystem.Colors.whimsy.opacity(0.10))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                                    .stroke(DesignSystem.Colors.whimsy.opacity(0.3), lineWidth: 0.75)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                if let feedback = feedback?.nonEmpty {
                    Text(feedback)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }

                // Project rows
                if mergedProjects.isEmpty {
                    VStack(spacing: DesignSystem.Spacing.lg) {
                        Image(systemName: "folder")
                            .font(.system(size: 48, weight: .thin))
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                        Text("No projects yet")
                            .font(DesignSystem.Typography.headline)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                        Text("Projects appear when OpenBurnBar scans agent sessions or you register one for scheduled reviews.")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DesignSystem.Spacing.xxxl)
                } else {
                    VStack(spacing: DesignSystem.Spacing.md) {
                        ForEach(Array(mergedProjects.enumerated()), id: \.element.id) { index, project in
                            ProjectListRow(project: project) {
                                openProject = project
                            }
                            .opacity(listAppeared ? 1 : 0)
                            .offset(y: listAppeared ? 0 : 8)
                            .animation(
                                DesignSystem.Animation.standard.delay(Double(index) * 0.04),
                                value: listAppeared
                            )
                        }
                    }
                }
            }
            .padding(DesignSystem.Spacing.xl)
        }
        .onAppear { listAppeared = true }
    }

    // MARK: - Actions

    @MainActor
    private func refreshControllerProjectsIfNeeded() async {
        guard settingsManager.controllerRuntimeEnabled else { return }
        do {
            _ = try await daemonManager.refreshControllerProjects()
        } catch {
            feedback = error.localizedDescription
        }
    }

    @MainActor
    private func saveControllerProject(_ updatedDraft: ControllerProjectDraft) async {
        do {
            _ = try await daemonManager.saveControllerProject(updatedDraft.snapshot())
            feedback = "Saved \(updatedDraft.displayName.isEmpty ? updatedDraft.projectSlug : updatedDraft.displayName)."
            draft = nil
        } catch {
            feedback = error.localizedDescription
        }
    }

    @MainActor
    private func launchReview(
        projectSlug: String,
        cadence: BurnBarControllerReviewCadence,
        origin: BurnBarControllerReviewRunOrigin
    ) async {
        do {
            let response = try await daemonManager.launchControllerReview(
                projectSlug: projectSlug,
                cadence: cadence,
                origin: origin
            )
            let runSuffix = response.run.launchedRunID.map { " (\($0.rawValue))" } ?? ""
            let cadenceLabel = cadence == .daily ? "daily check-in" : (cadence == .weekly ? "weekly review" : "review")
            feedback = "Launched a \(cadenceLabel) for \(projectSlug)\(runSuffix)."
        } catch {
            feedback = error.localizedDescription
        }
    }
}

// MARK: - Project List Row

private struct ProjectListRow: View {
    let project: MergedProject
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            GlassCard {
                HStack(spacing: DesignSystem.Spacing.lg) {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        HStack(spacing: DesignSystem.Spacing.sm) {
                            Text(project.displayName)
                                .font(DesignSystem.Typography.headline)
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                                .lineLimit(1)

                            if !project.isRegistered {
                                statusPill(title: "Unregistered", color: DesignSystem.Colors.textMuted)
                            }
                        }

                        if let attention = project.attentionSummary {
                            HStack(spacing: DesignSystem.Spacing.xs) {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(DesignSystem.Colors.amber)
                                Text(attention)
                                    .font(DesignSystem.Typography.caption)
                                    .foregroundStyle(DesignSystem.Colors.amber)
                            }
                        } else if project.isRegistered {
                            Text("No pending items")
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                        }

                        HStack(spacing: DesignSystem.Spacing.md) {
                            if project.sessionCount > 0 {
                                Text(project.totalCost.formatAsCost())
                                    .font(DesignSystem.Typography.monoSmall)
                                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                                Text("\(project.sessionCount) session\(project.sessionCount == 1 ? "" : "s")")
                                    .font(DesignSystem.Typography.tiny)
                                    .foregroundStyle(DesignSystem.Colors.textMuted)
                            }
                            HStack(spacing: DesignSystem.Spacing.xs) {
                                ForEach(project.providers.prefix(4), id: \.self) { provider in
                                    ProviderLogoView(provider: provider, size: 14, useFallbackColor: false)
                                }
                            }
                        }
                    }

                    Spacer(minLength: 0)

                    VStack(alignment: .trailing, spacing: 6) {
                        if let cadence = project.cadenceLabel {
                            statusPill(title: cadence, color: DesignSystem.Colors.blaze)
                        }
                        if let mode = project.automationMode {
                            statusPill(title: automationLabel(mode), color: automationColor(mode))
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    }
                }
                .padding(DesignSystem.Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.015 : 1.0)
        .animation(DesignSystem.Animation.hover, value: isHovered)
        .onHover { isHovered = $0 }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func automationLabel(_ mode: BurnBarControllerProjectAutomationMode) -> String {
        switch mode {
        case .manual: return "Manual"
        case .suggested: return "Suggested"
        case .scheduled: return "Scheduled"
        }
    }

    private func automationColor(_ mode: BurnBarControllerProjectAutomationMode) -> Color {
        switch mode {
        case .manual: return DesignSystem.Colors.textMuted
        case .suggested: return DesignSystem.Colors.amber
        case .scheduled: return DesignSystem.Colors.success
        }
    }
}

// MARK: - Project Hub View (detail for one project)

private struct ProjectHubView: View {
    let project: MergedProject
    let dataStore: DataStore
    @Bindable var operatingLayer: OpenBurnBarOperatingLayer
    let daemonManager: OpenBurnBarDaemonManager
    let settingsManager: SettingsManager
    let chatController: ChatSessionController
    let onBack: () -> Void
    let onEditSetup: () -> Void
    let onLaunchReview: (BurnBarControllerReviewCadence) -> Void
    let onRegister: () -> Void
    @State private var projectMemorySnapshot: ProjectMemorySnapshot?
    @State private var projectMemoryError: String?
    @State private var isRefreshingProjectMemory = false
    @State private var selectedPage: ProjectMemoryPage?
    @State private var selectedVisual: ProjectMemoryVisual?
    @State private var showHeroSheet = false
    @State private var selectedCitations: CitationWrapper?

    private var daemonIsHealthy: Bool {
        if case .healthy = daemonManager.status { return true }
        return false
    }

    private var pendingQuestions: [OpenBurnBarControllerQuestion] {
        operatingLayer.snapshot.controllerRuntime.pendingQuestions.filter { $0.projectName == project.slug || $0.projectName == project.displayName }
    }

    private var missions: [OpenBurnBarControllerMissionRecord] {
        operatingLayer.snapshot.controllerRuntime.missions.filter { $0.projectName == project.slug || $0.projectName == project.displayName }
    }

    private var openFollowups: [OpenBurnBarControllerFollowup] {
        operatingLayer.snapshot.controllerRuntime.openFollowups.filter { $0.projectName == project.slug || $0.projectName == project.displayName }
    }

    private var projectUsages: [TokenUsage] {
        dataStore.usages.filter { $0.projectName == project.slug || $0.projectName == project.displayName }
    }

    var body: some View {
        let projectHubTopAnchorID = "projectHubTop-\(project.id)"
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
                    // Keep a small top inset so the hub doesn't feel glued to the title/route chrome.
                    Color.clear
                        .frame(height: DesignSystem.Spacing.sm)
                        .id(projectHubTopAnchorID)

                    // Back
                    Button(action: onBack) {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.backward")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Projects")
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                        }
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(DesignSystem.Colors.surfaceElevated.opacity(0.62)))
                        .overlay(Capsule().stroke(DesignSystem.Colors.borderSubtle.opacity(0.7), lineWidth: 1))
                    }
                    .buttonStyle(.plain)

                    // Header
                    headerSection

                    // Project Memory Wiki
                    projectMemorySection

                    // Pending Questions
                    if !pendingQuestions.isEmpty {
                        questionsSection
                    }

                    // Missions
                    if !missions.isEmpty {
                        missionsSection
                    }

                    // Open Followups
                    if !openFollowups.isEmpty {
                        followupsSection
                    }

                    // Review History
                    if project.isRegistered {
                        reviewHistorySection
                    }

                    // Usage
                    if project.sessionCount > 0 {
                        usageSection
                    }

                    // Schedule (registered only)
                    if let p = project.registeredProject {
                        scheduleSection(p)
                    }

                    // Register CTA (unregistered only)
                    if !project.isRegistered {
                        GlassCard {
                            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                                sectionHeader("Register This Project")
                                Text("Register to enable scheduled reviews, mission tracking, and question workflows.")
                                    .font(DesignSystem.Typography.caption)
                                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                                Button(action: onRegister) {
                                    HStack(spacing: DesignSystem.Spacing.xs) {
                                        Image(systemName: "plus.circle.fill")
                                            .font(.system(size: 12, weight: .medium))
                                        Text("Register Project")
                                            .font(DesignSystem.Typography.caption)
                                    }
                                    .foregroundStyle(DesignSystem.Colors.whimsy)
                                    .padding(.horizontal, DesignSystem.Spacing.lg)
                                    .padding(.vertical, DesignSystem.Spacing.sm)
                                    .background(
                                        RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                                            .fill(DesignSystem.Colors.whimsy.opacity(0.10))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                                            .stroke(DesignSystem.Colors.whimsy.opacity(0.3), lineWidth: 0.75)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(DesignSystem.Spacing.lg)
                        }
                    }

                    // Feedback
                    if let fb = operatingLayer.controllerFeedback {
                        Text(fb.message)
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(fb.tone.color)
                    }
                }
                .padding(DesignSystem.Spacing.xl)
            }
            .defaultScrollAnchor(.top)
            .task(id: project.id) {
                await scrollProjectHubToTop(using: proxy, anchorID: projectHubTopAnchorID)
                await loadProjectMemory(forceRefresh: false)
            }
            .sheet(item: $selectedPage) { page in
                ProjectMemoryPageDetailSheet(
                    page: page,
                    projectName: project.displayName,
                    chatController: chatController
                )
                .frame(minWidth: 720, minHeight: 540)
            }
            .sheet(item: $selectedVisual) { visual in
                ProjectMemoryVisualDetailSheet(visual: visual, chatController: chatController)
                    .frame(minWidth: 760, minHeight: 560)
            }
            .sheet(isPresented: $showHeroSheet) {
                if let snapshot = projectMemorySnapshot {
                    ProjectMemoryHeroDetailSheet(snapshot: snapshot, chatController: chatController)
                        .frame(minWidth: 760, minHeight: 580)
                }
            }
            .sheet(item: $selectedCitations) { wrapper in
                CitationInsightSheet(citations: wrapper.citations, chatController: chatController)
                    .frame(minWidth: 800, minHeight: 620)
            }
        }
    }

    @MainActor
    private func scrollProjectHubToTop(using proxy: ScrollViewProxy, anchorID: String) async {
        await Task.yield()
        proxy.scrollTo(anchorID, anchor: .top)
    }

    private func normalizedProjectMemoryKey(_ raw: String) -> String {
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9_-]+", with: "-", options: .regularExpression)
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return normalized
    }

    private var projectMemoryKeys: [String] {
        let normalized = [project.slug, project.displayName]
            .flatMap { value -> [String] in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return [] }
                let lower = trimmed.lowercased()
                let slug = normalizedProjectMemoryKey(trimmed)
                return slug.isEmpty || slug == lower ? [lower] : [lower, slug]
            }
        var seen = Set<String>()
        return normalized.filter { seen.insert($0).inserted }
    }

    @MainActor
    private func loadProjectMemory(forceRefresh: Bool) async {
        if isRefreshingProjectMemory { return }
        isRefreshingProjectMemory = true
        defer { isRefreshingProjectMemory = false }

        let syncContext = CloudSyncContext(
            dataStore: dataStore,
            accountManager: AccountManager.shared,
            settingsManager: settingsManager
        )
        let projectMemorySync = SessionLogSyncService(context: syncContext)

        if forceRefresh == false {
            for key in projectMemoryKeys {
                if let cached = try? dataStore.fetchProjectMemorySnapshot(projectSlug: key) {
                    projectMemorySnapshot = cached
                    break
                }
            }
        }

        if forceRefresh == false, projectMemorySnapshot == nil {
            for key in projectMemoryKeys {
                if let cloudSnapshot = try? await projectMemorySync.fetchCloudProjectMemorySnapshot(projectSlug: key) {
                    projectMemorySnapshot = cloudSnapshot
                    try? dataStore.upsertProjectMemorySnapshot(cloudSnapshot)
                    break
                }
            }
        }

        var conversations: [ConversationRecord] = []
        for key in projectMemoryKeys {
            if let rows = try? dataStore.fetchConversationsForTranscriptScan(
                provider: nil,
                projectName: key,
                dateRange: nil,
                conversationSources: nil,
                limit: 240
            ) {
                conversations.append(contentsOf: rows)
            }
        }
        if conversations.isEmpty {
            let fallback = (try? dataStore.fetchConversations(limit: 500)) ?? []
            let keys = Set(projectMemoryKeys)
            conversations = fallback.filter { keys.contains($0.projectName.lowercased()) }
        }

        let previousContentHash = projectMemorySnapshot?.contentHash
        var seen = Set<String>()
        let dedupedConversations = conversations.filter { seen.insert($0.id).inserted }
        let snapshot = ProjectMemoryService.assemble(
            projectSlug: project.slug,
            projectDisplayName: project.displayName,
            conversations: dedupedConversations,
            usages: projectUsages,
            referenceDate: Date()
        )
        projectMemorySnapshot = snapshot

        do {
            try dataStore.upsertProjectMemorySnapshot(snapshot)
            projectMemoryError = nil
        } catch {
            projectMemoryError = "Couldn't persist Project Memory locally: \(error.localizedDescription)"
        }

        guard forceRefresh || previousContentHash != snapshot.contentHash else { return }
        do {
            try await projectMemorySync.uploadProjectMemorySnapshot(snapshot)
        } catch {
            if projectMemoryError == nil {
                projectMemoryError = "Project Memory saved locally, but cloud backup failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        Text(project.displayName)
                            .font(DesignSystem.Typography.title)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)

                        if project.displayName != project.slug {
                            Text(project.slug)
                                .font(DesignSystem.Typography.monoSmall)
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                        }

                        if let p = project.registeredProject {
                            Text(p.summary)
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 6) {
                        if let cadence = project.cadenceLabel {
                            statusPill(title: cadence, color: DesignSystem.Colors.blaze)
                        }
                        if let mode = project.automationMode {
                            statusPill(title: mode == .scheduled ? "Scheduled" : (mode == .suggested ? "Suggested" : "Manual"),
                                  color: mode == .scheduled ? DesignSystem.Colors.success : (mode == .suggested ? DesignSystem.Colors.amber : DesignSystem.Colors.textMuted))
                        }
                        if !project.isRegistered {
                            statusPill(title: "Unregistered", color: DesignSystem.Colors.textMuted)
                        }
                    }
                }

                if project.isRegistered {
                    let reentryControls = project.reentryReviewControls(daemonIsHealthy: daemonIsHealthy)
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        Menu {
                            ForEach(reentryControls) { control in
                                Button(control.title) {
                                    onLaunchReview(control.cadence)
                                }
                                .disabled(!control.isEnabled)
                            }
                        } label: {
                            HStack(spacing: DesignSystem.Spacing.xs) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("Run Review")
                                    .font(DesignSystem.Typography.caption)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 8, weight: .semibold))
                            }
                            .foregroundStyle(DesignSystem.Colors.blaze)
                            .padding(.horizontal, DesignSystem.Spacing.md)
                            .padding(.vertical, DesignSystem.Spacing.sm)
                            .background(
                                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                                    .fill(DesignSystem.Colors.blaze.opacity(0.10))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                                    .stroke(DesignSystem.Colors.blaze.opacity(0.3), lineWidth: 0.75)
                            )
                        }
                        .disabled(reentryControls.allSatisfy { !$0.isEnabled })
                        .buttonStyle(.plain)

                        Button(action: onEditSetup) {
                            HStack(spacing: DesignSystem.Spacing.xs) {
                                Image(systemName: "gearshape")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("Edit Setup")
                                    .font(DesignSystem.Typography.caption)
                            }
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .padding(.horizontal, DesignSystem.Spacing.md)
                            .padding(.vertical, DesignSystem.Spacing.sm)
                            .background(
                                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                                    .fill(DesignSystem.Colors.surfaceElevated.opacity(0.6))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                                    .stroke(DesignSystem.Colors.border.opacity(0.3), lineWidth: 0.75)
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    if daemonIsHealthy == false {
                        Text("Daemon unavailable — review controls stay visible but are temporarily disabled.")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    }
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
    }

    // MARK: - Project Memory

    private var projectMemorySection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                HStack(alignment: .center) {
                    sectionHeader("Project Memory Wiki")
                    Spacer()
                    if isRefreshingProjectMemory {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button {
                        Task { await loadProjectMemory(forceRefresh: true) }
                    } label: {
                        HStack(spacing: DesignSystem.Spacing.xs) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10, weight: .semibold))
                            Text("Refresh")
                                .font(DesignSystem.Typography.caption)
                        }
                        .foregroundStyle(DesignSystem.Colors.hermesAureate)
                        .padding(.horizontal, DesignSystem.Spacing.md)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                                .fill(DesignSystem.Colors.hermesAureate.opacity(0.12))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                                .stroke(DesignSystem.Colors.hermesAureate.opacity(0.35), lineWidth: 0.75)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isRefreshingProjectMemory)
                }

                if let snapshot = projectMemorySnapshot {
                    ProjectMemoryHeroCard(snapshot: snapshot, onTap: { showHeroSheet = true })

                    ForEach(snapshot.pages.prefix(2)) { page in
                        ProjectMemoryPageCard(
                            page: page,
                            onTap: { selectedPage = page },
                            onCitationTap: { citations in selectedCitations = CitationWrapper(citations: citations) }
                        )
                    }

                    if snapshot.visuals.isEmpty == false {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: DesignSystem.Spacing.md) {
                                ForEach(snapshot.visuals) { visual in
                                    ProjectMemoryVisualCard(visual: visual, onTap: { selectedVisual = visual })
                                }
                            }
                            .padding(.vertical, DesignSystem.Spacing.xs)
                        }
                    }

                    HStack(spacing: DesignSystem.Spacing.sm) {
                        statusPill(title: snapshot.freshness.label, color: snapshot.freshness.color)
                        Text(snapshot.generatedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    }
                } else if isRefreshingProjectMemory {
                    Text("Building project memory from local transcript evidence…")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                } else {
                    Text("No Project Memory snapshot yet. Refresh to generate a cited, visual brief for this project.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let projectMemoryError {
                    Text(projectMemoryError)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
    }

    // MARK: - Questions

    private var questionsSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                HStack {
                    sectionHeader("Pending Questions")
                    Spacer()
                    statusPill(title: "\(pendingQuestions.count)", color: DesignSystem.Colors.amber)
                }
                ForEach(pendingQuestions) { question in
                    InlineQuestionRow(question: question, operatingLayer: operatingLayer)
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
    }

    // MARK: - Missions

    private var missionsSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                sectionHeader("Missions")
                ForEach(missions) { mission in
                    InlineMissionCard(mission: mission, operatingLayer: operatingLayer)
                    if mission.id != missions.last?.id {
                        Divider().background(DesignSystem.Colors.border)
                    }
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
    }

    // MARK: - Followups

    private var followupsSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                HStack {
                    sectionHeader("Open Followups")
                    Spacer()
                    statusPill(title: "\(openFollowups.count)", color: DesignSystem.Colors.blaze)
                }
                ForEach(openFollowups) { followup in
                    InlineFollowupRow(followup: followup, operatingLayer: operatingLayer)
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
    }

    // MARK: - Review History

    private var reviewHistorySection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                sectionHeader("Review History")
                let indicators = project.reviewHistoryIndicators
                if indicators.isEmpty {
                    Text("No reviews have run yet for this project.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                } else {
                    ForEach(indicators) { indicator in
                        factRow(
                            icon: "calendar",
                            title: indicator.cadence == .weekly ? "Last weekly" : "Last daily",
                            value: indicator.reviewedAt.formatted(date: .abbreviated, time: .shortened)
                        )
                    }
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
    }

    // MARK: - Usage

    private var usageSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                sectionHeader("Usage")
                HStack(spacing: DesignSystem.Spacing.lg) {
                    metricChip(title: "Cost", value: project.totalCost.formatAsCost(), color: DesignSystem.Colors.hermesAureate)
                    metricChip(title: "Tokens", value: project.totalTokens.formatAsTokenVolume(), color: DesignSystem.Colors.textPrimary)
                    metricChip(title: "Sessions", value: "\(project.sessionCount)", color: DesignSystem.Colors.blaze)
                }
                if !project.providers.isEmpty {
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        ForEach(project.providers, id: \.self) { provider in
                            HStack(spacing: DesignSystem.Spacing.xs) {
                                ProviderLogoView(provider: provider, size: 14, useFallbackColor: false)
                                Text(provider.displayName)
                                    .font(DesignSystem.Typography.tiny)
                                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                            }
                        }
                    }
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
    }

    // MARK: - Schedule

    private func scheduleSection(_ p: BurnBarReviewProjectSnapshot) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                sectionHeader("Schedule")
                factRow(icon: "repeat", title: "Cadence", value: project.cadenceLabel ?? "—")
                factRow(icon: "gearshape.2", title: "Automation", value: p.automationMode == .scheduled ? "Scheduled" : (p.automationMode == .suggested ? "Suggested" : "Manual"))
                if let hour = p.scheduleHourLocal {
                    let hourStr = formattedHour(hour)
                    if p.preferredCadence == .weekly, let weekday = p.scheduleWeekdayLocal {
                        factRow(icon: "clock", title: "Schedule", value: "\(weekdayLabel(weekday)) at \(hourStr)")
                    } else {
                        factRow(icon: "clock", title: "Schedule", value: "Daily at \(hourStr)")
                    }
                }
                if let next = p.nextScheduledReviewAt {
                    factRow(icon: "arrow.right.circle", title: "Next review", value: next.formatted(date: .abbreviated, time: .shortened))
                }
                if let model = p.reviewModelID?.nonEmpty {
                    factRow(icon: "cpu", title: "Model", value: model)
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
    }

    private func formattedHour(_ hour: Int) -> String {
        let safeHour = min(max(hour, 0), 23)
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        let date = Calendar.current.date(from: DateComponents(hour: safeHour, minute: 0)) ?? Date()
        return formatter.string(from: date)
    }

    private func weekdayLabel(_ weekday: Int) -> String {
        let safeWeekday = min(max(weekday, 1), 7)
        return Calendar.current.weekdaySymbols[safeWeekday - 1]
    }
}

// MARK: - Inline Question Row

private struct InlineQuestionRow: View {
    let question: OpenBurnBarControllerQuestion
    @Bindable var operatingLayer: OpenBurnBarOperatingLayer
    @State private var answerText = ""
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Button {
                withAnimation(DesignSystem.Animation.standard) { expanded.toggle() }
            } label: {
                HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                    Circle()
                        .fill(DesignSystem.Colors.amber)
                        .frame(width: 6, height: 6)
                        .padding(.top, 5)
                    VStack(alignment: .leading, spacing: 2) {
                        if let stage = question.stageLabel?.nonEmpty {
                            Text(stage)
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.amber)
                        }
                        Text(question.title)
                            .font(DesignSystem.Typography.body)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                            .lineLimit(expanded ? nil : 2)
                    }
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                if let prompt = question.prompt.nonEmpty {
                    Text(prompt)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, DesignSystem.Spacing.lg)
                }

                if !question.suggestedOptions.isEmpty {
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        ForEach(question.suggestedOptions, id: \.id) { option in
                            Button {
                                Task {
                                    await operatingLayer.answerPendingQuestion(
                                        id: question.id,
                                        answer: option.answer.isEmpty ? option.title : option.answer,
                                        selectedOptionID: option.id
                                    )
                                }
                            } label: {
                                Text(option.title)
                                    .font(DesignSystem.Typography.caption)
                                    .foregroundStyle(DesignSystem.Colors.whimsy)
                                    .padding(.horizontal, DesignSystem.Spacing.md)
                                    .padding(.vertical, 6)
                                    .background(
                                        RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                                            .fill(DesignSystem.Colors.whimsy.opacity(0.10))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                                            .stroke(DesignSystem.Colors.whimsy.opacity(0.3), lineWidth: 0.75)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.leading, DesignSystem.Spacing.lg)
                }

                HStack(spacing: DesignSystem.Spacing.sm) {
                    TextField("Type an answer...", text: $answerText)
                        .textFieldStyle(.plain)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .padding(.horizontal, DesignSystem.Spacing.md)
                        .padding(.vertical, DesignSystem.Spacing.sm)
                        .background(
                            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.6))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                                .stroke(DesignSystem.Colors.border.opacity(0.4), lineWidth: 0.75)
                        )
                        .onSubmit { sendAnswer() }

                    Button(action: sendAnswer) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(answerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? DesignSystem.Colors.textMuted : DesignSystem.Colors.whimsy)
                    }
                    .buttonStyle(.plain)
                    .disabled(answerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.leading, DesignSystem.Spacing.lg)
            }
        }
        .padding(DesignSystem.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                .fill(DesignSystem.Colors.surfaceElevated.opacity(expanded ? 0.4 : 0))
        )
    }

    private func sendAnswer() {
        let trimmed = answerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            await operatingLayer.answerPendingQuestion(id: question.id, answer: trimmed)
            answerText = ""
        }
    }
}

// MARK: - Inline Mission Card

private struct InlineMissionCard: View {
    let mission: OpenBurnBarControllerMissionRecord
    @Bindable var operatingLayer: OpenBurnBarOperatingLayer
    @State private var approvalNote = ""

    private var canApprove: Bool {
        mission.approval == .pending && operatingLayer.snapshot.mission.missionID == mission.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(mission.title)
                        .font(DesignSystem.Typography.headline)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text(mission.packetSummary?.nonEmpty ?? mission.summary)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    statusPill(title: mission.state.label, color: mission.state.color)
                    statusPill(title: mission.approval.label, color: mission.approval.color)
                    if let ts = mission.latestTakeoverState {
                        statusPill(title: ts.label, color: ts.color)
                    }
                }
            }

            HStack(spacing: DesignSystem.Spacing.sm) {
                metricChip(title: "Burn", value: mission.burnCostUSD.formatAsCost(), color: DesignSystem.Colors.hermesAureate)
                if mission.packetRunCount > 0 {
                    metricChip(title: "Runs", value: "\(mission.packetRunCount)", color: DesignSystem.Colors.blaze)
                }
                if mission.takeoverCount > 0 {
                    metricChip(title: "Takeovers", value: "\(mission.takeoverCount)", color: mission.latestTakeoverState?.color ?? DesignSystem.Colors.blaze)
                }
            }

            if let runID = mission.activeRunID?.nonEmpty {
                factRow(icon: "point.3.filled.connected.trianglepath.dotted", title: "Run", value: runID)
            }
            if let result = mission.latestResultSummary?.nonEmpty {
                factRow(icon: "checklist.checked", title: "Latest result", value: result)
            }
            if let reason = mission.latestTakeoverReason?.nonEmpty {
                factRow(icon: "arrow.triangle.branch", title: "Takeover", value: reason, accent: mission.latestTakeoverState?.color)
            }

            if canApprove {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    TextField("Optional note...", text: $approvalNote)
                        .textFieldStyle(.plain)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .padding(.horizontal, DesignSystem.Spacing.md)
                        .padding(.vertical, DesignSystem.Spacing.sm)
                        .background(
                            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.6))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                                .stroke(DesignSystem.Colors.border.opacity(0.4), lineWidth: 0.75)
                        )

                    Button {
                        withAnimation(DesignSystem.Animation.standard) {
                            operatingLayer.approveMission(note: approvalNote)
                            approvalNote = ""
                        }
                    } label: {
                        HStack(spacing: DesignSystem.Spacing.xs) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 12, weight: .medium))
                            Text("Approve")
                                .font(DesignSystem.Typography.caption)
                        }
                        .foregroundStyle(DesignSystem.Colors.hermesAureate)
                        .padding(.horizontal, DesignSystem.Spacing.lg)
                        .padding(.vertical, DesignSystem.Spacing.sm)
                        .background(
                            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                                .fill(DesignSystem.Colors.hermesAureate.opacity(0.12))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                                .stroke(DesignSystem.Colors.hermesAureate.opacity(0.35), lineWidth: 0.75)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Inline Followup Row

private struct InlineFollowupRow: View {
    let followup: OpenBurnBarControllerFollowup
    @Bindable var operatingLayer: OpenBurnBarOperatingLayer

    var body: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(followup.title)
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(followup.summary)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineLimit(2)
                if let snoozed = followup.snoozedUntil {
                    Text("Snoozed until \(snoozed.formatted(date: .abbreviated, time: .shortened))")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            }
            Spacer()
            Button {
                Task { await operatingLayer.completeFollowup(id: followup.id) }
            } label: {
                Text("Complete")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.success)
                    .padding(.horizontal, DesignSystem.Spacing.md)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                            .fill(DesignSystem.Colors.success.opacity(0.10))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                            .stroke(DesignSystem.Colors.success.opacity(0.3), lineWidth: 0.75)
                    )
            }
            .buttonStyle(.plain)
        }
    }
}

private extension ProjectMemoryFreshness {
    var color: Color {
        switch self {
        case .fresh:
            return DesignSystem.Colors.success
        case .needsRefresh:
            return DesignSystem.Colors.hermesAureate
        case .evidenceThin:
            return DesignSystem.Colors.amber
        case .stale:
            return DesignSystem.Colors.warning
        }
    }
}

private struct ProjectMemoryHeroCard: View {
    let snapshot: ProjectMemorySnapshot
    var onTap: (() -> Void)? = nil
    @State private var isHovered = false

    private var coverVisual: ProjectMemoryVisual? {
        snapshot.visuals.first { $0.kind == .cover }
    }

    var body: some View {
        Button(action: { onTap?() }) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                DesignSystem.Colors.hermesMercury.opacity(0.22),
                                DesignSystem.Colors.hermesAureate.opacity(0.22),
                                DesignSystem.Colors.surfaceElevated.opacity(0.7),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                            .stroke(DesignSystem.Colors.mercuryGradient, lineWidth: 1)
                    )

                Circle()
                    .fill(DesignSystem.Colors.hermesAureate.opacity(0.18))
                    .frame(width: 120, height: 120)
                    .offset(x: 180, y: -30)
                    .blur(radius: 1.2)

                Circle()
                    .fill(DesignSystem.Colors.whimsy.opacity(0.12))
                    .frame(width: 80, height: 80)
                    .offset(x: 235, y: 42)
                    .blur(radius: 1)

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    Text(snapshot.projectDisplayName)
                        .font(DesignSystem.Typography.headline)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text(snapshot.usageSummary)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let coverVisual {
                        HStack(spacing: DesignSystem.Spacing.md) {
                            ForEach(Array(coverVisual.points.prefix(3).enumerated()), id: \.offset) { _, point in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(point.label.uppercased())
                                        .font(DesignSystem.Typography.tiny)
                                        .foregroundStyle(DesignSystem.Colors.textMuted)
                                    Text(metric(point))
                                        .font(DesignSystem.Typography.monoSmall)
                                        .foregroundStyle(DesignSystem.Colors.hermesAureate)
                                }
                            }
                        }
                    }
                }
                .padding(DesignSystem.Spacing.lg)
            }
            .clipShape(.rect(cornerRadius: DesignSystem.Radius.lg))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.015 : 1.0)
        .animation(DesignSystem.Animation.hover, value: isHovered)
        .onHover { isHovered = $0 }
    }

    private func metric(_ point: ProjectMemoryVisualPoint) -> String {
        if point.label.lowercased().contains("spend") {
            return point.value.formatAsCost()
        }
        if point.label.lowercased().contains("token") {
            return Int(point.value).formatAsTokenVolume()
        }
        return String(Int(point.value))
    }
}

private struct ProjectMemoryPageCard: View {
    let page: ProjectMemoryPage
    var onTap: (() -> Void)? = nil
    var onCitationTap: (([ProjectMemoryCitation]) -> Void)? = nil
    @State private var isHovered = false

    var body: some View {
        Button(action: { onTap?() }) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text(page.title)
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(page.summary)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(page.sections.prefix(2)) { section in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(section.title)
                            .font(DesignSystem.Typography.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                        Text(section.body)
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .lineLimit(3)
                        if section.citations.isEmpty == false {
                            Button {
                                onCitationTap?(section.citations)
                            } label: {
                                Text("\(section.citations.count) citation\(section.citations.count == 1 ? "" : "s")")
                                    .font(DesignSystem.Typography.tiny)
                                    .foregroundStyle(DesignSystem.Colors.hermesAureate)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(DesignSystem.Spacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                            .fill(DesignSystem.Colors.surfaceElevated.opacity(0.55))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                            .stroke(DesignSystem.Colors.border.opacity(0.25), lineWidth: 0.75)
                    )
                }
            }
            .padding(DesignSystem.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(DesignSystem.Colors.surface.opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .stroke(DesignSystem.Colors.border.opacity(0.3), lineWidth: 0.75)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.015 : 1.0)
        .animation(DesignSystem.Animation.hover, value: isHovered)
        .onHover { isHovered = $0 }
    }
}

private struct ProjectMemoryVisualCard: View {
    let visual: ProjectMemoryVisual
    var onTap: (() -> Void)? = nil
    @State private var isHovered = false

    private var maxValue: Double {
        max(visual.points.map(\.value).max() ?? 1, 1)
    }

    var body: some View {
        Button(action: { onTap?() }) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text(visual.title)
                    .font(DesignSystem.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                if let subtitle = visual.subtitle {
                    Text(subtitle)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }

                ForEach(Array(visual.points.prefix(5).enumerated()), id: \.offset) { _, point in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(point.label)
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                                .lineLimit(1)
                            Spacer()
                            Text(pointValueLabel(point))
                                .font(DesignSystem.Typography.monoTiny)
                                .foregroundStyle(DesignSystem.Colors.hermesAureate)
                        }
                        Capsule()
                            .fill(DesignSystem.Colors.hermesAureate.opacity(0.8))
                            .frame(width: CGFloat(max(0.12, point.value / maxValue)) * 140, height: 4)
                    }
                }
            }
            .padding(DesignSystem.Spacing.md)
            .frame(width: 220, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(DesignSystem.Colors.surfaceElevated.opacity(0.65))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .stroke(DesignSystem.Colors.mercuryGradient, lineWidth: 0.75)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.015 : 1.0)
        .animation(DesignSystem.Animation.hover, value: isHovered)
        .onHover { isHovered = $0 }
    }

    private func pointValueLabel(_ point: ProjectMemoryVisualPoint) -> String {
        if let subtitle = point.subtitle, subtitle.isEmpty == false {
            return subtitle
        }
        if visual.kind == .providerMix {
            return point.value.formatAsCost()
        }
        if visual.kind == .timeline {
            return Int(point.value).formatAsTokenVolume()
        }
        return String(Int(point.value))
    }
}

// MARK: - Shared Helpers

private func statusPill(title: String, color: Color) -> some View {
    Text(title)
        .font(DesignSystem.Typography.tiny)
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
}

private func sectionHeader(_ title: String) -> some View {
    Text(title)
        .font(DesignSystem.Typography.caption)
        .fontWeight(.semibold)
        .foregroundStyle(DesignSystem.Colors.textSecondary)
        .textCase(.uppercase)
}

private func factRow(icon: String, title: String, value: String, accent: Color? = nil) -> some View {
    HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
        Image(systemName: icon)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(accent ?? DesignSystem.Colors.textSecondary)
            .frame(width: 16, alignment: .center)
        Text(title)
            .font(DesignSystem.Typography.tiny)
            .foregroundStyle(DesignSystem.Colors.textMuted)
            .frame(width: 80, alignment: .leading)
        Text(value)
            .font(DesignSystem.Typography.caption)
            .foregroundStyle(accent ?? DesignSystem.Colors.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private func metricChip(title: String, value: String, color: Color) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        Text(title)
            .font(DesignSystem.Typography.tiny)
            .foregroundStyle(DesignSystem.Colors.textMuted)
        Text(value)
            .font(DesignSystem.Typography.monoSmall)
            .foregroundStyle(color)
    }
    .padding(.horizontal, DesignSystem.Spacing.sm)
    .padding(.vertical, 6)
    .background(
        RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
            .fill(DesignSystem.Colors.surfaceElevated.opacity(0.7))
    )
    .overlay(
        RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
            .stroke(DesignSystem.Colors.border.opacity(0.3), lineWidth: 0.5)
    )
}

// MARK: - Editor Sheet (preserved from original)

private struct ControllerProjectDraft: Identifiable {
    let id: String
    let existingProjectID: String?
    var projectSlug: String
    var displayName: String
    var summary: String
    var aliasesText: String
    var preferredCadence: BurnBarControllerReviewCadence
    var automationMode: BurnBarControllerProjectAutomationMode
    var scheduleHourLocal: Int
    var scheduleWeekdayLocal: Int
    var reviewModelID: String
    var isPaused: Bool
    var existingMetadata: BurnBarMetadata
    var existingLatestDailyReviewAt: Date?
    var existingLatestWeeklyReviewAt: Date?
    var existingNextScheduledReviewAt: Date?
    var existingActiveMissionID: BurnBarMissionID?
    var existingPendingQuestionCount: Int
    var existingOpenFollowupCount: Int
    var existingActiveMissionCount: Int

    init(project: BurnBarReviewProjectSnapshot? = nil) {
        self.id = project?.id ?? UUID().uuidString
        self.existingProjectID = project?.id
        self.projectSlug = project?.projectSlug ?? ""
        self.displayName = project?.displayName ?? ""
        self.summary = project?.summary ?? ""
        self.aliasesText = project?.aliases.joined(separator: ", ") ?? ""
        self.preferredCadence = project?.preferredCadence ?? .weekly
        self.automationMode = project?.automationMode ?? .manual
        self.scheduleHourLocal = project?.scheduleHourLocal ?? 9
        self.scheduleWeekdayLocal = project?.scheduleWeekdayLocal ?? 2
        self.reviewModelID = project?.reviewModelID ?? "glm-5"
        self.isPaused = project?.status == .paused
        self.existingMetadata = project?.metadata ?? [:]
        self.existingLatestDailyReviewAt = project?.latestDailyReviewAt
        self.existingLatestWeeklyReviewAt = project?.latestWeeklyReviewAt
        self.existingNextScheduledReviewAt = project?.nextScheduledReviewAt
        self.existingActiveMissionID = project?.activeMissionID
        self.existingPendingQuestionCount = project?.pendingQuestionCount ?? 0
        self.existingOpenFollowupCount = project?.openFollowupCount ?? 0
        self.existingActiveMissionCount = project?.activeMissionCount ?? 0
    }

    var aliases: [String] {
        aliasesText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    func snapshot() -> BurnBarReviewProjectSnapshot {
        let normalizedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSlug = projectSlug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? normalizedDisplayName.lowercased().replacingOccurrences(of: " ", with: "-")
            : projectSlug.trimmingCharacters(in: .whitespacesAndNewlines)
        return BurnBarReviewProjectSnapshot(
            id: existingProjectID ?? "project-\(normalizedSlug)",
            projectSlug: normalizedSlug,
            displayName: normalizedDisplayName.isEmpty ? normalizedSlug : normalizedDisplayName,
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Native OpenBurnBar controller registry project." : summary.trimmingCharacters(in: .whitespacesAndNewlines),
            status: isPaused ? .paused : .healthy,
            preferredCadence: preferredCadence,
            aliases: aliases,
            automationMode: automationMode,
            reviewModelID: reviewModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : reviewModelID.trimmingCharacters(in: .whitespacesAndNewlines),
            scheduleHourLocal: scheduleHourLocal,
            scheduleWeekdayLocal: scheduleWeekdayLocal,
            freshness: .provisional,
            latestDailyReviewAt: existingLatestDailyReviewAt,
            latestWeeklyReviewAt: existingLatestWeeklyReviewAt,
            nextScheduledReviewAt: existingNextScheduledReviewAt,
            pendingQuestionCount: existingPendingQuestionCount,
            openFollowupCount: existingOpenFollowupCount,
            activeMissionCount: existingActiveMissionCount,
            activeMissionID: existingActiveMissionID,
            needsOperatorAttention: existingPendingQuestionCount > 0 || existingOpenFollowupCount > 0 || existingActiveMissionCount > 0,
            ingestionSource: .manual,
            metadata: existingMetadata
        )
    }
}

private struct ControllerProjectEditorSheet: View {
    @State var draft: ControllerProjectDraft
    let onCancel: () -> Void
    let onSave: (ControllerProjectDraft) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            Text(draft.existingProjectID == nil ? "Add Review Project" : "Edit Review Project")
                .font(DesignSystem.Typography.title)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
            Text("This saves OpenBurnBar's default review style and optional automatic schedule for a project.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Display name", text: $draft.displayName).textFieldStyle(.roundedBorder)
            TextField("Project slug", text: $draft.projectSlug).textFieldStyle(.roundedBorder)
            TextField("Summary", text: $draft.summary, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(3, reservesSpace: true)
            TextField("Aliases (comma separated)", text: $draft.aliasesText).textFieldStyle(.roundedBorder)
            TextField("Review model ID", text: $draft.reviewModelID).textFieldStyle(.roundedBorder)
            HStack {
                Picker("Cadence", selection: $draft.preferredCadence) {
                    Text("Daily").tag(BurnBarControllerReviewCadence.daily)
                    Text("Weekly").tag(BurnBarControllerReviewCadence.weekly)
                    Text("Ad hoc").tag(BurnBarControllerReviewCadence.adHoc)
                }
                Picker("Automation", selection: $draft.automationMode) {
                    Text("Manual").tag(BurnBarControllerProjectAutomationMode.manual)
                    Text("Suggested").tag(BurnBarControllerProjectAutomationMode.suggested)
                    Text("Scheduled").tag(BurnBarControllerProjectAutomationMode.scheduled)
                }
            }
            HStack {
                Picker("Hour", selection: $draft.scheduleHourLocal) {
                    ForEach(0..<24, id: \.self) { hour in Text(String(format: "%02d:00", hour)).tag(hour) }
                }
                Picker("Weekday", selection: $draft.scheduleWeekdayLocal) {
                    Text("Sunday").tag(1); Text("Monday").tag(2); Text("Tuesday").tag(3)
                    Text("Wednesday").tag(4); Text("Thursday").tag(5); Text("Friday").tag(6); Text("Saturday").tag(7)
                }
            }
            Toggle("Pause this project", isOn: $draft.isPaused)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") { onSave(draft) }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.projectSlug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(DesignSystem.Spacing.xl)
        .frame(minWidth: 520)
        .background(DesignSystem.Colors.background)
    }
}


// MARK: - Editorial Subviews (shared by all Project Memory detail sheets)

/// Identifiable bridge so multiple citations OR a single citation can drive
/// `.sheet(item:)`. Each invocation gets a fresh `id` so re-tapping the
/// same chip presents a new sheet (intentional — the sheet's own controller
/// re-runs Hermes on every present).
private struct CitationWrapper: Identifiable {
    let id: UUID
    let citations: [ProjectMemoryCitation]

    init(citations: [ProjectMemoryCitation]) {
        self.id = UUID()
        self.citations = citations
    }

    static func single(_ citation: ProjectMemoryCitation) -> CitationWrapper {
        CitationWrapper(citations: [citation])
    }
}

@MainActor
@Observable
final class ProjectMemoryInsightController {
    enum State: Equatable {
        case idle
        case streaming
        case complete
        case failed(String)
    }

    private(set) var streamingContent: String = ""
    private(set) var state: State = .idle

    private let chat: ChatSessionController
    private var trackedAssistantID: String?
    private var trackedAfterMessageCount: Int = 0
    private var streamTask: Task<Void, Never>?

    init(chatController: ChatSessionController) {
        self.chat = chatController
    }

    func generate(prompt: String) {
        cancel()
        streamingContent = ""
        state = .streaming
        trackedAfterMessageCount = chat.messages.count
        chat.inputText = prompt
        streamTask = Task { @MainActor in
            await chat.send()
        }
    }

    func observeStreamingTick(messages: [ChatMessageRecord], activeID: String?, isStreaming: Bool) {
        guard state == .streaming else { return }

        if trackedAssistantID == nil, let id = activeID {
            trackedAssistantID = id
        }

        let candidateID = trackedAssistantID ?? activeID
        let candidate: ChatMessageRecord? = {
            if let id = candidateID, let m = messages.first(where: { $0.id == id }) {
                return m
            }
            return messages.dropFirst(trackedAfterMessageCount).first(where: { $0.role == .assistant })
        }()

        if let msg = candidate {
            streamingContent = msg.content
        }

        if !isStreaming, activeID == nil {
            let trimmed = streamingContent.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                state = .failed("Hermes returned no content. Open the chat panel to retry.")
            } else {
                state = .complete
            }
        }
    }

    func cancel() {
        streamTask?.cancel()
        streamTask = nil
        trackedAssistantID = nil
    }
}

private struct EditorialHero: View {
    let eyebrow: String
    let subtitle: String?
    let headline: String
    let metaSegments: [String]
    let leadAccent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "scroll.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(leadAccent)
                Text(eyebrow.uppercased())
                    .font(DesignSystem.Typography.caption)
                    .tracking(2.0)
                    .foregroundStyle(leadAccent)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
            }
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(headline)
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if !metaSegments.isEmpty {
                Text(metaSegments.joined(separator: "  ·  "))
                    .font(DesignSystem.Typography.monoSmall)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
            }
            MercuryHairline()
                .padding(.top, DesignSystem.Spacing.xs)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MercuryHairline: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(DesignSystem.Colors.mercuryGradient)
                    .frame(height: 0.5)
                if !reduceMotion {
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    DesignSystem.Colors.hermesMercury.opacity(0.0),
                                    DesignSystem.Colors.hermesAureate.opacity(0.55),
                                    DesignSystem.Colors.hermesMercury.opacity(0.0)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(40, w * 0.18), height: 0.5)
                        .offset(x: phase * w)
                        .blendMode(.plusLighter)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: w, height: 0.5, alignment: .leading)
            .clipped()
        }
        .frame(height: 0.5)
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 3.0)) { phase = 1 }
        }
    }
}

private struct HermesReadingCard: View {
    let title: String
    let placeholder: String
    let controller: ProjectMemoryInsightController
    var onRetry: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            header
            content
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(DesignSystem.Colors.surface.opacity(0.68))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .stroke(DesignSystem.Colors.mercuryGradient, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Hermes reading")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        switch controller.state {
        case .idle: return placeholder
        case .streaming where controller.streamingContent.isEmpty: return "Hermes is reading the evidence."
        case .streaming: return controller.streamingContent
        case .complete: return controller.streamingContent
        case .failed(let err): return "Failed. " + err
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: headerIcon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.hermesAureate)
            Text(title.uppercased())
                .font(DesignSystem.Typography.caption)
                .tracking(2.0)
                .foregroundStyle(DesignSystem.Colors.hermesAureate)
            Spacer(minLength: 0)
            trailingControl
        }
    }

    @ViewBuilder
    private var trailingControl: some View {
        switch controller.state {
        case .streaming:
            MercuryPoolDots()
        case .failed:
            if let onRetry {
                Button("Retry", action: onRetry)
                    .buttonStyle(.borderless)
                    .font(DesignSystem.Typography.monoTiny)
                    .foregroundStyle(DesignSystem.Colors.hermesAureate)
            } else {
                EmptyView()
            }
        case .idle, .complete:
            EmptyView()
        }
    }

    private var headerIcon: String {
        switch controller.state {
        case .failed: return "exclamationmark.triangle.fill"
        default:      return "sparkles"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch controller.state {
        case .idle:
            Text(placeholder)
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        case .streaming where controller.streamingContent.isEmpty:
            Text(placeholder)
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        case .streaming:
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(controller.streamingContent)
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: controller.streamingContent)
                MercuryCaret()
            }
        case .complete:
            Text(controller.streamingContent)
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let err):
            VStack(alignment: .leading, spacing: 6) {
                Text(err)
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.error)
                    .fixedSize(horizontal: false, vertical: true)
                Text("If Hermes isn't running, the indexed evidence below is still authoritative.")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
        }
    }
}

private struct MercuryPoolDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var t: Double = 0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(DesignSystem.Colors.mercuryGradient)
                    .frame(width: 6, height: 6)
                    .scaleEffect(scale(at: i))
                    .opacity(opacity(at: i))
            }
        }
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                t = 1
            }
        }
    }

    private func scale(at i: Int) -> CGFloat {
        let start: [CGFloat] = [1.0, 0.8, 1.0]
        let target: [CGFloat] = [1.4, 1.0, 0.8]
        return start[i] + (target[i] - start[i]) * CGFloat(t)
    }

    private func opacity(at i: Int) -> Double {
        let start: [Double] = [0.55, 1.0, 0.6]
        let target: [Double] = [1.0, 0.55, 1.0]
        return start[i] + (target[i] - start[i]) * t
    }
}

private struct MercuryCaret: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = true

    var body: some View {
        Rectangle()
            .fill(DesignSystem.Colors.hermesAureate)
            .frame(width: 6, height: 14)
            .opacity(visible ? 1 : 0.2)
            .accessibilityHidden(true)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                    visible.toggle()
                }
            }
    }
}

private struct NumberedSectionRow: View {
    let index: Int
    let total: Int
    let title: String
    let text: String
    let accent: Color
    let citations: [ProjectMemoryCitation]
    let onCitationTap: (ProjectMemoryCitation) -> Void
    let onCombinedCitationTap: (() -> Void)?

    private var trimmedBody: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSentinelBody: Bool {
        let lowered = trimmedBody.lowercased()
        let sentinels = [
            "no indexed conversations are available yet",
            "no explicit decision summaries were found yet",
            "no key-file evidence found yet",
            "no reusable commands captured yet",
            "no unresolved risk language captured yet"
        ]
        return sentinels.contains(where: { lowered.hasPrefix($0) }) || trimmedBody.count < 12
    }

    var body: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            Rectangle()
                .fill(accent)
                .frame(width: 3)
                .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.sm) {
                    Text(String(format: "%02d", index))
                        .font(.system(.title3, design: .monospaced).weight(.semibold))
                        .foregroundStyle(accent)
                    Text(title)
                        .font(DesignSystem.Typography.headline)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Spacer(minLength: 0)
                    Text("\(index) / \(total)")
                        .font(DesignSystem.Typography.monoTiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
                if isSentinelBody {
                    EmptyEvidenceCallout(message: trimmedBody)
                } else {
                    Text(trimmedBody)
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !citations.isEmpty {
                    citationStrip
                }
            }
            .padding(.vertical, DesignSystem.Spacing.sm)
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(DesignSystem.Colors.surface.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .stroke(DesignSystem.Colors.border.opacity(0.3), lineWidth: 0.75)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(index) of \(total). \(title)")
        .accessibilityValue(isSentinelBody ? "Insufficient evidence" : trimmedBody)
    }

    @ViewBuilder
    private var citationStrip: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            HStack(spacing: 6) {
                Text("FOOTNOTES")
                    .font(DesignSystem.Typography.monoTiny)
                    .tracking(1.4)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                if let onCombinedCitationTap {
                    Button {
                        onCombinedCitationTap()
                    } label: {
                        Text("Read all \(citations.count) →")
                            .font(DesignSystem.Typography.monoTiny)
                            .foregroundStyle(DesignSystem.Colors.hermesAureate)
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            HFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                ForEach(Array(citations.prefix(8).enumerated()), id: \.element.id) { idx, citation in
                    FootnoteCitationChip(
                        ordinal: idx + 1,
                        citation: citation,
                        onTap: { onCitationTap(citation) }
                    )
                }
            }
        }
    }
}

private struct FootnoteCitationChip: View {
    let ordinal: Int
    let citation: ProjectMemoryCitation
    let onTap: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Text(String(format: "[%02d]", ordinal))
                    .font(DesignSystem.Typography.monoTiny)
                    .foregroundStyle(DesignSystem.Colors.hermesAureate)
                Text(citation.title.isEmpty ? citation.sourceKind.rawValue : citation.title)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, DesignSystem.Spacing.sm)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(DesignSystem.Colors.surfaceElevated.opacity(hovered ? 0.95 : 0.55))
            )
            .overlay(
                Capsule()
                    .stroke(
                        hovered ? DesignSystem.Colors.hermesAureate.opacity(0.5) : DesignSystem.Colors.borderSubtle,
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .scaleEffect(hovered ? 1.02 : 1.0)
        .animation(DesignSystem.Animation.hover, value: hovered)
        .onHover { hovered = $0 }
        .accessibilityLabel("Footnote \(ordinal): \(citation.title)")
        .accessibilityHint("Opens Hermes analysis of this citation")
    }
}

private struct EmptyEvidenceCallout: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            HStack(spacing: 6) {
                Image(systemName: "tray")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.warning)
                Text("INSUFFICIENT EVIDENCE")
                    .font(DesignSystem.Typography.monoTiny)
                    .tracking(1.6)
                    .foregroundStyle(DesignSystem.Colors.warning)
            }
            Text(message.isEmpty ? "This section needs more indexed conversations before it can synthesize a meaningful answer." : message)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Text("Run Refresh Memory on the project to regenerate this section.")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .italic()
        }
        .padding(DesignSystem.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                .fill(DesignSystem.Colors.warning.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                .stroke(DesignSystem.Colors.warning.opacity(0.25), lineWidth: 0.5)
        )
    }
}

private struct CitationQuoteCard: View {
    let ordinal: Int
    let citation: ProjectMemoryCitation

    var body: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            Text(String(format: "%02d", ordinal))
                .font(.system(.title3, design: .monospaced).weight(.semibold))
                .foregroundStyle(DesignSystem.Colors.hermesAureate)
                .frame(width: 32, alignment: .leading)
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                HStack {
                    Text(citation.title.isEmpty ? "Untitled" : citation.title)
                        .font(DesignSystem.Typography.headline)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    sourceChip
                }
                Text(citation.snippet.isEmpty ? "(no snippet captured)" : citation.snippet)
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                if let createdAt = citation.createdAt {
                    Text(createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(DesignSystem.Typography.monoTiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(DesignSystem.Colors.surface.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .stroke(DesignSystem.Colors.border.opacity(0.3), lineWidth: 0.75)
        )
        .accessibilityElement(children: .combine)
    }

    private var sourceChip: some View {
        Text(sourceLabel)
            .font(DesignSystem.Typography.monoTiny)
            .tracking(0.8)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(DesignSystem.Colors.hermesAureate.opacity(0.12))
            )
            .overlay(
                Capsule().stroke(DesignSystem.Colors.hermesAureate.opacity(0.35), lineWidth: 0.5)
            )
            .foregroundStyle(DesignSystem.Colors.hermesAureate)
    }

    private var sourceLabel: String {
        switch citation.sourceKind {
        case .conversation:    return "TRANSCRIPT"
        case .skillDoc:        return "SKILL DOC"
        case .agentDoc:        return "AGENT DOC"
        case .sharedArtifact:  return "SHARED ARTIFACT"
        }
    }
}

private struct VisualChart: View {
    let visual: ProjectMemoryVisual
    let sortAscending: Bool

    private var points: [ProjectMemoryVisualPoint] {
        visual.points.sorted { sortAscending ? $0.value < $1.value : $0.value > $1.value }
    }

    var body: some View {
        Chart {
            switch visual.kind {
            case .timeline:
                ForEach(Array(visual.points.enumerated()), id: \.offset) { idx, point in
                    LineMark(
                        x: .value("Bucket", idx),
                        y: .value("Value", point.value)
                    )
                    .foregroundStyle(DesignSystem.Colors.hermesAureate)
                    .interpolationMethod(.catmullRom)
                    PointMark(
                        x: .value("Bucket", idx),
                        y: .value("Value", point.value)
                    )
                    .foregroundStyle(DesignSystem.Colors.hermesAureate)
                    .annotation(position: .top, alignment: .center, spacing: 2) {
                        Text(Int(point.value).formatAsTokenVolume())
                            .font(DesignSystem.Typography.monoTiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    }
                }
            case .providerMix, .hotspots, .cover:
                ForEach(Array(points.enumerated()), id: \.offset) { idx, point in
                    BarMark(
                        x: .value("Label", point.label),
                        y: .value("Value", point.value)
                    )
                    .foregroundStyle(barColor(at: idx))
                    .cornerRadius(4)
                    .annotation(position: .top, alignment: .center, spacing: 2) {
                        Text(valueLabel(point))
                            .font(DesignSystem.Typography.monoTiny)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                    }
                }
            }
        }
        .frame(height: 220)
        .chartXAxis {
            AxisMarks(values: .automatic) { _ in
                AxisGridLine().foregroundStyle(DesignSystem.Colors.borderSubtle)
                AxisValueLabel()
                    .font(DesignSystem.Typography.monoTiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(DesignSystem.Colors.borderSubtle)
                AxisValueLabel()
                    .font(DesignSystem.Typography.monoTiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
        }
        .accessibilityLabel("Chart of \(visual.title)")
        .accessibilityValue("\(visual.points.count) data points")
    }

    private func barColor(at idx: Int) -> Color {
        let palette: [Color] = [
            DesignSystem.Colors.hermesAureate,
            DesignSystem.Colors.whimsy,
            DesignSystem.Colors.ember,
            DesignSystem.Colors.amber,
            DesignSystem.Colors.hermesMercury
        ]
        return palette[idx % palette.count]
    }

    private func valueLabel(_ point: ProjectMemoryVisualPoint) -> String {
        if let s = point.subtitle, !s.isEmpty { return s }
        if visual.kind == .providerMix { return point.value.formatAsCost() }
        if visual.kind == .timeline { return Int(point.value).formatAsTokenVolume() }
        return String(Int(point.value))
    }
}

private struct CascadeInModifier: ViewModifier {
    let index: Int
    let visible: Int
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        let shown = reduceMotion || visible < 0 || index < visible
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 8)
    }
}

private extension View {
    func cascadeIn(index: Int, visible: Int, reduceMotion: Bool) -> some View {
        modifier(CascadeInModifier(index: index, visible: visible, reduceMotion: reduceMotion))
    }
}

private struct HFlowLayout: Layout {
    var horizontalSpacing: CGFloat
    var verticalSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowWidth: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if rowWidth + size.width > width, rowWidth > 0 {
                totalHeight += rowHeight + verticalSpacing
                rowHeight = size.height
                rowWidth = size.width + horizontalSpacing
            } else {
                rowWidth += size.width + horizontalSpacing
                rowHeight = max(rowHeight, size.height)
            }
        }
        totalHeight += rowHeight
        return CGSize(width: width.isFinite ? width : rowWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Project Memory Hero Detail Sheet (Editorial Observatory)

private struct ProjectMemoryHeroDetailSheet: View {
    let snapshot: ProjectMemorySnapshot
    let chatController: ChatSessionController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var insight: ProjectMemoryInsightController
    @State private var visibleSections: Int = -1
    @State private var cascadeTask: Task<Void, Never>?
    @State private var selectedPage: ProjectMemoryPage?
    @State private var selectedVisual: ProjectMemoryVisual?
    @State private var citationWrapper: CitationWrapper?

    init(snapshot: ProjectMemorySnapshot, chatController: ChatSessionController) {
        self.snapshot = snapshot
        self.chatController = chatController
        _insight = State(initialValue: ProjectMemoryInsightController(chatController: chatController))
    }

    var body: some View {
        VStack(spacing: 0) {
            chrome
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
                    EditorialHero(
                        eyebrow: "PROJECT MEMORY · \(snapshot.freshness.label)",
                        subtitle: subtitle,
                        headline: snapshot.projectDisplayName,
                        metaSegments: metaSegments,
                        leadAccent: DesignSystem.Colors.hermesAureate
                    )
                    .cascadeIn(index: 0, visible: visibleSections, reduceMotion: reduceMotion)

                    HermesReadingCard(
                        title: "Hermes Reading",
                        placeholder: "Hermes is synthesizing the project memory into a three-beat brief: what the team is working on, where the spend is going, what to do next.",
                        controller: insight,
                        onRetry: { startInsight() }
                    )
                    .cascadeIn(index: 1, visible: visibleSections, reduceMotion: reduceMotion)

                    if !snapshot.pages.isEmpty {
                        pagesSection
                            .cascadeIn(index: 2, visible: visibleSections, reduceMotion: reduceMotion)
                    }

                    if !snapshot.visuals.isEmpty {
                        visualsSection
                            .cascadeIn(index: 3, visible: visibleSections, reduceMotion: reduceMotion)
                    }

                    if !snapshot.keyFiles.isEmpty {
                        keyFilesSection
                            .cascadeIn(index: 4, visible: visibleSections, reduceMotion: reduceMotion)
                    }

                    if !snapshot.keyCommands.isEmpty {
                        keyCommandsSection
                            .cascadeIn(index: 5, visible: visibleSections, reduceMotion: reduceMotion)
                    }

                    auditFooter
                        .cascadeIn(index: 6, visible: visibleSections, reduceMotion: reduceMotion)
                }
                .padding(DesignSystem.Spacing.xl)
            }
        }
        .background(DesignSystem.Colors.background)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .onAppear { startInsight(); runEntranceMotion() }
        .onDisappear { cascadeTask?.cancel(); insight.cancel() }
        .onChange(of: chatController.streamingTick) { _, _ in
            insight.observeStreamingTick(
                messages: chatController.messages,
                activeID: chatController.activeStreamMessageId,
                isStreaming: chatController.isStreaming
            )
        }
        .onChange(of: chatController.isStreaming) { _, _ in
            insight.observeStreamingTick(
                messages: chatController.messages,
                activeID: chatController.activeStreamMessageId,
                isStreaming: chatController.isStreaming
            )
        }
        .sheet(item: $selectedPage) { page in
            ProjectMemoryPageDetailSheet(page: page, projectName: snapshot.projectDisplayName, chatController: chatController)
                .frame(minWidth: 720, minHeight: 540)
        }
        .sheet(item: $selectedVisual) { visual in
            ProjectMemoryVisualDetailSheet(visual: visual, chatController: chatController)
                .frame(minWidth: 760, minHeight: 560)
        }
        .sheet(item: $citationWrapper) { wrapper in
            CitationInsightSheet(citations: wrapper.citations, chatController: chatController)
                .frame(minWidth: 800, minHeight: 620)
        }
    }

    private var chrome: some View {
        HStack {
            Text("Memory · \(snapshot.projectDisplayName)")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            Spacer()
            Button {
                handoffToChat()
            } label: {
                Label("Continue in chat", systemImage: "arrow.right.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, DesignSystem.Spacing.xl)
        .padding(.vertical, DesignSystem.Spacing.md)
        .background(DesignSystem.Colors.surface.opacity(0.6))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DesignSystem.Colors.borderSubtle)
                .frame(height: 0.5)
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let end = snapshot.sourceWindowEnd, let start = snapshot.sourceWindowStart {
            parts.append("\(start.formatted(date: .abbreviated, time: .omitted)) – \(end.formatted(date: .abbreviated, time: .omitted))")
        }
        parts.append("Generated \(snapshot.generatedAt.formatted(.relative(presentation: .named)))")
        return parts.joined(separator: " · ")
    }

    private var metaSegments: [String] {
        var parts: [String] = []
        parts.append("\(snapshot.sourceSessionCount) sessions")
        parts.append("\(snapshot.sourceConversationCount) transcripts")
        if let usage = parseUsageSummary() {
            parts.append(usage.cost)
            parts.append(usage.tokens)
        }
        parts.append("\(snapshot.keyFiles.count) files · \(snapshot.keyCommands.count) cmds")
        return parts
    }

    private func parseUsageSummary() -> (cost: String, tokens: String)? {
        let parts = snapshot.usageSummary.split(separator: " ")
        var cost: String?
        var tokens: String?
        for p in parts {
            if p.hasPrefix("$") { cost = String(p); continue }
            if p.contains("tok") || p.contains("M") || p.contains("B") || p.contains("K") {
                tokens = String(p)
            }
        }
        if let cost, let tokens { return (cost, tokens) }
        return nil
    }

    private var pagesSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            sectionEyebrow("PAGES")
            VStack(spacing: DesignSystem.Spacing.md) {
                ForEach(Array(snapshot.pages.enumerated()), id: \.element.id) { idx, page in
                    HeroPageRow(
                        ordinal: idx + 1,
                        total: snapshot.pages.count,
                        page: page,
                        onTap: { selectedPage = page },
                        onCitationTap: { c in citationWrapper = .single(c) }
                    )
                }
            }
        }
    }

    private var visualsSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            sectionEyebrow("VISUALS")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                    ForEach(snapshot.visuals) { visual in
                        VisualTile(visual: visual, onTap: { selectedVisual = visual })
                    }
                }
                .padding(.vertical, DesignSystem.Spacing.xs)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var keyFilesSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            sectionEyebrow("KEY FILES")
            VStack(spacing: DesignSystem.Spacing.xs) {
                ForEach(Array(snapshot.keyFiles.enumerated()), id: \.offset) { idx, file in
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        Text(String(format: "%02d", idx + 1))
                            .font(DesignSystem.Typography.monoTiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .frame(width: 24, alignment: .leading)
                        Image(systemName: "doc.text")
                            .font(.system(size: 11))
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                        Text(file)
                            .font(DesignSystem.Typography.monoSmall)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(DesignSystem.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(DesignSystem.Colors.surface.opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .stroke(DesignSystem.Colors.border.opacity(0.3), lineWidth: 0.75)
            )
        }
    }

    private var keyCommandsSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            sectionEyebrow("KEY COMMANDS")
            VStack(spacing: DesignSystem.Spacing.xs) {
                ForEach(Array(snapshot.keyCommands.enumerated()), id: \.offset) { idx, cmd in
                    HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                        Text(String(format: "%02d", idx + 1))
                            .font(DesignSystem.Typography.monoTiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .frame(width: 24, alignment: .leading)
                        Image(systemName: "terminal")
                            .font(.system(size: 11))
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                        Text(cmd)
                            .font(DesignSystem.Typography.monoSmall)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(DesignSystem.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(DesignSystem.Colors.surface.opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .stroke(DesignSystem.Colors.border.opacity(0.3), lineWidth: 0.75)
            )
        }
    }

    private var auditFooter: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Rectangle()
                .fill(DesignSystem.Colors.mercuryGradient)
                .frame(height: 0.5)
            HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.sm) {
                Text("Schema v\(snapshot.schemaVersion)  ·  Hash \(String(snapshot.contentHash.prefix(8)))  ·  \(snapshot.freshness.label)")
                    .font(DesignSystem.Typography.monoTiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
        }
    }

    private func sectionEyebrow(_ title: String) -> some View {
        Text(title)
            .font(DesignSystem.Typography.caption)
            .tracking(2.0)
            .foregroundStyle(DesignSystem.Colors.textSecondary)
            .accessibilityAddTraits(.isHeader)
    }

    private func startInsight() {
        let prompt = """
        You are summarizing a local project memory snapshot for a developer.
        Write a tight three-paragraph brief — no preamble, no headings, no fluff.

        Paragraph 1: What the team is working on right now (use the pages + key files).
        Paragraph 2: Where the spend and effort are going (use the usage summary).
        Paragraph 3: What to do next (concrete, actionable, prioritized).

        Project: \(snapshot.projectDisplayName)
        Window: \(snapshot.usageSummary)
        Sessions: \(snapshot.sourceSessionCount); Transcripts: \(snapshot.sourceConversationCount)
        Key files: \(snapshot.keyFiles.prefix(8).joined(separator: ", "))
        Key commands: \(snapshot.keyCommands.prefix(6).joined(separator: " ; "))

        Page outlines:
        \(snapshot.pages.map { page in
            "• \(page.title) — \(page.summary)\n  sections: \(page.sections.map(\.title).joined(separator: ", "))"
        }.joined(separator: "\n"))
        """
        insight.generate(prompt: prompt)
    }

    @MainActor
    private func handoffToChat() {
        let prompt = """
        Continue analyzing the project memory for \(snapshot.projectDisplayName).
        Key files: \(snapshot.keyFiles.prefix(8).joined(separator: ", "))
        \(snapshot.usageSummary)
        Ask me what I want to dive into.
        """
        chatController.inputText = prompt
        Task { await chatController.send() }
        dismiss()
    }

    private func runEntranceMotion() {
        if reduceMotion {
            visibleSections = 7
            return
        }
        guard visibleSections < 0 else { return }
        visibleSections = 0
        cascadeTask?.cancel()
        cascadeTask = Task { @MainActor in
            for i in 0..<7 {
                if i > 0 {
                    try? await Task.sleep(nanoseconds: 40_000_000)
                    if Task.isCancelled { return }
                }
                withAnimation(DesignSystem.Animation.gentle) {
                    visibleSections = i + 1
                }
            }
        }
    }
}

private struct HeroPageRow: View {
    let ordinal: Int
    let total: Int
    let page: ProjectMemoryPage
    let onTap: () -> Void
    let onCitationTap: (ProjectMemoryCitation) -> Void
    @State private var hovered = false

    private var aggregatedCitations: [ProjectMemoryCitation] {
        Array(page.sections.flatMap(\.citations).prefix(6))
    }

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                Rectangle()
                    .fill(DesignSystem.Colors.mercuryGradient)
                    .frame(width: 3)
                    .frame(maxHeight: .infinity)
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.sm) {
                        Text(String(format: "%02d", ordinal))
                            .font(.system(.title3, design: .monospaced).weight(.semibold))
                            .foregroundStyle(DesignSystem.Colors.hermesAureate)
                        Text(page.title)
                            .font(DesignSystem.Typography.headline)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                        Spacer(minLength: 0)
                        Text("\(ordinal) / \(total)")
                            .font(DesignSystem.Typography.monoTiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    }
                    Text(page.summary)
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                    if !page.sections.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(page.sections) { section in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text("·")
                                        .font(DesignSystem.Typography.monoSmall)
                                        .foregroundStyle(DesignSystem.Colors.textMuted)
                                    Text(section.title)
                                        .font(DesignSystem.Typography.caption)
                                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                                }
                            }
                        }
                    }
                    if !aggregatedCitations.isEmpty {
                        HFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                            ForEach(Array(aggregatedCitations.prefix(5).enumerated()), id: \.element.id) { idx, c in
                                FootnoteCitationChip(
                                    ordinal: idx + 1,
                                    citation: c,
                                    onTap: { onCitationTap(c) }
                                )
                            }
                        }
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Open page")
                            .font(DesignSystem.Typography.monoTiny)
                            .tracking(0.8)
                    }
                    .foregroundStyle(DesignSystem.Colors.hermesAureate)
                    .padding(.top, 2)
                }
                .padding(.vertical, DesignSystem.Spacing.sm)
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(DesignSystem.Colors.surface.opacity(hovered ? 0.85 : 0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .stroke(
                        hovered ? DesignSystem.Colors.hermesAureate.opacity(0.45) : DesignSystem.Colors.border.opacity(0.3),
                        lineWidth: hovered ? 1 : 0.75
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(hovered ? 1.005 : 1.0)
        .animation(DesignSystem.Animation.hover, value: hovered)
        .onHover { hovered = $0 }
    }
}

private struct VisualTile: View {
    let visual: ProjectMemoryVisual
    let onTap: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text(visualKindLabel.uppercased())
                    .font(DesignSystem.Typography.monoTiny)
                    .tracking(1.4)
                    .foregroundStyle(DesignSystem.Colors.hermesAureate)
                Text(visual.title)
                    .font(DesignSystem.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineLimit(2)
                if let subtitle = visual.subtitle {
                    Text(subtitle)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .lineLimit(1)
                }
                MiniVisualPreview(visual: visual)
                    .frame(height: 60)
                Text("\(visual.points.count) points · open →")
                    .font(DesignSystem.Typography.monoTiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            .padding(DesignSystem.Spacing.md)
            .frame(width: 220, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(DesignSystem.Colors.surfaceElevated.opacity(hovered ? 0.85 : 0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .stroke(DesignSystem.Colors.mercuryGradient, lineWidth: hovered ? 1 : 0.75)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(hovered ? 1.02 : 1.0)
        .animation(DesignSystem.Animation.hover, value: hovered)
        .onHover { hovered = $0 }
    }

    private var visualKindLabel: String {
        switch visual.kind {
        case .cover: return "Cover"
        case .providerMix: return "Provider Mix"
        case .timeline: return "Timeline"
        case .hotspots: return "Hotspots"
        }
    }
}

private struct MiniVisualPreview: View {
    let visual: ProjectMemoryVisual

    var body: some View {
        Chart {
            switch visual.kind {
            case .timeline:
                ForEach(Array(visual.points.enumerated()), id: \.offset) { idx, p in
                    LineMark(x: .value("i", idx), y: .value("v", p.value))
                        .foregroundStyle(DesignSystem.Colors.hermesAureate)
                        .interpolationMethod(.catmullRom)
                }
            default:
                ForEach(Array(visual.points.prefix(6).enumerated()), id: \.offset) { idx, p in
                    BarMark(x: .value("i", idx), y: .value("v", p.value))
                        .foregroundStyle(barColor(idx))
                        .cornerRadius(2)
                }
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .accessibilityHidden(true)
    }

    private func barColor(_ idx: Int) -> Color {
        let palette: [Color] = [
            DesignSystem.Colors.hermesAureate,
            DesignSystem.Colors.whimsy,
            DesignSystem.Colors.ember,
            DesignSystem.Colors.amber,
            DesignSystem.Colors.hermesMercury
        ]
        return palette[idx % palette.count]
    }
}

// MARK: - Project Memory Page Detail Sheet (Editorial Observatory)

private struct ProjectMemoryPageDetailSheet: View {
    let page: ProjectMemoryPage
    let projectName: String
    let chatController: ChatSessionController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var insight: ProjectMemoryInsightController
    @State private var visibleSections: Int = -1
    @State private var cascadeTask: Task<Void, Never>?
    @State private var citationWrapper: CitationWrapper?

    init(page: ProjectMemoryPage, projectName: String, chatController: ChatSessionController) {
        self.page = page
        self.projectName = projectName
        self.chatController = chatController
        _insight = State(initialValue: ProjectMemoryInsightController(chatController: chatController))
    }

    var body: some View {
        VStack(spacing: 0) {
            chrome
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
                    EditorialHero(
                        eyebrow: "MEMORY PAGE · \(page.title)",
                        subtitle: page.summary,
                        headline: page.title,
                        metaSegments: heroMetaSegments,
                        leadAccent: DesignSystem.Colors.hermesAureate
                    )
                    .cascadeIn(index: 0, visible: visibleSections, reduceMotion: reduceMotion)

                    HermesReadingCard(
                        title: "Hermes Reading",
                        placeholder: "Hermes is interpreting this page — what it tells the operator and what to do with it.",
                        controller: insight,
                        onRetry: { startInsight() }
                    )
                    .cascadeIn(index: 1, visible: visibleSections, reduceMotion: reduceMotion)

                    if !page.sections.isEmpty {
                        sectionsSection
                            .cascadeIn(index: 2, visible: visibleSections, reduceMotion: reduceMotion)
                    } else {
                        EmptyEvidenceCallout(message: "This page has no synthesized sections yet.")
                            .cascadeIn(index: 2, visible: visibleSections, reduceMotion: reduceMotion)
                    }

                    if !page.visualIDs.isEmpty {
                        visualsRefsSection
                            .cascadeIn(index: 3, visible: visibleSections, reduceMotion: reduceMotion)
                    }

                    auditFooter
                        .cascadeIn(index: 4, visible: visibleSections, reduceMotion: reduceMotion)
                }
                .padding(DesignSystem.Spacing.xl)
            }
        }
        .background(DesignSystem.Colors.background)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .onAppear { startInsight(); runEntranceMotion() }
        .onDisappear { cascadeTask?.cancel(); insight.cancel() }
        .onChange(of: chatController.streamingTick) { _, _ in
            insight.observeStreamingTick(
                messages: chatController.messages,
                activeID: chatController.activeStreamMessageId,
                isStreaming: chatController.isStreaming
            )
        }
        .onChange(of: chatController.isStreaming) { _, _ in
            insight.observeStreamingTick(
                messages: chatController.messages,
                activeID: chatController.activeStreamMessageId,
                isStreaming: chatController.isStreaming
            )
        }
        .sheet(item: $citationWrapper) { wrapper in
            CitationInsightSheet(citations: wrapper.citations, chatController: chatController)
                .frame(minWidth: 800, minHeight: 620)
        }
    }

    private var chrome: some View {
        HStack {
            Text("\(projectName) · Memory page")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            Spacer()
            Button {
                handoffToChat()
            } label: {
                Label("Deep dive in chat", systemImage: "arrow.right.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, DesignSystem.Spacing.xl)
        .padding(.vertical, DesignSystem.Spacing.md)
        .background(DesignSystem.Colors.surface.opacity(0.6))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DesignSystem.Colors.borderSubtle)
                .frame(height: 0.5)
        }
    }

    private var heroMetaSegments: [String] {
        var parts: [String] = []
        parts.append("\(page.sections.count) sections")
        let totalCitations = page.sections.reduce(0) { $0 + $1.citations.count }
        parts.append("\(totalCitations) citations")
        if !page.visualIDs.isEmpty {
            parts.append("\(page.visualIDs.count) visuals")
        }
        return parts
    }

    private var sectionsSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            sectionEyebrow("SECTIONS")
            VStack(spacing: DesignSystem.Spacing.md) {
                ForEach(Array(page.sections.enumerated()), id: \.element.id) { idx, section in
                    NumberedSectionRow(
                        index: idx + 1,
                        total: page.sections.count,
                        title: section.title,
                        text: section.body,
                        accent: accentColor(for: idx),
                        citations: section.citations,
                        onCitationTap: { c in citationWrapper = .single(c) },
                        onCombinedCitationTap: section.citations.isEmpty ? nil : {
                            citationWrapper = CitationWrapper(citations: section.citations)
                        }
                    )
                }
            }
        }
    }

    private var visualsRefsSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            sectionEyebrow("REFERENCED VISUALS")
            Text(page.visualIDs.joined(separator: " · "))
                .font(DesignSystem.Typography.monoTiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .padding(DesignSystem.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                        .fill(DesignSystem.Colors.surface.opacity(0.4))
                )
        }
    }

    private var auditFooter: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Rectangle()
                .fill(DesignSystem.Colors.mercuryGradient)
                .frame(height: 0.5)
            Text("page-id \(page.id)  ·  \(page.sections.count) sections  ·  \(page.visualIDs.count) visuals")
                .font(DesignSystem.Typography.monoTiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
    }

    private func accentColor(for idx: Int) -> Color {
        let palette: [Color] = [
            DesignSystem.Colors.hermesAureate,
            DesignSystem.Colors.ember,
            DesignSystem.Colors.whimsy,
            DesignSystem.Colors.amber
        ]
        return palette[idx % palette.count]
    }

    private func sectionEyebrow(_ title: String) -> some View {
        Text(title)
            .font(DesignSystem.Typography.caption)
            .tracking(2.0)
            .foregroundStyle(DesignSystem.Colors.textSecondary)
            .accessibilityAddTraits(.isHeader)
    }

    private func startInsight() {
        let prompt = """
        You are reading a single page from a project memory snapshot. Write a tight 2–3 paragraph reading — no preamble, no headings, no fluff.

        Paragraph 1: What this page is actually saying about the project right now (synthesize across the sections).
        Paragraph 2: What gaps, risks, or questions the operator should care about (be specific, name files or session ids when relevant).
        Paragraph 3 (optional): What next move makes sense — a concrete suggestion the operator can take in the next 30 minutes.

        Project: \(projectName)
        Page: \(page.title)
        Summary: \(page.summary)

        Sections:
        \(page.sections.map { section in
            "• \(section.title)\n  \(section.body)"
        }.joined(separator: "\n\n"))
        """
        insight.generate(prompt: prompt)
    }

    @MainActor
    private func handoffToChat() {
        let prompt = """
        Deep dive into the project memory page "\(page.title)" for \(projectName).
        Summary: \(page.summary)
        Sections to analyze: \(page.sections.map(\.title).joined(separator: ", "))
        Pull on threads from the body text, surface contradictions, and suggest next investigations.
        """
        chatController.inputText = prompt
        Task { await chatController.send() }
        dismiss()
    }

    private func runEntranceMotion() {
        if reduceMotion {
            visibleSections = 5
            return
        }
        guard visibleSections < 0 else { return }
        visibleSections = 0
        cascadeTask?.cancel()
        cascadeTask = Task { @MainActor in
            for i in 0..<5 {
                if i > 0 {
                    try? await Task.sleep(nanoseconds: 40_000_000)
                    if Task.isCancelled { return }
                }
                withAnimation(DesignSystem.Animation.gentle) {
                    visibleSections = i + 1
                }
            }
        }
    }
}

// MARK: - Project Memory Visual Detail Sheet (Swift Charts-first)

private struct ProjectMemoryVisualDetailSheet: View {
    let visual: ProjectMemoryVisual
    let chatController: ChatSessionController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var insight: ProjectMemoryInsightController
    @State private var visibleSections: Int = -1
    @State private var cascadeTask: Task<Void, Never>?
    @State private var sortAscending: Bool = false

    init(visual: ProjectMemoryVisual, chatController: ChatSessionController) {
        self.visual = visual
        self.chatController = chatController
        _insight = State(initialValue: ProjectMemoryInsightController(chatController: chatController))
    }

    var body: some View {
        VStack(spacing: 0) {
            chrome
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
                    EditorialHero(
                        eyebrow: "VISUAL · \(kindLabel.uppercased())",
                        subtitle: visual.subtitle ?? "Source: local project memory snapshot.",
                        headline: visual.title,
                        metaSegments: heroMetaSegments,
                        leadAccent: DesignSystem.Colors.hermesAureate
                    )
                    .cascadeIn(index: 0, visible: visibleSections, reduceMotion: reduceMotion)

                    chartCard
                        .cascadeIn(index: 1, visible: visibleSections, reduceMotion: reduceMotion)

                    dataTableSection
                        .cascadeIn(index: 2, visible: visibleSections, reduceMotion: reduceMotion)

                    HermesReadingCard(
                        title: "Hermes Reading",
                        placeholder: "Hermes is interpreting this visual — what the distribution implies and what to do about it.",
                        controller: insight,
                        onRetry: { startInsight() }
                    )
                    .cascadeIn(index: 3, visible: visibleSections, reduceMotion: reduceMotion)

                    auditFooter
                        .cascadeIn(index: 4, visible: visibleSections, reduceMotion: reduceMotion)
                }
                .padding(DesignSystem.Spacing.xl)
            }
        }
        .background(DesignSystem.Colors.background)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .onAppear { startInsight(); runEntranceMotion() }
        .onDisappear { cascadeTask?.cancel(); insight.cancel() }
        .onChange(of: chatController.streamingTick) { _, _ in
            insight.observeStreamingTick(
                messages: chatController.messages,
                activeID: chatController.activeStreamMessageId,
                isStreaming: chatController.isStreaming
            )
        }
        .onChange(of: chatController.isStreaming) { _, _ in
            insight.observeStreamingTick(
                messages: chatController.messages,
                activeID: chatController.activeStreamMessageId,
                isStreaming: chatController.isStreaming
            )
        }
    }

    private var chrome: some View {
        HStack {
            Text("Visual · \(kindLabel)")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            Spacer()
            Button {
                sortAscending.toggle()
            } label: {
                Label(sortAscending ? "Sort: ascending" : "Sort: descending",
                      systemImage: sortAscending ? "arrow.up" : "arrow.down")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, DesignSystem.Spacing.xl)
        .padding(.vertical, DesignSystem.Spacing.md)
        .background(DesignSystem.Colors.surface.opacity(0.6))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DesignSystem.Colors.borderSubtle)
                .frame(height: 0.5)
        }
    }

    private var kindLabel: String {
        switch visual.kind {
        case .cover: return "Cover"
        case .providerMix: return "Provider Mix"
        case .timeline: return "Timeline"
        case .hotspots: return "Hotspots"
        }
    }

    private var heroMetaSegments: [String] {
        var parts: [String] = []
        parts.append("\(visual.points.count) points")
        let sum = visual.points.reduce(0.0) { $0 + $1.value }
        if visual.kind == .providerMix {
            parts.append("Σ \(sum.formatAsCost())")
        } else if visual.kind == .timeline {
            parts.append("Σ \(Int(sum).formatAsTokenVolume())")
        } else {
            parts.append("Σ \(Int(sum))")
        }
        if let mx = visual.points.max(by: { $0.value < $1.value }) {
            parts.append("max · \(mx.label)")
        }
        return parts
    }

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            sectionEyebrow("DISTRIBUTION")
            VisualChart(visual: visual, sortAscending: sortAscending)
                .padding(DesignSystem.Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                        .fill(DesignSystem.Colors.surface.opacity(0.55))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                        .stroke(DesignSystem.Colors.border.opacity(0.3), lineWidth: 0.75)
                )
        }
    }

    private var sortedPoints: [ProjectMemoryVisualPoint] {
        visual.points.sorted {
            sortAscending ? $0.value < $1.value : $0.value > $1.value
        }
    }

    private var hasDetail: Bool {
        sortedPoints.contains { $0.subtitle != nil }
    }

    private var dataTableSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            sectionEyebrow("DATA POINTS")
            VStack(spacing: 0) {
                HStack {
                    Text("LABEL")
                        .font(DesignSystem.Typography.monoTiny)
                        .tracking(1.4)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("VALUE")
                        .font(DesignSystem.Typography.monoTiny)
                        .tracking(1.4)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .frame(width: 120, alignment: .trailing)
                    if hasDetail {
                        Text("DETAIL")
                            .font(DesignSystem.Typography.monoTiny)
                            .tracking(1.4)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .frame(width: 140, alignment: .trailing)
                    }
                }
                .padding(.vertical, DesignSystem.Spacing.sm)
                Rectangle()
                    .fill(DesignSystem.Colors.border.opacity(0.5))
                    .frame(height: 0.5)

                ForEach(Array(sortedPoints.enumerated()), id: \.offset) { _, point in
                    HStack {
                        Text(point.label)
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(valueLabel(point))
                            .font(DesignSystem.Typography.monoSmall)
                            .foregroundStyle(DesignSystem.Colors.hermesAureate)
                            .frame(width: 120, alignment: .trailing)
                        if hasDetail {
                            if let subtitle = point.subtitle {
                                Text(subtitle)
                                    .font(DesignSystem.Typography.tiny)
                                    .foregroundStyle(DesignSystem.Colors.textMuted)
                                    .frame(width: 140, alignment: .trailing)
                            } else {
                                Color.clear.frame(width: 140)
                            }
                        }
                    }
                    .padding(.vertical, DesignSystem.Spacing.sm)
                    Rectangle()
                        .fill(DesignSystem.Colors.border.opacity(0.25))
                        .frame(height: 0.5)
                }
            }
            .padding(DesignSystem.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(DesignSystem.Colors.surface.opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .stroke(DesignSystem.Colors.border.opacity(0.3), lineWidth: 0.75)
            )
        }
    }

    private var auditFooter: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Rectangle()
                .fill(DesignSystem.Colors.mercuryGradient)
                .frame(height: 0.5)
            Text("visual-id \(visual.id)  ·  kind \(visual.kind.rawValue)  ·  \(visual.points.count) points")
                .font(DesignSystem.Typography.monoTiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
    }

    private func valueLabel(_ point: ProjectMemoryVisualPoint) -> String {
        if let s = point.subtitle, !s.isEmpty { return s }
        if visual.kind == .providerMix { return point.value.formatAsCost() }
        if visual.kind == .timeline { return Int(point.value).formatAsTokenVolume() }
        return String(Int(point.value))
    }

    private func sectionEyebrow(_ title: String) -> some View {
        Text(title)
            .font(DesignSystem.Typography.caption)
            .tracking(2.0)
            .foregroundStyle(DesignSystem.Colors.textSecondary)
            .accessibilityAddTraits(.isHeader)
    }

    private func startInsight() {
        let topLine = sortedPoints.prefix(5).map { p in
            "\(p.label): \(valueLabel(p))"
        }.joined(separator: " · ")
        let prompt = """
        You are reading a chart from a project memory snapshot.

        Write a tight 2-paragraph reading — no preamble, no headings, no fluff.

        Paragraph 1: What the distribution means (concentration, skew, outliers, recent shifts).
        Paragraph 2: What action the developer should take — concrete, specific, with at most one number.

        Visual: \(visual.title) (kind: \(kindLabel))
        Subtitle: \(visual.subtitle ?? "—")
        Top points: \(topLine)
        Total points: \(visual.points.count)
        """
        insight.generate(prompt: prompt)
    }

    private func runEntranceMotion() {
        if reduceMotion {
            visibleSections = 5
            return
        }
        guard visibleSections < 0 else { return }
        visibleSections = 0
        cascadeTask?.cancel()
        cascadeTask = Task { @MainActor in
            for i in 0..<5 {
                if i > 0 {
                    try? await Task.sleep(nanoseconds: 40_000_000)
                    if Task.isCancelled { return }
                }
                withAnimation(DesignSystem.Animation.gentle) {
                    visibleSections = i + 1
                }
            }
        }
    }
}

// MARK: - Citation Insight Sheet (LLM-powered, live streaming)

private struct CitationInsightSheet: View {
    let citations: [ProjectMemoryCitation]
    let chatController: ChatSessionController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var insight: ProjectMemoryInsightController
    @State private var visibleSections: Int = -1
    @State private var cascadeTask: Task<Void, Never>?

    init(citations: [ProjectMemoryCitation], chatController: ChatSessionController) {
        self.citations = citations
        self.chatController = chatController
        _insight = State(initialValue: ProjectMemoryInsightController(chatController: chatController))
    }

    var body: some View {
        VStack(spacing: 0) {
            chrome
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
                    EditorialHero(
                        eyebrow: "CITATION INSIGHT · \(citations.count) CITATION\(citations.count == 1 ? "" : "S")",
                        subtitle: heroSubtitle,
                        headline: heroHeadline,
                        metaSegments: heroMetaSegments,
                        leadAccent: DesignSystem.Colors.hermesAureate
                    )
                    .cascadeIn(index: 0, visible: visibleSections, reduceMotion: reduceMotion)

                    HermesReadingCard(
                        title: "Hermes Reading",
                        placeholder: citations.count == 1
                            ? "Hermes is reading this citation — what it means and why it matters."
                            : "Hermes is reading the evidence — drawing connections and surfacing what matters.",
                        controller: insight,
                        onRetry: { startInsight() }
                    )
                    .cascadeIn(index: 1, visible: visibleSections, reduceMotion: reduceMotion)

                    evidenceSection
                        .cascadeIn(index: 2, visible: visibleSections, reduceMotion: reduceMotion)

                    handoffFooter
                        .cascadeIn(index: 3, visible: visibleSections, reduceMotion: reduceMotion)
                }
                .padding(DesignSystem.Spacing.xl)
            }
        }
        .background(DesignSystem.Colors.background)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .onAppear { startInsight(); runEntranceMotion() }
        .onDisappear { cascadeTask?.cancel(); insight.cancel() }
        .onChange(of: chatController.streamingTick) { _, _ in
            insight.observeStreamingTick(
                messages: chatController.messages,
                activeID: chatController.activeStreamMessageId,
                isStreaming: chatController.isStreaming
            )
        }
        .onChange(of: chatController.isStreaming) { _, _ in
            insight.observeStreamingTick(
                messages: chatController.messages,
                activeID: chatController.activeStreamMessageId,
                isStreaming: chatController.isStreaming
            )
        }
    }

    private var chrome: some View {
        HStack {
            Text("Citation insight · live")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, DesignSystem.Spacing.xl)
        .padding(.vertical, DesignSystem.Spacing.md)
        .background(DesignSystem.Colors.surface.opacity(0.6))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DesignSystem.Colors.borderSubtle)
                .frame(height: 0.5)
        }
    }

    private var heroHeadline: String {
        if citations.count == 1, let only = citations.first {
            return only.title.isEmpty ? "Untitled evidence" : only.title
        }
        let trimmed = insight.streamingContent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty,
           let dot = trimmed.firstIndex(where: { ".!?".contains($0) }) {
            return String(trimmed[..<dot]) + "."
        }
        return "Reading the evidence"
    }

    private var heroSubtitle: String {
        let kinds = Array(Set(citations.map(\.sourceKind))).map { kind -> String in
            switch kind {
            case .conversation:    return "transcripts"
            case .skillDoc:        return "skill docs"
            case .agentDoc:        return "agent docs"
            case .sharedArtifact:  return "shared artifacts"
            }
        }
        return "Across " + kinds.joined(separator: ", ") + " · synthesized by Hermes"
    }

    private var heroMetaSegments: [String] {
        var parts: [String] = []
        parts.append("\(citations.count) cite\(citations.count == 1 ? "" : "s")")
        let snippetChars = citations.reduce(0) { $0 + $1.snippet.count }
        parts.append("\(snippetChars) chars evidence")
        if let oldest = citations.compactMap(\.createdAt).min() {
            parts.append("since \(oldest.formatted(.relative(presentation: .named)))")
        }
        return parts
    }

    private var evidenceSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            sectionEyebrow("EVIDENCE")
            VStack(spacing: DesignSystem.Spacing.md) {
                ForEach(Array(citations.enumerated()), id: \.element.id) { idx, citation in
                    CitationQuoteCard(ordinal: idx + 1, citation: citation)
                }
            }
        }
    }

    private var handoffFooter: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Rectangle()
                .fill(DesignSystem.Colors.mercuryGradient)
                .frame(height: 0.5)
            HStack {
                Text("Want to keep pulling on this thread?")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                Spacer()
                Button {
                    handoffToChat()
                } label: {
                    Label("Continue in chat", systemImage: "arrow.right.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }

    private func sectionEyebrow(_ title: String) -> some View {
        Text(title)
            .font(DesignSystem.Typography.caption)
            .tracking(2.0)
            .foregroundStyle(DesignSystem.Colors.textSecondary)
            .accessibilityAddTraits(.isHeader)
    }

    private func startInsight() {
        let citationSummaries = citations.enumerated().map { idx, citation in
            """
            [\(String(format: "%02d", idx + 1))] \(citation.title) (\(citation.sourceKind.rawValue), id: \(citation.sourceID))
            \(citation.snippet)
            """
        }.joined(separator: "\n\n")

        let prompt = citations.count == 1 ? """
            You are reading a single piece of evidence from a project's local memory. Write a tight 2-paragraph reading — no preamble, no headings, no fluff.

            Paragraph 1: What this evidence actually says and why it matters in this project.
            Paragraph 2: What the operator should do next — concrete, specific, low-friction.

            \(citationSummaries)
            """ : """
            You are synthesizing a small evidence pack from a project's local memory. The citations below were grouped because they share a section. Write a tight 2–3 paragraph reading — no preamble, no headings, no fluff. Connect across the citations.

            Paragraph 1: What story this evidence tells, drawing connections (name 1–2 citations by their [01]-style ordinals).
            Paragraph 2: What pattern or risk this surfaces.
            Paragraph 3 (optional): What concrete next move makes sense given this evidence.

            \(citationSummaries)
            """
        insight.generate(prompt: prompt)
    }

    @MainActor
    private func handoffToChat() {
        let citationTitles = citations.prefix(5).map(\.title).joined(separator: ", ")
        let prompt = """
        Continue analyzing these citations — pull on the threads I haven't surfaced yet.
        Citations: \(citationTitles)
        Hermes already gave me one reading — give me a deeper one with concrete file/path mentions if you can.
        """
        chatController.inputText = prompt
        Task { await chatController.send() }
        dismiss()
    }

    private func runEntranceMotion() {
        if reduceMotion {
            visibleSections = 4
            return
        }
        guard visibleSections < 0 else { return }
        visibleSections = 0
        cascadeTask?.cancel()
        cascadeTask = Task { @MainActor in
            for i in 0..<4 {
                if i > 0 {
                    try? await Task.sleep(nanoseconds: 40_000_000)
                    if Task.isCancelled { return }
                }
                withAnimation(DesignSystem.Animation.gentle) {
                    visibleSections = i + 1
                }
            }
        }
    }
}
