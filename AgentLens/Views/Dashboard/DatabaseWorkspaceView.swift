import SwiftUI

// MARK: - Database Workspace View

struct DatabaseWorkspaceView: View {
    @Bindable var dataStore: DataStore
    @Bindable var settingsManager: SettingsManager
    var accountManager: AccountManager
    var cloudSyncService: CloudSyncService?

    @State private var mode: DatabaseWorkspaceMode = .story
    @State private var snapshot = DatabaseWorkspaceSnapshot()
    @State private var filter = DatabaseWorkspaceFilterState()
    @State private var selection: DatabaseWorkspaceSelection?
    @State private var appeared = false

    var body: some View {
        HSplitView {
            mainContent
                .frame(minWidth: 500)

            if let selection, mode == .atlas || mode == .system {
                inspectorPanel(for: selection)
                    .frame(width: 300)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .background(Color.clear)
        .task { rebuildSnapshot() }
        .onChange(of: dataStore.usages.count) { _, _ in rebuildSnapshot() }
        .onChange(of: dataStore.lastRefresh) { _, _ in rebuildSnapshot() }
    }

    private func rebuildSnapshot() {
        snapshot = DatabaseWorkspaceSnapshotBuilder.build(
            from: dataStore,
            settingsManager: settingsManager,
            accountManager: accountManager,
            cloudSyncService: cloudSyncService
        )
    }

    // MARK: - Main Content

    private var mainContent: some View {
        VStack(spacing: 0) {
            commandStrip
            Divider().foregroundStyle(DesignSystem.Colors.borderSubtle)

            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
                    switch mode {
                    case .story:
                        storyContent
                    case .atlas:
                        atlasContent
                    case .system:
                        systemContent
                    }
                }
                .padding(DesignSystem.Spacing.xl)
            }
            .scrollContentBackground(.hidden)
        }
        .onAppear {
            withAnimation(DesignSystem.Animation.standard) {
                appeared = true
            }
        }
    }

    // MARK: - Command Strip

