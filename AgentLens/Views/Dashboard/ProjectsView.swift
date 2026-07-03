import Charts
import OpenBurnBarCore
import SwiftUI

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

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
    @Environment(\.dashboardLiveBackdropActive) private var dashboardLiveBackdropActive

    // Cached aggregate. Rebuilt only when the inputs that materially shape
    // the merge change (usages, controllerProjects). Pre-cache, this
    // O(usages + projects) aggregation reran on every observable wiggle of
    // `dataStore` — and `dataStore.usages` can hold up to 5 000 rows on a
    // warm launch.
    @State private var cachedMergedProjects: [MergedProject] = []
    @State private var lastMergedProjectsKey: MergedProjectsCacheKey?

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

    /// Cache key for the materialised `mergedProjects` array. We avoid hashing
    /// the full `dataStore.usages` array (5 000+ rows on warm launch) by
    /// instead deriving a cheap proxy: the version ticker that
    /// `DataStoreCoordinator` bumps on every mutating write + the controller
    /// project count. The slugs themselves never change in place — projects
    /// are only added/removed/renamed via mutations that bump the count or
    /// trigger `controllerProjects` to be reassigned wholesale, which
    /// SwiftUI's `.onChange(of: count)` already catches.
    fileprivate struct MergedProjectsCacheKey: Equatable {
        let usagesVersion: Int
        let usagesCount: Int
        let controllerProjectsCount: Int
        let controllerProjectsDigest: UInt64
    }

    private var mergedProjectsCacheKey: MergedProjectsCacheKey {
        // A FNV-1a digest of the slugs catches the (rare) rename case where
        // count is unchanged. The hash is computed in O(n) over the slug
        // characters but `n` is small (typically <50 projects), and only the
        // characters of the slug strings are walked — never the usage array.
        var hash: UInt64 = 0xcbf29ce484222325
        for project in daemonManager.controllerProjects {
            for byte in project.projectSlug.utf8 {
                hash ^= UInt64(byte)
                hash &*= 0x100000001b3
            }
            hash ^= 0xff // slug separator
        }
        return MergedProjectsCacheKey(
            usagesVersion: dataStore.usagesVersion,
            usagesCount: dataStore.usages.count,
            controllerProjectsCount: daemonManager.controllerProjects.count,
            controllerProjectsDigest: hash
        )
    }

    private var mergedProjects: [MergedProject] {
        // First-paint fallback: if `@State` hasn't been hydrated yet but the
        // inputs aren't empty, compute synchronously so the user doesn't see
        // a one-frame empty flash. Every subsequent body invocation hits the
        // cached `@State` value and skips the aggregation entirely.
        if lastMergedProjectsKey == nil,
           !dataStore.usages.isEmpty || !daemonManager.controllerProjects.isEmpty {
            return Self.computeMergedProjects(
                usages: dataStore.usages,
                controllerProjects: daemonManager.controllerProjects
            )
        }
        return cachedMergedProjects
    }

    private func rebuildMergedProjectsIfNeeded() {
        let key = mergedProjectsCacheKey
        guard key != lastMergedProjectsKey else { return }
        cachedMergedProjects = Self.computeMergedProjects(
            usages: dataStore.usages,
            controllerProjects: daemonManager.controllerProjects
        )
        lastMergedProjectsKey = key
    }

    /// Pure, deterministic aggregation. Exposed `internal` so tests in
    /// `AgentLensTests/Dashboard/ProjectsMergedProjectsCacheTests.swift` can
    /// pin the matrix down without a SwiftUI host.
    static func computeMergedProjects(
        usages: [TokenUsage],
        controllerProjects: [BurnBarReviewProjectSnapshot]
    ) -> [MergedProject] {
        // Usage by project
        var usageByProject: [String: (cost: Double, tokens: Int, count: Int, providers: Set<AgentProvider>)] = [:]
        for usage in usages {
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
        for project in controllerProjects {
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
        .background(dashboardLiveBackdropActive ? Color.clear : DesignSystem.Colors.background)
        .task { await refreshControllerProjectsIfNeeded() }
        .onAppear { rebuildMergedProjectsIfNeeded() }
        .onChange(of: dataStore.usagesVersion) { _, _ in rebuildMergedProjectsIfNeeded() }
        .onChange(of: daemonManager.controllerProjects.count) { _, _ in rebuildMergedProjectsIfNeeded() }
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
                    ContentUnavailableView(
                        "No projects yet",
                        systemImage: "folder",
                        description: Text("Projects appear when OpenBurnBar scans agent sessions or you register one for scheduled reviews.")
                    )
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
