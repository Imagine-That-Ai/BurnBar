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

    @State private var daemonManager: OpenBurnBarDaemonManager
    @State private var openProject: MergedProject?
    @State private var draft: ControllerProjectDraft?
    @State private var feedback: String?
    @State private var listAppeared = false

    init(
        dataStore: DataStore,
        settingsManager: SettingsManager,
        operatingLayer: OpenBurnBarOperatingLayer,
        daemonManager: OpenBurnBarDaemonManager = .shared
    ) {
        self.dataStore = dataStore
        self.settingsManager = settingsManager
        self._operatingLayer = Bindable(operatingLayer)
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
    let onBack: () -> Void
    let onEditSetup: () -> Void
    let onLaunchReview: (BurnBarControllerReviewCadence) -> Void
    let onRegister: () -> Void
    @State private var projectMemorySnapshot: ProjectMemorySnapshot?
    @State private var projectMemoryError: String?
    @State private var isRefreshingProjectMemory = false

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
                    ProjectMemoryHeroCard(snapshot: snapshot)

                    ForEach(snapshot.pages.prefix(2)) { page in
                        ProjectMemoryPageCard(page: page)
                    }

                    if snapshot.visuals.isEmpty == false {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: DesignSystem.Spacing.md) {
                                ForEach(snapshot.visuals) { visual in
                                    ProjectMemoryVisualCard(visual: visual)
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

    private var coverVisual: ProjectMemoryVisual? {
        snapshot.visuals.first { $0.kind == .cover }
    }

    var body: some View {
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

    var body: some View {
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
                        Text("\(section.citations.count) citation\(section.citations.count == 1 ? "" : "s")")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.hermesAureate)
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
    }
}

private struct ProjectMemoryVisualCard: View {
    let visual: ProjectMemoryVisual

    private var maxValue: Double {
        max(visual.points.map(\.value).max() ?? 1, 1)
    }

    var body: some View {
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
