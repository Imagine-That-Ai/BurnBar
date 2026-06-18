import Charts
import OpenBurnBarCore
import SwiftUI

// Project list/hub rows and inline question/mission/followup cards.
// Extracted from ProjectsView.swift (god-file decomposition) — same module, verbatim.

struct ProjectListRow: View {
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

struct ProjectHubView: View {
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
    @Environment(AccountManager.self) private var accountManager
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
            accountManager: accountManager,
            settingsManager: settingsManager
        )
        let projectMemorySync = SessionLogSyncService(context: syncContext)

        if forceRefresh == false {
            for key in projectMemoryKeys {
                if let cached = try? await dataStore.fetchProjectMemorySnapshot(projectSlug: key) {
                    projectMemorySnapshot = cached
                    break
                }
            }
        }

        if forceRefresh == false, projectMemorySnapshot == nil {
            for key in projectMemoryKeys {
                if let cloudSnapshot = try? await projectMemorySync.fetchCloudProjectMemorySnapshot(projectSlug: key) {
                    projectMemorySnapshot = cloudSnapshot
                    try? await dataStore.upsertProjectMemorySnapshot(cloudSnapshot)
                    break
                }
            }
        }

        var conversations: [ConversationRecord] = []
        for key in projectMemoryKeys {
            if let rows = try? await dataStore.fetchConversationsForTranscriptScan(
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
            let fallback = (try? await dataStore.fetchConversations(limit: 500)) ?? []
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
            try await dataStore.upsertProjectMemorySnapshot(snapshot)
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

struct InlineQuestionRow: View {
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

struct InlineMissionCard: View {
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
                        let note = approvalNote
                        withAnimation(DesignSystem.Animation.standard) {
                            approvalNote = ""
                        }
                        Task {
                            await operatingLayer.approveMission(note: note)
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

struct InlineFollowupRow: View {
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

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