    private var commandStrip: some View {
        HStack(spacing: DesignSystem.Spacing.lg) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Database")
                    .font(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                HStack(spacing: DesignSystem.Spacing.sm) {
                    Circle()
                        .fill(snapshot.indexingEnabled ? DesignSystem.Colors.success : DesignSystem.Colors.textMuted)
                        .frame(width: 6, height: 6)

                    Text(freshnessLabel)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            }

            Spacer()

            if mode == .atlas {
                HStack(spacing: DesignSystem.Spacing.xs) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(DesignSystem.Colors.textMuted)

                    TextField("Search corpus...", text: $filter.searchQuery)
                        .textFieldStyle(.plain)
                        .font(DesignSystem.Typography.body)
                        .frame(width: 180)
                }
                .padding(.horizontal, DesignSystem.Spacing.md)
                .padding(.vertical, DesignSystem.Spacing.xs)
                .background(
                    Capsule().fill(DesignSystem.Colors.surfaceElevated.opacity(0.6))
                )
                .overlay(
                    Capsule().stroke(DesignSystem.Colors.borderSubtle, lineWidth: 0.5)
                )
            }

            modeSwitcher
        }
        .padding(.horizontal, DesignSystem.Spacing.xl)
        .padding(.vertical, DesignSystem.Spacing.md)
        .background(DesignSystem.Colors.surface.opacity(0.4))
    }

    private var modeSwitcher: some View {
        HStack(spacing: 2) {
            ForEach(DatabaseWorkspaceMode.allCases) { m in
                Button {
                    withAnimation(DesignSystem.Animation.standard) {
                        mode = m
                    }
                } label: {
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        Image(systemName: m.icon)
                            .font(.system(size: 10, weight: .medium))
                        Text(m.displayName)
                            .font(DesignSystem.Typography.caption)
                    }
                    .foregroundStyle(mode == m ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textMuted)
                    .padding(.horizontal, DesignSystem.Spacing.md)
                    .padding(.vertical, DesignSystem.Spacing.xs)
                    .background(
                        Capsule().fill(mode == m ? DesignSystem.Colors.surfaceElevated : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(
            Capsule().fill(DesignSystem.Colors.surface.opacity(0.6))
        )
        .overlay(
            Capsule().stroke(DesignSystem.Colors.borderSubtle, lineWidth: 0.5)
        )
    }

    private var freshnessLabel: String {
        if let last = snapshot.lastRefresh {
            return "Updated \(last.formatted(date: .omitted, time: .shortened))"
        }
        return "Never scanned"
    }

    // MARK: - Story Mode

    @ViewBuilder
    private var storyContent: some View {
        if !snapshot.indexingEnabled && snapshot.totalSessions == 0 {
            indexingDisabledState
        } else {
            storyCorpusBand
                .storyReveal(appeared: appeared, delay: 0)
            storyActivityBand
                .storyReveal(appeared: appeared, delay: 0.06)
            storySearchCoverageBand
                .storyReveal(appeared: appeared, delay: 0.12)
            storyRecentSessionsBand
                .storyReveal(appeared: appeared, delay: 0.18)
            storySharedBand
                .storyReveal(appeared: appeared, delay: 0.24)
            storySystemTrustBand
                .storyReveal(appeared: appeared, delay: 0.30)
        }
    }

    private var storyCorpusBand: some View {
        WideBand(title: "Corpus") {
            HStack(spacing: DesignSystem.Spacing.xxl) {
                bandMetric(label: "Sessions", value: "\(snapshot.totalSessions)")
                bandMetric(label: "Conversations", value: "\(snapshot.totalConversations)")
                bandMetric(
                    label: "Total Cost",
                    value: snapshot.totalCostAllTime.formatAsCost()
                )
                bandMetric(
                    label: "Total Tokens",
                    value: snapshot.totalTokensAllTime.formatAsTokenVolume()
                )
                bandMetric(label: "Providers", value: "\(snapshot.activeProviders.count)")
                bandMetric(label: "Models", value: "\(snapshot.activeModels.count)")
                bandMetric(label: "Projects", value: "\(snapshot.projectNames.count)")

                Spacer()

                if let oldest = snapshot.oldestSession, let newest = snapshot.newestSession {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Span")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                        Text("\(oldest.formatted(date: .abbreviated, time: .omitted)) - \(newest.formatted(date: .abbreviated, time: .omitted))")
                            .font(DesignSystem.Typography.monoSmall)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                    }
                }
            }
        }
    }

    private var storyActivityBand: some View {
        WideBand(title: "Activity by Provider") {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                ForEach(snapshot.providerSummaries.prefix(8)) { summary in
                    HStack(spacing: DesignSystem.Spacing.md) {
                        Circle()
                            .fill(DesignSystem.Colors.primary(for: summary.provider))
                            .frame(width: 8, height: 8)

                        Text(summary.provider.displayName)
                            .font(DesignSystem.Typography.body)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                            .frame(width: 120, alignment: .leading)

                        BarFill(
                            fraction: snapshot.totalCostAllTime > 0
                                ? summary.totalCost / snapshot.totalCostAllTime
                                : 0,
                            color: DesignSystem.Colors.primary(for: summary.provider)
                        )

                        Text(summary.totalCost.formatAsCost())
                            .font(DesignSystem.Typography.monoSmall)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .frame(width: 70, alignment: .trailing)

                        Text("\(summary.sessionCount) sess")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .frame(width: 60, alignment: .trailing)
                    }
                }
            }
        }
    }

    private var storySearchCoverageBand: some View {
        WideBand(title: "Search Coverage") {
            HStack(spacing: DesignSystem.Spacing.xxl) {
                bandMetric(label: "Indexed Documents", value: "\(snapshot.indexedDocuments)")
                bandMetric(label: "Source Artifacts", value: "\(snapshot.sourceArtifacts)")
                bandMetric(label: "Embedding Models", value: "\(snapshot.embeddingModels)")
                bandMetric(label: "Embedded Chunks", value: "\(snapshot.embeddedChunks)")

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("Indexing")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        Circle()
                            .fill(snapshot.indexingEnabled ? DesignSystem.Colors.success : DesignSystem.Colors.error)
                            .frame(width: 6, height: 6)
                        Text(snapshot.indexingEnabled ? "Enabled" : "Disabled")
                            .font(DesignSystem.Typography.monoSmall)
                            .foregroundStyle(snapshot.indexingEnabled ? DesignSystem.Colors.success : DesignSystem.Colors.error)
                    }
                }
            }
        }
    }

    private var storyRecentSessionsBand: some View {
        WideBand(title: "Recent Sessions") {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                ForEach(snapshot.recentSessions.prefix(8)) { usage in
                    HStack(spacing: DesignSystem.Spacing.md) {
                        Circle()
                            .fill(DesignSystem.Colors.primary(for: usage.provider))
                            .frame(width: 6, height: 6)

                        Text(usage.provider.displayName)
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .frame(width: 100, alignment: .leading)

                        Text(usage.model)
                            .font(DesignSystem.Typography.monoSmall)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                            .lineLimit(1)

                        Spacer()

                        Text(usage.cost.formatAsCost())
                            .font(DesignSystem.Typography.monoSmall)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)

                        Text(usage.startTime.formatted(date: .abbreviated, time: .shortened))
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .frame(width: 120, alignment: .trailing)
                    }
                }
            }
        }
    }

    private var storySharedBand: some View {
        WideBand(title: "Shared Artifacts") {
            if accountManager.isSignedIn {
                HStack(spacing: DesignSystem.Spacing.xxl) {
                    bandMetric(label: "Shared Artifacts", value: "\(snapshot.sharedArtifactCount)")
                    bandMetric(label: "Permissions", value: "\(snapshot.permissions.count)")
                    bandMetric(label: "Audit Events", value: "\(snapshot.auditEvents.count)")

                    let syncedCount = snapshot.syncStates.filter { $0.syncStatus == .synced }.count
                    let pendingCount = snapshot.syncStates.filter { $0.syncStatus == .pendingUpload || $0.syncStatus == .pendingPull }.count
                    bandMetric(label: "Synced", value: "\(syncedCount)")
                    bandMetric(label: "Pending", value: "\(pendingCount)")

                    Spacer()
                }
            } else {
                unavailableLabel("Sign in to view shared artifacts and team state.")
            }
        }
    }

    private var storySystemTrustBand: some View {
        WideBand(title: "System Trust") {
            HStack(spacing: DesignSystem.Spacing.xxl) {
                let healthyCount = snapshot.retrievalHealth.filter { $0.status == .healthy }.count
                let degradedCount = snapshot.retrievalHealth.filter { $0.status == .degraded }.count
                let failedCount = snapshot.retrievalHealth.filter { $0.status == .failed }.count

                bandMetric(label: "Healthy", value: "\(healthyCount)", color: DesignSystem.Colors.success)
                bandMetric(label: "Degraded", value: "\(degradedCount)", color: degradedCount > 0 ? DesignSystem.Colors.warning : nil)
                bandMetric(label: "Failed", value: "\(failedCount)", color: failedCount > 0 ? DesignSystem.Colors.error : nil)

                Divider().frame(height: 28)

                let activeJobs = snapshot.projectionJobs.filter { $0.status == .running || $0.status == .leased }.count
                let queuedJobs = snapshot.projectionJobs.filter { $0.status == .queued }.count
                let failedJobs = snapshot.projectionJobs.filter { $0.status == .failed }.count
                bandMetric(label: "Active Jobs", value: "\(activeJobs)")
                bandMetric(label: "Queued", value: "\(queuedJobs)")
                bandMetric(label: "Failed Jobs", value: "\(failedJobs)", color: failedJobs > 0 ? DesignSystem.Colors.error : nil)

                Spacer()
            }
        }
    }

    // MARK: - Atlas Mode

    @ViewBuilder
    private var atlasContent: some View {
        if !snapshot.indexingEnabled && snapshot.totalSessions == 0 {
            indexingDisabledState
        } else {
            atlasProviderChartBand
            atlasDenseTable
        }
    }

    private var atlasProviderChartBand: some View {
        WideBand(title: "Cost Mix") {
            HStack(spacing: DesignSystem.Spacing.md) {
                ForEach(snapshot.providerSummaries.prefix(6)) { summary in
                    Button {
                        withAnimation(DesignSystem.Animation.standard) {
                            selection = .provider(summary.provider)
                        }
                    } label: {
                        VStack(spacing: DesignSystem.Spacing.xs) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(DesignSystem.Colors.primary(for: summary.provider))
                                .frame(
                                    width: 28,
                                    height: max(8, CGFloat(snapshot.totalCostAllTime > 0
                                        ? summary.totalCost / snapshot.totalCostAllTime * 80
                                        : 4))
                                )

                            Text(summary.provider.displayName)
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                                .lineLimit(1)

                            Text(summary.totalCost.formatAsCost())
                                .font(DesignSystem.Typography.monoTiny)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                        }
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
            }
        }
    }

    private var atlasDenseTable: some View {
        WideBand(title: "Sessions") {
            VStack(spacing: 0) {
                // Header
                HStack(spacing: 0) {
                    tableHeader("Provider", width: 110)
                    tableHeader("Model", width: nil)
                    tableHeader("Project", width: 120)
                    tableHeader("Cost", width: 70)
                    tableHeader("Tokens", width: 80)
                    tableHeader("Date", width: 130)
                }
                .padding(.bottom, DesignSystem.Spacing.xs)

                Divider().foregroundStyle(DesignSystem.Colors.borderSubtle)

                let filtered = filteredSessions
                ForEach(filtered.prefix(50)) { usage in
                    Button {
                        withAnimation(DesignSystem.Animation.standard) {
                            selection = .session(usage.id)
                        }
                    } label: {
                        HStack(spacing: 0) {
                            HStack(spacing: DesignSystem.Spacing.xs) {
                                Circle()
                                    .fill(DesignSystem.Colors.primary(for: usage.provider))
                                    .frame(width: 6, height: 6)
                                Text(usage.provider.displayName)
                                    .lineLimit(1)
                            }
                            .frame(width: 110, alignment: .leading)

                            Text(usage.model)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Text(usage.projectName)
                                .lineLimit(1)
                                .frame(width: 120, alignment: .leading)

                            Text(usage.cost.formatAsCost())
                                .font(DesignSystem.Typography.monoSmall)
                                .frame(width: 70, alignment: .trailing)

                            Text(usage.totalTokens.formatAsTokenVolume())
                                .font(DesignSystem.Typography.monoSmall)
                                .frame(width: 80, alignment: .trailing)

                            Text(usage.startTime.formatted(date: .abbreviated, time: .shortened))
                                .frame(width: 130, alignment: .trailing)
                        }
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .padding(.vertical, DesignSystem.Spacing.xs)
                        .background(
                            selection == .session(usage.id)
                                ? DesignSystem.Colors.surfaceElevated.opacity(0.5)
                                : Color.clear
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Divider().foregroundStyle(DesignSystem.Colors.borderSubtle.opacity(0.5))
                }

                if filtered.count > 50 {
                    Text("\(filtered.count - 50) more sessions...")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .padding(.top, DesignSystem.Spacing.sm)
                }
            }
        }
    }

    // MARK: - System Mode

    @ViewBuilder
    private var systemContent: some View {
        systemProjectionQueueBand
        systemRetrievalHealthBand
        systemEmbeddingBand
        systemAuditFeedBand
        systemSyncBand
    }

    private var systemProjectionQueueBand: some View {
        WideBand(title: "Projection Queue") {
            if snapshot.projectionJobs.isEmpty {
                emptyLabel("No projection jobs recorded.")
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        tableHeader("Type", width: 80)
                        tableHeader("Status", width: 80)
                        tableHeader("Source", width: nil)
                        tableHeader("Attempts", width: 70)
                        tableHeader("Scheduled", width: 130)
                    }
                    .padding(.bottom, DesignSystem.Spacing.xs)

                    Divider().foregroundStyle(DesignSystem.Colors.borderSubtle)

                    ForEach(snapshot.projectionJobs.prefix(30)) { job in
                        Button {
                            withAnimation(DesignSystem.Animation.standard) {
                                selection = .projectionJob(job.id)
                            }
                        } label: {
                            HStack(spacing: 0) {
                                Text(job.jobType.rawValue)
                                    .frame(width: 80, alignment: .leading)

                                HStack(spacing: DesignSystem.Spacing.xs) {
                                    Circle()
                                        .fill(jobStatusColor(job.status))
                                        .frame(width: 6, height: 6)
                                    Text(job.status.rawValue)
                                }
                                .frame(width: 80, alignment: .leading)

                                Text(job.sourceKind?.rawValue ?? "-")
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                Text("\(job.attempts)/\(job.maxAttempts)")
                                    .frame(width: 70, alignment: .center)

                                Text(job.scheduledAt.formatted(date: .abbreviated, time: .shortened))
                                    .frame(width: 130, alignment: .trailing)
                            }
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .padding(.vertical, DesignSystem.Spacing.xs)
                            .background(
                                selection == .projectionJob(job.id)
                                    ? DesignSystem.Colors.surfaceElevated.opacity(0.5)
                                    : Color.clear
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Divider().foregroundStyle(DesignSystem.Colors.borderSubtle.opacity(0.5))
                    }
                }
            }
        }
    }

    private var systemRetrievalHealthBand: some View {
        WideBand(title: "Retrieval Health") {
            if snapshot.retrievalHealth.isEmpty {
                emptyLabel("No retrieval health data.")
            } else {
                VStack(spacing: DesignSystem.Spacing.sm) {
                    ForEach(snapshot.retrievalHealth, id: \.subsystem) { health in
                        Button {
                            withAnimation(DesignSystem.Animation.standard) {
                                selection = .retrievalSubsystem(health.subsystem)
                            }
                        } label: {
                            HStack(spacing: DesignSystem.Spacing.md) {
                                Circle()
                                    .fill(healthStatusColor(health.status))
                                    .frame(width: 8, height: 8)

                                Text(health.subsystem.rawValue)
                                    .font(DesignSystem.Typography.body)
                                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                                    .frame(width: 140, alignment: .leading)

                                Text(health.status.rawValue)
                                    .font(DesignSystem.Typography.monoSmall)
                                    .foregroundStyle(healthStatusColor(health.status))

                                Spacer()

                                if let err = health.errorMessage {
                                    Text(err)
                                        .font(DesignSystem.Typography.tiny)
                                        .foregroundStyle(DesignSystem.Colors.textMuted)
                                        .lineLimit(1)
                                }

                                Text(health.observedAt.formatted(date: .omitted, time: .shortened))
                                    .font(DesignSystem.Typography.tiny)
                                    .foregroundStyle(DesignSystem.Colors.textMuted)
                            }
                            .padding(.vertical, DesignSystem.Spacing.xs)
                            .background(
                                selection == .retrievalSubsystem(health.subsystem)
                                    ? DesignSystem.Colors.surfaceElevated.opacity(0.5)
                                    : Color.clear
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var systemEmbeddingBand: some View {
        WideBand(title: "Embedding Coverage") {
            HStack(spacing: DesignSystem.Spacing.xxl) {
                bandMetric(label: "Embedding Models", value: "\(snapshot.embeddingModels)")
                bandMetric(label: "Active Versions", value: "\(snapshot.embeddingVersions)")
                bandMetric(label: "Embedded Chunks", value: "\(snapshot.embeddedChunks)")
                Spacer()
            }
        }
    }

    private var systemAuditFeedBand: some View {
        WideBand(title: "Audit Feed") {
            if snapshot.auditEvents.isEmpty {
                emptyLabel("No audit events recorded.")
            } else {
                VStack(spacing: DesignSystem.Spacing.sm) {
                    ForEach(snapshot.auditEvents.prefix(20)) { event in
                        Button {
                            withAnimation(DesignSystem.Animation.standard) {
                                selection = .auditEvent(event.id)
                            }
                        } label: {
                            HStack(spacing: DesignSystem.Spacing.md) {
                                Image(systemName: auditActionIcon(event.action))
                                    .font(.system(size: 10))
                                    .foregroundStyle(DesignSystem.Colors.textMuted)
                                    .frame(width: 16)

                                Text(event.action.rawValue)
                                    .font(DesignSystem.Typography.caption)
                                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                                    .frame(width: 120, alignment: .leading)

                                Text(event.workspaceID)
                                    .font(DesignSystem.Typography.tiny)
                                    .foregroundStyle(DesignSystem.Colors.textMuted)
                                    .lineLimit(1)

                                Spacer()

                                Text(event.occurredAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(DesignSystem.Typography.tiny)
                                    .foregroundStyle(DesignSystem.Colors.textMuted)
                            }
                            .padding(.vertical, DesignSystem.Spacing.xxs)
                            .background(
                                selection == .auditEvent(event.id)
                                    ? DesignSystem.Colors.surfaceElevated.opacity(0.5)
                                    : Color.clear
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var systemSyncBand: some View {
        WideBand(title: "Sync Status") {
            if accountManager.isSignedIn {
                HStack(spacing: DesignSystem.Spacing.xxl) {
                    let synced = snapshot.syncStates.filter { $0.syncStatus == .synced }.count
                    let pending = snapshot.syncStates.filter {
                        $0.syncStatus == .pendingUpload || $0.syncStatus == .pendingPull
                    }.count
                    let conflicted = snapshot.syncStates.filter { $0.syncStatus == .conflicted }.count
                    let failed = snapshot.syncStates.filter { $0.syncStatus == .failed }.count

                    bandMetric(label: "Synced", value: "\(synced)", color: DesignSystem.Colors.success)
                    bandMetric(label: "Pending", value: "\(pending)", color: pending > 0 ? DesignSystem.Colors.warning : nil)
                    bandMetric(label: "Conflicted", value: "\(conflicted)", color: conflicted > 0 ? DesignSystem.Colors.error : nil)
                    bandMetric(label: "Failed", value: "\(failed)", color: failed > 0 ? DesignSystem.Colors.error : nil)

                    Spacer()

                    if cloudSyncService?.isSyncing == true {
                        HStack(spacing: DesignSystem.Spacing.xs) {
                            ProgressView().controlSize(.mini)
                            Text("Syncing...")
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                        }
                    }
                }
            } else {
                unavailableLabel("Sign in to view sync status across devices.")
            }
        }
    }

    // MARK: - Inspector

    @ViewBuilder
    private func inspectorPanel(for sel: DatabaseWorkspaceSelection) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                HStack {
                    Text("Inspector")
                        .font(DesignSystem.Typography.headline)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)

                    Spacer()

                    Button {
                        withAnimation(DesignSystem.Animation.standard) {
                            selection = nil
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    }
                    .buttonStyle(.plain)
                }

                Divider().foregroundStyle(DesignSystem.Colors.borderSubtle)

                switch sel {
                case .session(let id):
                    if let usage = snapshot.recentSessions.first(where: { $0.id == id })
                        ?? dataStore.usages.first(where: { $0.id == id }) {
                        inspectorRow("Provider", usage.provider.displayName)
                        inspectorRow("Model", usage.model)
                        inspectorRow("Project", usage.projectName)
                        inspectorRow("Cost", usage.cost.formatAsCost())
                        inspectorRow("Input Tokens", "\(usage.inputTokens)")
                        inspectorRow("Output Tokens", "\(usage.outputTokens)")
                        inspectorRow("Cache Created", "\(usage.cacheCreationTokens)")
                        inspectorRow("Cache Read", "\(usage.cacheReadTokens)")
                        inspectorRow("Total Tokens", "\(usage.totalTokens)")
                        inspectorRow("Started", usage.startTime.formatted())
                        inspectorRow("Ended", usage.endTime.formatted())
                        inspectorRow("Duration", usage.formattedDuration)
                    }

                case .provider(let provider):
                    if let summary = snapshot.providerSummaries.first(where: { $0.provider == provider }) {
                        inspectorRow("Provider", summary.provider.displayName)
                        inspectorRow("Sessions", "\(summary.sessionCount)")
                        inspectorRow("Total Cost", summary.totalCost.formatAsCost())
                        inspectorRow("Total Tokens", "\(summary.totalTokens)")
                        inspectorRow("Input Tokens", "\(summary.totalInputTokens)")
                        inspectorRow("Output Tokens", "\(summary.totalOutputTokens)")

                        Divider().foregroundStyle(DesignSystem.Colors.borderSubtle)

                        Text("Models")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textMuted)

                        ForEach(summary.modelBreakdown, id: \.modelName) { model in
                            HStack {
                                Text(model.modelName)
                                    .font(DesignSystem.Typography.caption)
                                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                                Spacer()
                                Text(model.cost.formatAsCost())
                                    .font(DesignSystem.Typography.monoSmall)
                                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                            }
                        }
                    }

                case .model(let modelName):
                    if let summary = snapshot.modelSummaries.first(where: { $0.modelName == modelName }) {
                        inspectorRow("Model", summary.displayName)
                        inspectorRow("Sessions", "\(summary.sessionCount)")
                        inspectorRow("Total Cost", summary.totalCost.formatAsCost())
                        inspectorRow("Total Tokens", "\(summary.totalTokens)")
                    }

                case .projectionJob(let id):
                    if let job = snapshot.projectionJobs.first(where: { $0.id == id }) {
                        inspectorRow("Job Type", job.jobType.rawValue)
                        inspectorRow("Status", job.status.rawValue)
                        inspectorRow("Source Kind", job.sourceKind?.rawValue ?? "-")
                        inspectorRow("Source ID", job.sourceID ?? "-")
                        inspectorRow("Attempts", "\(job.attempts)/\(job.maxAttempts)")
                        inspectorRow("Priority", "\(job.priority)")
                        inspectorRow("Scheduled", job.scheduledAt.formatted())
                        if let started = job.startedAt {
                            inspectorRow("Started", started.formatted())
                        }
                        if let completed = job.completedAt {
                            inspectorRow("Completed", completed.formatted())
                        }
                        if let err = job.lastErrorMessage {
                            inspectorRow("Error", err)
                        }
                    }

                case .auditEvent(let id):
                    if let event = snapshot.auditEvents.first(where: { $0.id == id }) {
                        inspectorRow("Action", event.action.rawValue)
                        inspectorRow("Workspace", event.workspaceID)
                        inspectorRow("Team", event.teamID)
                        if let actor = event.actorUserID {
                            inspectorRow("Actor", actor)
                        }
                        if let role = event.actorRole {
                            inspectorRow("Role", role.rawValue)
                        }
                        inspectorRow("Occurred", event.occurredAt.formatted())
                    }

                case .retrievalSubsystem(let subsystem):
                    if let health = snapshot.retrievalHealth.first(where: { $0.subsystem == subsystem }) {
                        inspectorRow("Subsystem", health.subsystem.rawValue)
                        inspectorRow("Status", health.status.rawValue)
                        if let err = health.errorCode {
                            inspectorRow("Error Code", err)
                        }
                        if let msg = health.errorMessage {
                            inspectorRow("Error", msg)
                        }
                        inspectorRow("Observed", health.observedAt.formatted())
                    }

                case .conversation, .artifact:
                    Text("Detail not available")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
        .background(DesignSystem.Colors.surface.opacity(0.8))
    }

    // MARK: - Helpers

    private var filteredSessions: [TokenUsage] {
        var result = dataStore.usages

        if let provider = filter.providerFilter {
            result = result.filter { $0.provider == provider }
        }
        if let project = filter.projectFilter, !project.isEmpty {
            result = result.filter { $0.projectName == project }
        }
        if !filter.searchQuery.isEmpty {
            let q = filter.searchQuery.lowercased()
            result = result.filter {
                $0.model.lowercased().contains(q)
                || $0.provider.displayName.lowercased().contains(q)
                || $0.projectName.lowercased().contains(q)
            }
        }

        return result.sorted { $0.startTime > $1.startTime }
    }

    private func bandMetric(label: String, value: String, color: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Text(value)
                .font(DesignSystem.Typography.monoSmall)
                .foregroundStyle(color ?? DesignSystem.Colors.textPrimary)
        }
    }

    private func inspectorRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .textSelection(.enabled)
            Spacer()
        }
    }

    @ViewBuilder
    private func tableHeader(_ title: String, width: CGFloat?) -> some View {
        let header = Text(title)
            .font(DesignSystem.Typography.tiny)
            .foregroundStyle(DesignSystem.Colors.textMuted)
            .textCase(.uppercase)

        if let width {
            header.frame(width: width, alignment: .leading)
        } else {
            header.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func emptyLabel(_ text: String) -> some View {
        Text(text)
            .font(DesignSystem.Typography.caption)
            .foregroundStyle(DesignSystem.Colors.textMuted)
            .padding(.vertical, DesignSystem.Spacing.sm)
    }

    private func unavailableLabel(_ text: String) -> some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "lock.fill")
                .font(.system(size: 11))
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Text(text)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
        .padding(.vertical, DesignSystem.Spacing.sm)
    }

    private var indexingDisabledState: some View {
        VStack(spacing: DesignSystem.Spacing.lg) {
            Image(systemName: "cylinder.split.1x2")
                .font(.system(size: 48))
                .foregroundStyle(DesignSystem.Colors.textMuted)

            Text("Indexing is disabled")
                .font(DesignSystem.Typography.title)
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            Text("Enable conversation indexing to populate the Database workspace with search, coverage, and system data.")
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            Button {
                settingsManager.conversationIndexingEnabled = true
            } label: {
                Text("Enable Indexing")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, DesignSystem.Spacing.lg)
                    .padding(.vertical, DesignSystem.Spacing.sm)
                    .background(Capsule().fill(DesignSystem.Colors.blaze))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DesignSystem.Spacing.xxxl)
    }

    private func jobStatusColor(_ status: ProjectionJobStatus) -> Color {
        switch status {
        case .completed: return DesignSystem.Colors.success
        case .running, .leased: return DesignSystem.Colors.amber
        case .queued: return DesignSystem.Colors.textMuted
        case .failed: return DesignSystem.Colors.error
        case .canceled: return DesignSystem.Colors.textMuted
        }
    }

    private func healthStatusColor(_ status: RetrievalHealthStatus) -> Color {
        switch status {
        case .healthy: return DesignSystem.Colors.success
        case .degraded: return DesignSystem.Colors.warning
        case .failed: return DesignSystem.Colors.error
        }
    }

    private func auditActionIcon(_ action: SharedArtifactAuditAction) -> String {
        switch action {
        case .create: return "plus.circle"
        case .update: return "pencil.circle"
        case .share: return "person.2"
        case .permissionChange: return "lock.rotation"
        case .rebuild: return "arrow.clockwise"
        case .conflictDetected: return "exclamationmark.triangle"
        case .conflictResolved: return "checkmark.circle"
        }
    }
}

// MARK: - Wide Band

private struct WideBand<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Text(title)
                .font(DesignSystem.Typography.headline)
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignSystem.Spacing.lg)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(DesignSystem.Colors.surface.opacity(0.45))
            }
        }
        .clipShape(.rect(cornerRadius: DesignSystem.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.08), DesignSystem.Colors.border.opacity(0.3)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )
        )
    }
}

// MARK: - Bar Fill

private struct BarFill: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(DesignSystem.Colors.borderSubtle)
                    .frame(height: 6)

                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: max(2, geo.size.width * CGFloat(min(fraction, 1))), height: 6)
            }
        }
        .frame(height: 6)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Story Reveal Modifier

private struct StoryRevealModifier: ViewModifier {
    let appeared: Bool
    let delay: Double

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 12)
            .animation(DesignSystem.Animation.standard.delay(delay), value: appeared)
    }
}

extension View {
    fileprivate func storyReveal(appeared: Bool, delay: Double) -> some View {
        modifier(StoryRevealModifier(appeared: appeared, delay: delay))
    }
}
