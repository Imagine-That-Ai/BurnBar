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
    @State private var atlasRows: [AtlasCorpusRow] = []
    @State private var atlasLoading = false
    @State private var atlasError: String?
    /// When the query planner detects aggregate intent, show full substring counts over stored transcripts (not top‑K retrieval).
    @State private var atlasAggregateSummary: String?

    private var showInspector: Bool {
        selection != nil && (mode == .atlas || mode == .system)
    }

    var body: some View {
        HStack(spacing: 0) {
            mainContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showInspector, let sel = selection {
                Divider()
                inspectorPanel(for: sel)
                    .frame(width: 380)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(DesignSystem.Animation.standard, value: showInspector)
        .background(Color.clear)
        .task { await runRefreshLoop() }
        .task(id: atlasRefreshKey) { await refreshAtlasRowsIfNeeded() }
        .onChange(of: dataStore.usages.count) { _, _ in Task { @MainActor in await rebuildSnapshot() } }
        .onChange(of: dataStore.lastRefresh) { _, _ in Task { @MainActor in await rebuildSnapshot() } }
        .onChange(of: settingsManager.conversationIndexingEnabled) { _, _ in Task { @MainActor in await rebuildSnapshot() } }
        .onChange(of: settingsManager.preferredIndexEmbeddingVersionID) { _, _ in
            Task { @MainActor in await rebuildSnapshot() }
            Task { await refreshAtlasRowsIfNeeded() }
        }
        .onChange(of: accountManager.isSignedIn) { _, _ in Task { @MainActor in await rebuildSnapshot() } }
    }

    @MainActor
    private func rebuildSnapshot() async {
        snapshot = await DatabaseWorkspaceSnapshotBuilder.build(
            from: dataStore,
            settingsManager: settingsManager,
            accountManager: accountManager,
            cloudSyncService: cloudSyncService
        )
    }

    @MainActor
    private func runRefreshLoop() async {
        await rebuildSnapshot()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(8))
            guard Task.isCancelled == false else { break }
            await rebuildSnapshot()
        }
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
                        .fill(statusDotColor)
                        .frame(width: 6, height: 6)

                    Text(statusLabel)
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

                    TextField("Search conversations, skills, and agent docs...", text: $filter.searchQuery)
                        .textFieldStyle(.plain)
                        .font(DesignSystem.Typography.body)
                        .frame(minWidth: 120, idealWidth: 260, maxWidth: 260)
                }
                .padding(.horizontal, DesignSystem.Spacing.md)
                .padding(.vertical, DesignSystem.Spacing.xs)
                .background(
                    Capsule().fill(DesignSystem.Colors.surfaceElevated.opacity(0.6))
                )
                .overlay(
                    Capsule().stroke(DesignSystem.Colors.borderSubtle, lineWidth: 0.5)
                )
                .layoutPriority(-1)
            }

            if snapshot.indexingEnabled {
                indexStatusPill
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
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
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
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
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(1)
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

    private var statusDotColor: Color {
        if snapshot.loadIssues.isEmpty == false {
            return DesignSystem.Colors.warning
        }
        if indexingInProgress {
            return DesignSystem.Colors.amber
        }
        if snapshot.retrievalSystemHealth.degradedModes.isEmpty == false {
            return DesignSystem.Colors.warning
        }
        return snapshot.indexingEnabled ? DesignSystem.Colors.success : DesignSystem.Colors.textMuted
    }

    private var statusLabel: String {
        if snapshot.loadIssues.isEmpty == false {
            return "Partial data • \(freshnessLabel)"
        }
        if snapshot.indexingEnabled && indexingInProgress {
            let queueDepth = snapshot.retrievalSystemHealth.projectionQueue.queueDepth
            let queueLabel = queueDepth > 0 ? " • \(queueDepth) queued" : ""
            return "Indexing \(Int(sourceCoverageFraction * 100))%\(queueLabel) • \(freshnessLabel)"
        }
        if snapshot.indexingEnabled && snapshot.retrievalSystemHealth.degradedModes.isEmpty == false {
            return "Index degraded • \(freshnessLabel)"
        }
        if snapshot.indexingEnabled {
            return "Index ready • \(freshnessLabel)"
        }
        return freshnessLabel
    }

    private var indexStatusPill: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Text("Health")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .lineLimit(1)

                Text(indexStatusTitle)
                    .font(DesignSystem.Typography.monoTiny)
                    .foregroundStyle(statusDotColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, DesignSystem.Spacing.xs)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(statusDotColor.opacity(0.12))
                    )
            }
            .fixedSize(horizontal: true, vertical: false)

            HStack(alignment: .center, spacing: DesignSystem.Spacing.sm) {
                ProgressView(value: sourceCoverageFraction)
                    .progressViewStyle(.linear)
                    .frame(width: 132, height: 6)
                    .fixedSize(horizontal: true, vertical: false)

                Text("Coverage \(indexStatusValue)")
                    .font(DesignSystem.Typography.monoSmall)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.xl, style: .continuous)
                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.xl, style: .continuous)
                .stroke(DesignSystem.Colors.borderSubtle, lineWidth: 0.5)
        )
    }

    // MARK: - Story Mode

    @ViewBuilder
    private var storyContent: some View {
        if !snapshot.indexingEnabled && snapshot.indexedDocuments == 0 {
            indexingDisabledState
        } else {
            if snapshot.loadIssues.isEmpty == false {
                partialDataBand
                    .storyReveal(appeared: appeared, delay: 0)
            }
            storyCorpusBand
                .storyReveal(appeared: appeared, delay: 0.04)
            storyActivityBand
                .storyReveal(appeared: appeared, delay: 0.10)
            storySearchCoverageBand
                .storyReveal(appeared: appeared, delay: 0.16)
            storyRecentSessionsBand
                .storyReveal(appeared: appeared, delay: 0.22)
            storyDevicesBand
                .storyReveal(appeared: appeared, delay: 0.28)
            storySharedBand
                .storyReveal(appeared: appeared, delay: 0.34)
            storySystemTrustBand
                .storyReveal(appeared: appeared, delay: 0.40)
        }
    }

    private var storyCorpusBand: some View {
        WideBand(title: "Corpus") {
            HStack(spacing: DesignSystem.Spacing.xxl) {
                bandMetric(label: "Sessions", value: "\(snapshot.totalSessions)")
                bandMetric(label: "Conversations", value: metricValue(snapshot.totalConversations, for: .totalConversations))
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
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                HStack(spacing: DesignSystem.Spacing.xxl) {
                    bandMetric(label: "Indexed Documents", value: metricValue(snapshot.indexedDocuments, for: .indexedDocuments))
                    bandMetric(label: "Indexed Chunks", value: metricValue(snapshot.indexedChunks, for: .indexedChunks))
                    bandMetric(label: "Source Artifacts", value: metricValue(snapshot.sourceArtifacts, for: .sourceArtifacts))
                    bandMetric(label: "Embedding Models", value: metricValue(snapshot.embeddingModels, for: .embeddingModels))
                    bandMetric(label: "Embedded Chunks", value: metricValue(snapshot.embeddedChunks, for: .embeddedChunks))

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Indexing")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                        HStack(spacing: DesignSystem.Spacing.xs) {
                            Circle()
                                .fill(statusDotColor)
                                .frame(width: 6, height: 6)
                            Text(indexStatusTitle)
                                .font(DesignSystem.Typography.monoSmall)
                                .foregroundStyle(statusDotColor)
                        }
                    }
                }

                indexProgressRow(
                    label: "Source Coverage",
                    fraction: sourceCoverageFraction,
                    detail: "\(snapshot.indexedDocuments) of \(max(indexableSourceCount, snapshot.indexedDocuments)) searchable records are projected."
                )

                indexProgressRow(
                    label: "Semantic Coverage",
                    fraction: semanticCoverageFraction,
                    detail: "\(snapshot.embeddedChunks) of \(max(snapshot.indexedChunks, snapshot.embeddedChunks)) chunks have embeddings."
                )

                if let semanticVersion = semanticEmbeddingVersion,
                   let semanticModel = embeddingModel(for: semanticVersion) {
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        Text("Current Index")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                        Text(embeddingDisplayName(model: semanticModel, version: semanticVersion))
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
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

    @State private var deviceSummaries: [DeviceUsageSummary] = []

    private var storyDevicesBand: some View {
        WideBand(title: "Devices") {
            if deviceSummaries.isEmpty {
                unavailableLabel("No device data yet. Sign in and sync to see cross-device usage.")
            } else {
                HStack(spacing: DesignSystem.Spacing.xxl) {
                    bandMetric(label: "Devices", value: "\(deviceSummaries.count)")
                    ForEach(deviceSummaries) { device in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: DesignSystem.Spacing.xxs) {
                                Image(systemName: device.sfSymbolName)
                                    .font(.system(size: 9))
                                    .foregroundStyle(device.isLocal ? DesignSystem.Colors.teal : DesignSystem.Colors.purple)
                                Text(device.deviceName)
                                    .font(DesignSystem.Typography.tiny)
                                    .foregroundStyle(DesignSystem.Colors.textMuted)
                                    .lineLimit(1)
                            }
                            Text(device.totalCost.formatAsCost())
                                .font(DesignSystem.Typography.monoSmall)
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                        }
                    }
                    Spacer()
                }
            }
        }
        .onAppear { deviceSummaries = (try? dataStore.deviceUsageSummaries()) ?? [] }
    }

    private var storySharedBand: some View {
        WideBand(title: "Shared Artifacts") {
            if accountManager.isSignedIn {
                HStack(spacing: DesignSystem.Spacing.xxl) {
                    bandMetric(label: "Shared Artifacts", value: metricValue(snapshot.sharedArtifactCount, for: .sharedArtifacts))
                    bandMetric(label: "Permissions", value: metricValue(snapshot.permissionCount, for: .permissions))
                    bandMetric(label: "Audit Events", value: metricValue(snapshot.auditEventCount, for: .auditEvents))
                    bandMetric(label: "Synced", value: metricValue(snapshot.syncedArtifactCount, for: .sharedArtifacts))
                    bandMetric(label: "Pending", value: metricValue(snapshot.pendingArtifactCount, for: .sharedArtifacts))

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

                bandMetric(
                    label: "Active Jobs",
                    value: metricValue(snapshot.projectionJobCounts.active, for: .projectionJobs)
                )
                bandMetric(
                    label: "Queued",
                    value: metricValue(snapshot.projectionJobCounts.queued, for: .projectionJobs)
                )
                bandMetric(
                    label: "Failed Jobs",
                    value: metricValue(snapshot.projectionJobCounts.failed, for: .projectionJobs),
                    color: snapshot.projectionJobCounts.failed > 0 ? DesignSystem.Colors.error : nil
                )

                Spacer()
            }
        }
    }

    // MARK: - Atlas Mode

    @State private var showAtlasCostMix = false

    @ViewBuilder
    private var atlasContent: some View {
        if !snapshot.indexingEnabled && snapshot.indexedDocuments == 0 {
            indexingDisabledState
        } else {
            if snapshot.loadIssues.isEmpty == false {
                partialDataBand
            }
            atlasCompactToolbar
            if showAtlasCostMix {
                atlasProviderChartBand
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            atlasDenseTable
        }
    }

    /// Compact inline toolbar replacing the old full-width filter band.
    /// Filters + summary on one line, cost mix toggle on the right.
    private var atlasCompactToolbar: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                atlasFilterMenu(
                    title: "Provider",
                    value: filter.providerFilter?.displayName ?? "All"
                ) {
                    Button("All Providers") { filter.providerFilter = nil }
                    ForEach(snapshot.activeProviders, id: \.self) { provider in
                        Button {
                            filter.providerFilter = provider
                        } label: {
                            HStack {
                                ProviderLogoView(provider: provider, size: 16, useFallbackColor: true)
                                Text(provider.displayName)
                            }
                        }
                    }
                }

                atlasFilterMenu(
                    title: "Source",
                    value: filter.sourceKindFilter?.databaseDisplayName ?? "All"
                ) {
                    Button("All Sources") { filter.sourceKindFilter = nil }
                    ForEach(SearchSourceKind.allCases, id: \.self) { sourceKind in
                        Button(sourceKind.databaseDisplayName) { filter.sourceKindFilter = sourceKind }
                    }
                }

                atlasFilterMenu(
                    title: "Project",
                    value: filter.projectFilter ?? "All"
                ) {
                    Button("All Projects") { filter.projectFilter = nil }
                    ForEach(snapshot.projectNames, id: \.self) { projectName in
                        Button(projectName) { filter.projectFilter = projectName }
                    }
                }

                atlasFilterMenu(
                    title: "Window",
                    value: filter.timeWindow.displayName
                ) {
                    ForEach(TimeRange.allCases) { timeRange in
                        Button(timeRange.displayName) { filter.timeWindow = timeRange }
                    }
                }

                Spacer()

                if hasActiveFilters {
                    Button("Reset") {
                        filter = DatabaseWorkspaceFilterState()
                    }
                    .buttonStyle(.plain)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                }

                Button {
                    withAnimation(DesignSystem.Animation.standard) {
                        showAtlasCostMix.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chart.bar.fill")
                            .font(.system(size: 10))
                        Text("Cost Mix")
                            .font(DesignSystem.Typography.tiny)
                    }
                    .foregroundStyle(showAtlasCostMix ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textMuted)
                    .padding(.horizontal, DesignSystem.Spacing.sm)
                    .padding(.vertical, DesignSystem.Spacing.xs)
                    .background(
                        Capsule().fill(showAtlasCostMix ? DesignSystem.Colors.surfaceElevated : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: DesignSystem.Spacing.sm) {
                Text(atlasSummaryText)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)

                if let atlasAggregateSummary {
                    Text(atlasAggregateSummary)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .lineLimit(1)
                }

                if atlasLoading {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .background {
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(DesignSystem.Colors.surface.opacity(0.3))
        }
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .strokeBorder(DesignSystem.Colors.borderSubtle, lineWidth: 0.5)
        )
    }

    // atlasFilterBand replaced by atlasCompactToolbar above

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
        WideBand(title: filter.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Indexed Corpus" : "Search Results") {
            VStack(spacing: 0) {
                if let atlasError {
                    emptyLabel(atlasError)
                } else if atlasRows.isEmpty, atlasLoading {
                    emptyLabel("Loading indexed corpus...")
                } else if atlasRows.isEmpty {
                    emptyLabel("No indexed records match the current query and filters.")
                } else {
                    HStack(spacing: 0) {
                        tableHeader("Source", width: 96)
                        tableHeader("Title", width: nil)
                        tableHeader("Provider", width: 110)
                        tableHeader("Project", width: 120)
                        tableHeader("Updated", width: 140)
                    }
                    .padding(.bottom, DesignSystem.Spacing.xs)

                    Divider().foregroundStyle(DesignSystem.Colors.borderSubtle)

                    ForEach(atlasRows.prefix(80)) { row in
                        Button {
                            withAnimation(DesignSystem.Animation.standard) {
                                selection = row.selection
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                                HStack(spacing: 0) {
                                    Text(row.sourceKind.databaseDisplayName)
                                        .frame(width: 96, alignment: .leading)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(row.title)
                                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                                            .lineLimit(1)

                                        if row.preview.isEmpty == false {
                                            Text(row.preview)
                                                .font(DesignSystem.Typography.tiny)
                                                .foregroundStyle(DesignSystem.Colors.textMuted)
                                                .lineLimit(2)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                    Text(row.providerLabel)
                                        .frame(width: 110, alignment: .leading)

                                    Text(row.projectName ?? "—")
                                        .frame(width: 120, alignment: .leading)

                                    Text(row.displayDate.formatted(date: .abbreviated, time: .shortened))
                                        .frame(width: 140, alignment: .trailing)
                                }
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)

                                if row.subtitle?.isEmpty == false {
                                    Text(row.subtitle ?? "")
                                        .font(DesignSystem.Typography.tiny)
                                        .foregroundStyle(DesignSystem.Colors.textMuted)
                                        .lineLimit(1)
                                        .padding(.leading, 96)
                                }
                            }
                            .padding(.vertical, DesignSystem.Spacing.sm)
                            .background(
                                selection == row.selection
                                    ? DesignSystem.Colors.surfaceElevated.opacity(0.5)
                                    : Color.clear
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Divider().foregroundStyle(DesignSystem.Colors.borderSubtle.opacity(0.5))
                    }

                    if atlasRows.count > 80 {
                        Text("\(atlasRows.count - 80) more indexed records...")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .padding(.top, DesignSystem.Spacing.sm)
                    }
                }
            }
        }
    }

    // MARK: - System Mode

    @ViewBuilder
    private var systemContent: some View {
        if snapshot.loadIssues.isEmpty == false {
            partialDataBand
        }
        systemIndexingControlBand
        systemProjectionQueueBand
        systemRetrievalHealthBand
        systemAuditFeedBand
        systemSyncBand
    }

    private var systemIndexingControlBand: some View {
        WideBand(title: "Indexing Control") {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                HStack(spacing: DesignSystem.Spacing.xxl) {
                    bandMetric(
                        label: "Source Coverage",
                        value: "\(snapshot.indexedDocuments)/\(max(indexableSourceCount, snapshot.indexedDocuments))"
                    )
                    bandMetric(
                        label: "Semantic Coverage",
                        value: "\(snapshot.embeddedChunks)/\(max(snapshot.indexedChunks, snapshot.embeddedChunks))"
                    )
                    bandMetric(
                        label: "Queue Depth",
                        value: "\(snapshot.retrievalSystemHealth.projectionQueue.queueDepth)"
                    )
                    bandMetric(
                        label: "Failed Jobs",
                        value: "\(snapshot.retrievalSystemHealth.projectionQueue.failedJobs)",
                        color: snapshot.retrievalSystemHealth.projectionQueue.failedJobs > 0 ? DesignSystem.Colors.error : nil
                    )
                    Spacer()
                }

                indexProgressRow(
                    label: "Projection",
                    fraction: sourceCoverageFraction,
                    detail: indexingInProgress
                        ? "Projection queue is active. New sources are still being indexed."
                        : "Projected coverage is current for the records OpenBurnBar knows about."
                )

                indexProgressRow(
                    label: "Embeddings",
                    fraction: semanticCoverageFraction,
                    detail: snapshot.retrievalSystemHealth.semanticPipeline.indexedVectorCount > 0
                        ? "\(snapshot.retrievalSystemHealth.semanticPipeline.indexedVectorCount) vectors are available for semantic ranking."
                        : "Semantic retrieval is still waiting for chunk embeddings."
                )

                if snapshot.embeddingVersionRecords.isEmpty {
                    emptyLabel("The first indexing pass has not registered any embedding versions yet.")
                } else {
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        atlasFilterMenu(
                            title: "Index Version",
                            value: selectedEmbeddingVersionLabel
                        ) {
                            Button("Automatic (use active version)") {
                                settingsManager.preferredIndexEmbeddingVersionID = ""
                            }
                            ForEach(snapshot.embeddingVersionRecords) { version in
                                Button(embeddingVersionMenuLabel(version)) {
                                    settingsManager.preferredIndexEmbeddingVersionID = version.id
                                }
                            }
                        }

                        Spacer()
                    }

                    if let selectedVersion = selectedEmbeddingVersion,
                       let selectedModel = embeddingModel(for: selectedVersion) {
                        HStack(spacing: DesignSystem.Spacing.xs) {
                            Text("Selected Index")
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                            Text(embeddingDisplayName(model: selectedModel, version: selectedVersion))
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                        }
                    }

                    if let semanticVersion = semanticEmbeddingVersion,
                       let semanticModel = embeddingModel(for: semanticVersion) {
                        HStack(spacing: DesignSystem.Spacing.xs) {
                            Text("Running Now")
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                            Text(embeddingDisplayName(model: semanticModel, version: semanticVersion))
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                        }
                    }

                    if let selectionWarning {
                        HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(DesignSystem.Colors.warning)
                                .padding(.top, 2)
                            Text(selectionWarning)
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, DesignSystem.Spacing.md)
                        .padding(.vertical, DesignSystem.Spacing.sm)
                        .background(DesignSystem.Colors.warning.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
                    }
                }
            }
        }
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
                    bandMetric(label: "Synced", value: metricValue(snapshot.syncedArtifactCount, for: .sharedArtifacts), color: DesignSystem.Colors.success)
                    bandMetric(label: "Pending", value: metricValue(snapshot.pendingArtifactCount, for: .sharedArtifacts), color: snapshot.pendingArtifactCount > 0 ? DesignSystem.Colors.warning : nil)
                    bandMetric(label: "Conflicted", value: metricValue(snapshot.conflictedArtifactCount, for: .sharedArtifacts), color: snapshot.conflictedArtifactCount > 0 ? DesignSystem.Colors.error : nil)
                    bandMetric(label: "Failed", value: metricValue(snapshot.failedArtifactCount, for: .sharedArtifacts), color: snapshot.failedArtifactCount > 0 ? DesignSystem.Colors.error : nil)

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
                        if let payloadJSON = prettyPrintedJSON(job.payloadJSON) {
                            Divider().foregroundStyle(DesignSystem.Colors.borderSubtle)
                            inspectorTextBlock("Payload", payloadJSON)
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
                        if let details = prettyPrintedJSON(health.detailsJSON) {
                            Divider().foregroundStyle(DesignSystem.Colors.borderSubtle)
                            inspectorTextBlock("Details", details)
                        }
                    }

                case .indexedDocument(let id):
                    if let document = indexedDocumentDetail(id: id) {
                        let chunks = indexedChunks(documentID: document.id)
                        let embeddedChunkCount = selectedEmbeddingVersion.flatMap {
                            do {
                                return try dataStore.countChunkEmbeddings(
                                    documentID: document.id,
                                    embeddingVersionID: $0.id
                                )
                            } catch {
                                AppLogger.dataStore.silentFailure("countChunkEmbeddings", error: error)
                                return nil
                            }
                        }

                        inspectorSectionTitle("Index Record")
                        inspectorRow("Document ID", document.id)
                        inspectorRow("Kind", document.sourceKind.databaseDisplayName)
                        inspectorRow("Source ID", document.sourceID)
                        inspectorRow("Provider", document.provider ?? "—")
                        inspectorRow("Project", document.projectName ?? "—")
                        inspectorRow("Title", document.title)
                        if let subtitle = document.subtitle, subtitle.isEmpty == false {
                            inspectorRow("Subtitle", subtitle)
                        }
                        inspectorRow("Source Version", document.sourceVersionID)
                        if let contentHash = document.contentHash {
                            inspectorRow("Content Hash", contentHash)
                        }
                        inspectorRow("Indexed", document.indexedAt.formatted())
                        inspectorRow("Updated", document.updatedAt.formatted())
                        if let sourceUpdatedAt = document.sourceUpdatedAt {
                            inspectorRow("Source Updated", sourceUpdatedAt.formatted())
                        }
                        inspectorRow("Chunk Count", "\(chunks.count)")
                        if let embeddedChunkCount {
                            inspectorRow("Embedded Chunks", "\(embeddedChunkCount)/\(max(chunks.count, embeddedChunkCount))")
                        }
                        if let version = selectedEmbeddingVersion,
                           let model = embeddingModel(for: version) {
                            inspectorRow("Embedding", embeddingDisplayName(model: model, version: version))
                        }

                        if let bodyPreview = document.bodyPreview, bodyPreview.isEmpty == false {
                            Divider().foregroundStyle(DesignSystem.Colors.borderSubtle)
                            inspectorTextBlock("Search Preview", bodyPreview)
                        }

                        switch document.sourceKind {
                        case .conversation:
                            if let conversation = conversationDetail(id: document.sourceID) {
                                Divider().foregroundStyle(DesignSystem.Colors.borderSubtle)
                                inspectorSectionTitle("Conversation")
                                inspectorRow("Source", conversation.sourceType.rawValue)
                                inspectorRow("Session", conversation.sessionId)
                                inspectorRow("Messages", "\(conversation.messageCount)")
                                inspectorRow("User Words", "\(conversation.userWordCount)")
                                inspectorRow("Assistant Words", "\(conversation.assistantWordCount)")
                                if let start = conversation.startTime {
                                    inspectorRow("Started", start.formatted())
                                }
                                if let end = conversation.endTime {
                                    inspectorRow("Ended", end.formatted())
                                }
                                if let summary = conversation.summary, summary.isEmpty == false {
                                    Divider().foregroundStyle(DesignSystem.Colors.borderSubtle)
                                    inspectorTextBlock("Summary", summary)
                                }
                                if conversation.fullText.isEmpty == false {
                                    Divider().foregroundStyle(DesignSystem.Colors.borderSubtle)
                                    inspectorTextBlock("Full Conversation", conversation.fullText)
                                }
                            }
                        case .skillDoc, .agentDoc, .sharedArtifact:
                            if let artifact = sourceArtifactDetail(id: document.sourceID) {
                                Divider().foregroundStyle(DesignSystem.Colors.borderSubtle)
                                inspectorSectionTitle("Artifact")
                                inspectorRow("Path", artifact.relativePath)
                                inspectorRow("Root", artifact.rootPath)
                                inspectorRow("Status", artifact.status.rawValue)
                                inspectorRow("Provenance", artifact.provenance)
                                inspectorRow("Size", ByteCountFormatter.string(fromByteCount: Int64(artifact.fileSizeBytes), countStyle: .file))
                                if let modifiedAt = artifact.fileModifiedAt {
                                    inspectorRow("Modified", modifiedAt.formatted())
                                }
                                if artifact.body.isEmpty == false {
                                    Divider().foregroundStyle(DesignSystem.Colors.borderSubtle)
                                    inspectorTextBlock("Full Body", artifact.body)
                                }
                            }
                        }

                        if chunks.isEmpty == false {
                            Divider().foregroundStyle(DesignSystem.Colors.borderSubtle)
                            inspectorSectionTitle("Indexed Chunks")
                            let displayedChunks = Array(chunks.prefix(12))
                            ForEach(displayedChunks, id: \.id) { chunk in
                                inspectorChunkRow(chunk, embeddingVersionID: selectedEmbeddingVersion?.id)
                                if chunk.id != displayedChunks.last?.id {
                                    Divider().foregroundStyle(DesignSystem.Colors.borderSubtle.opacity(0.4))
                                }
                            }
                        }
                    }

                case .conversation(let id):
                    if let conversation = conversationDetail(id: id) {
                        inspectorRow("Source", conversation.sourceType.rawValue)
                        inspectorRow("Provider", conversation.provider.displayName)
                        inspectorRow("Project", conversation.projectName)
                        inspectorRow("Session", conversation.sessionId)
                        inspectorRow("Title", conversation.inferredTaskTitle)
                        inspectorRow("Messages", "\(conversation.messageCount)")
                        inspectorRow("User Words", "\(conversation.userWordCount)")
                        inspectorRow("Assistant Words", "\(conversation.assistantWordCount)")
                        inspectorRow("Indexed", conversation.indexedAt.formatted())
                        if let start = conversation.startTime {
                            inspectorRow("Started", start.formatted())
                        }
                        if let end = conversation.endTime {
                            inspectorRow("Ended", end.formatted())
                        }
                        if let summary = conversation.summary, summary.isEmpty == false {
                            Divider().foregroundStyle(DesignSystem.Colors.borderSubtle)
                            inspectorTextBlock("Summary", summary)
                        }
                        if conversation.fullText.isEmpty == false {
                            Divider().foregroundStyle(DesignSystem.Colors.borderSubtle)
                            inspectorTextBlock("Transcript Preview", String(conversation.fullText.prefix(600)))
                        }
                    } else {
                        unavailableLabel("Conversation detail is no longer available.")
                    }

                case .artifact(let id):
                    if let artifact = sourceArtifactDetail(id: id) {
                        inspectorRow("Kind", artifact.sourceKind.databaseDisplayName)
                        inspectorRow("Title", artifact.title)
                        inspectorRow("Path", artifact.relativePath)
                        inspectorRow("Root", artifact.rootPath)
                        inspectorRow("Status", artifact.status.rawValue)
                        inspectorRow("Provenance", artifact.provenance)
                        inspectorRow("Size", ByteCountFormatter.string(fromByteCount: Int64(artifact.fileSizeBytes), countStyle: .file))
                        inspectorRow("Updated", artifact.updatedAt.formatted())
                        if let modifiedAt = artifact.fileModifiedAt {
                            inspectorRow("Modified", modifiedAt.formatted())
                        }

                        if let syncState = sharedArtifactSyncState(sourceArtifactID: id) {
                            Divider().foregroundStyle(DesignSystem.Colors.borderSubtle)
                            inspectorRow("Sync", syncState.syncStatus.rawValue)
                            inspectorRow("Workspace", syncState.workspaceID)
                            inspectorRow("Team", syncState.teamID)
                            inspectorRow("Revision", syncState.revisionID)
                        }

                        if let permissionCount = try? dataStore.countSharedArtifactPermissions(sourceArtifactID: id),
                           permissionCount > 0 {
                            inspectorRow("Permissions", "\(permissionCount)")
                        }

                        if let auditCount = try? dataStore.countSharedArtifactAuditEvents(sourceArtifactID: id),
                           auditCount > 0 {
                            inspectorRow("Audit Events", "\(auditCount)")
                        }

                        if artifact.body.isEmpty == false {
                            Divider().foregroundStyle(DesignSystem.Colors.borderSubtle)
                            inspectorTextBlock("Body Preview", String(artifact.body.prefix(600)))
                        }
                    } else {
                        unavailableLabel("Artifact detail is no longer available.")
                    }
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
        .background(DesignSystem.Colors.surface.opacity(0.8))
    }

    // MARK: - Helpers

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

    private func conversationDetail(id: String) -> ConversationRecord? {
        do {
            return try dataStore.fetchConversation(id: id)
        } catch {
            return nil
        }
    }

    private func sourceArtifactDetail(id: String) -> SourceArtifactRecord? {
        do {
            return try dataStore.fetchSourceArtifact(id: id)
        } catch {
            return nil
        }
    }

    private func indexedDocumentDetail(id: String) -> SearchDocumentRecord? {
        do {
            return try dataStore.fetchSearchDocument(id: id)
        } catch {
            return nil
        }
    }

    private func indexedChunks(documentID: String) -> [SearchChunkRecord] {
        (try? dataStore.fetchSearchChunks(documentID: documentID)) ?? []
    }

    private func sharedArtifactSyncState(sourceArtifactID: String) -> SharedArtifactSyncStateRecord? {
        do {
            return try dataStore.fetchSharedArtifactSyncState(sourceArtifactID: sourceArtifactID)
        } catch {
            return nil
        }
    }

    private func embeddingModel(for version: EmbeddingVersionRecord) -> EmbeddingModelRecord? {
        snapshot.embeddingModelRecords.first(where: { $0.id == version.modelID })
    }

    private var semanticEmbeddingVersion: EmbeddingVersionRecord? {
        guard let versionID = snapshot.retrievalSystemHealth.semanticPipeline.embeddingVersionID else { return nil }
        return snapshot.embeddingVersionRecords.first(where: { $0.id == versionID })
    }

    private var selectedEmbeddingVersion: EmbeddingVersionRecord? {
        if let preferredVersionID = settingsManager.preferredIndexEmbeddingVersionIDValue,
           let preferredVersion = snapshot.embeddingVersionRecords.first(where: { $0.id == preferredVersionID }) {
            return preferredVersion
        }
        return semanticEmbeddingVersion
            ?? snapshot.embeddingVersionRecords.first(where: \.isActive)
            ?? snapshot.embeddingVersionRecords.first
    }

    private var selectedEmbeddingVersionLabel: String {
        guard let version = selectedEmbeddingVersion else { return "Automatic" }
        return embeddingVersionShortLabel(version)
    }

    private var selectionWarning: String? {
        guard
            let selectedVersion = selectedEmbeddingVersion,
            let semanticVersionID = snapshot.retrievalSystemHealth.semanticPipeline.embeddingVersionID,
            selectedVersion.id != semanticVersionID
        else {
            return nil
        }

        return "The selected index version differs from the currently served semantic version. OpenBurnBar will prefer the selected version for new retrieval sessions, but queued or stale embeddings can still leave search in lexical fallback until re-embedding catches up."
    }

    private var indexableSourceCount: Int {
        snapshot.totalConversations + snapshot.sourceArtifacts
    }

    private var sourceCoverageFraction: Double {
        guard indexableSourceCount > 0 else {
            return snapshot.indexedDocuments > 0 ? 1 : 0
        }
        return min(1, Double(snapshot.indexedDocuments) / Double(indexableSourceCount))
    }

    private var semanticCoverageFraction: Double {
        guard snapshot.indexedChunks > 0 else {
            return snapshot.embeddedChunks > 0 ? 1 : 0
        }
        return min(1, Double(snapshot.embeddedChunks) / Double(snapshot.indexedChunks))
    }

    private var indexingInProgress: Bool {
        snapshot.retrievalSystemHealth.rebuild.inProgress
            || snapshot.projectionJobCounts.active > 0
            || snapshot.projectionJobCounts.queued > 0
    }

    private var indexStatusTitle: String {
        if indexingInProgress {
            return "Indexing"
        }
        if snapshot.retrievalSystemHealth.degradedModes.isEmpty == false {
            return "Degraded"
        }
        return "Ready"
    }

    private var indexStatusValue: String {
        if indexingInProgress {
            return "\(snapshot.indexedDocuments)/\(max(indexableSourceCount, snapshot.indexedDocuments))"
        }
        return "\(Int(sourceCoverageFraction * 100))%"
    }

    private func embeddingDisplayName(model: EmbeddingModelRecord, version: EmbeddingVersionRecord) -> String {
        "\(model.provider) / \(model.modelName) • \(version.versionTag)"
    }

    private func embeddingVersionShortLabel(_ version: EmbeddingVersionRecord) -> String {
        if let model = embeddingModel(for: version) {
            return "\(model.modelName) • \(version.versionTag)"
        }
        return version.versionTag
    }

    private func embeddingVersionMenuLabel(_ version: EmbeddingVersionRecord) -> String {
        if let model = embeddingModel(for: version) {
            return "\(model.provider) / \(model.modelName) • \(version.versionTag)"
        }
        return version.id
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

    private func inspectorSectionTitle(_ title: String) -> some View {
        Text(title)
            .font(DesignSystem.Typography.caption)
            .foregroundStyle(DesignSystem.Colors.textMuted)
            .textCase(.uppercase)
    }

    private func inspectorChunkRow(_ chunk: SearchChunkRecord, embeddingVersionID: String?) -> some View {
        let isEmbedded = embeddingVersionID.flatMap {
            try? dataStore.countChunkEmbeddings(chunkID: chunk.id, embeddingVersionID: $0)
        }.map { $0 > 0 } ?? false

        return VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            HStack(alignment: .center, spacing: DesignSystem.Spacing.sm) {
                Text("#\(chunk.ordinal)")
                    .font(DesignSystem.Typography.monoSmall)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                if let sectionPath = chunk.sectionPath, sectionPath.isEmpty == false {
                    Text(sectionPath)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }

                Spacer()

                Circle()
                    .fill(isEmbedded ? DesignSystem.Colors.success : DesignSystem.Colors.warning)
                    .frame(width: 6, height: 6)

                Text(isEmbedded ? "Embedded" : "Not embedded")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(isEmbedded ? DesignSystem.Colors.success : DesignSystem.Colors.warning)
            }

            Text(chunk.text)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: DesignSystem.Spacing.sm) {
                Text("Offsets \(chunk.startOffset)-\(chunk.endOffset)")
                if let start = chunk.messageStartOffset, let end = chunk.messageEndOffset {
                    Text("Msg \(start)-\(end)")
                }
            }
            .font(DesignSystem.Typography.tiny)
            .foregroundStyle(DesignSystem.Colors.textMuted)
        }
        .padding(.vertical, DesignSystem.Spacing.xs)
    }

    private func inspectorTextBlock(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Text(label)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Text(value)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func prettyPrintedJSON(_ json: String?) -> String? {
        guard
            let json,
            let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let prettyData = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
            let pretty = String(data: prettyData, encoding: .utf8)
        else {
            return json
        }
        return pretty
    }

    private func indexProgressRow(label: String, fraction: Double, detail: String) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            HStack {
                Text(label)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Spacer()
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(DesignSystem.Typography.monoSmall)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }

            ProgressView(value: max(0.0, min(1.0, fraction)))
                .progressViewStyle(.linear)

            Text(detail)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
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

    private func atlasFilterMenu<Content: View>(
        title: String,
        value: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Menu {
            content()
        } label: {
            HStack(spacing: DesignSystem.Spacing.xs) {
                Text(title)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                Text(value)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.xs)
            .background(Capsule().fill(DesignSystem.Colors.surfaceElevated.opacity(0.45)))
            .overlay(
                Capsule().stroke(DesignSystem.Colors.borderSubtle, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
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

    private var partialDataBand: some View {
        WideBand(title: "Partial Data") {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text("Some database metrics could not be loaded. Values marked unavailable are not trustworthy until the next successful refresh.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)

                ForEach(snapshot.loadIssues.prefix(6)) { issue in
                    HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                        Circle()
                            .fill(DesignSystem.Colors.warning)
                            .frame(width: 6, height: 6)
                            .padding(.top, 6)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(issue.context.replacingOccurrences(of: "_", with: " ").capitalized)
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                            Text(issue.message)
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private var atlasRefreshKey: AtlasRefreshKey {
        AtlasRefreshKey(
            mode: mode,
            filter: filter,
            contentVersion: snapshot.contentVersion
        )
    }

    private var hasActiveFilters: Bool {
        filter.providerFilter != nil
            || filter.sourceKindFilter != nil
            || filter.projectFilter != nil
            || filter.timeWindow != .allTime
            || filter.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private var atlasSummaryText: String {
        let trimmedQuery = filter.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmedQuery.isEmpty
            ? "Showing \(atlasRows.count) indexed records"
            : "Found \(atlasRows.count) matching records"

        var qualifiers: [String] = []
        if let provider = filter.providerFilter {
            qualifiers.append(provider.displayName)
        }
        if let sourceKind = filter.sourceKindFilter {
            qualifiers.append(sourceKind.databaseDisplayName)
        }
        if let projectFilter = filter.projectFilter, projectFilter.isEmpty == false {
            qualifiers.append(projectFilter)
        }
        if filter.timeWindow != .allTime {
            qualifiers.append(filter.timeWindow.displayName)
        }

        guard qualifiers.isEmpty == false else { return base }
        return ([base] + qualifiers).joined(separator: " • ")
    }

    private func metricValue(_ value: Int, for metric: DatabaseWorkspaceMetric) -> String {
        snapshot.unavailableMetrics.contains(metric) ? "Unavailable" : "\(value)"
    }

    private var atlasArtifactTypes: Set<SearchSourceKind>? {
        guard let sourceKind = filter.sourceKindFilter else { return nil }
        return [sourceKind]
    }

    private var atlasDateRange: ClosedRange<Date>? {
        filter.timeWindow.dateRange()
    }

    @MainActor
    private func refreshAtlasRowsIfNeeded() async {
        guard mode == .atlas else { return }
        atlasLoading = true
        atlasError = nil
        atlasAggregateSummary = nil

        let trimmedQuery = filter.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedQuery.isEmpty {
            do {
                let documents = try dataStore.fetchSearchDocuments(
                    limit: 120,
                    provider: filter.providerFilter,
                    projectName: filter.projectFilter,
                    sourceKinds: atlasArtifactTypes.map(Array.init),
                    dateRange: atlasDateRange
                )
                atlasRows = documents.map(AtlasCorpusRow.init(document:))
            } catch {
                atlasRows = []
                atlasError = "Unable to load indexed corpus: \(error.localizedDescription)"
            }
            atlasLoading = false
            return
        }

        let searchService = SearchService.makeConversationSearchService(
            dataStore: dataStore,
            settingsManager: settingsManager
        )
        let run = await searchService.runBurnBarQuery(
            RetrievalQuery(
                text: trimmedQuery,
                filters: RetrievalFilters(
                    provider: filter.providerFilter,
                    projectName: filter.projectFilter,
                    artifactTypes: atlasArtifactTypes,
                    dateRange: atlasDateRange
                ),
                lexicalCandidateLimit: 180,
                semanticCandidateLimit: 180,
                rerankCandidateLimit: 220,
                resultLimit: 120
            )
        )
        atlasRows = run.retrievalResults.map(AtlasCorpusRow.init(retrievalResult:))
        if let count = run.aggregateOccurrenceCount, run.plan.aggregatePatterns.isEmpty == false {
            atlasAggregateSummary =
                "Complete substring count over indexed transcripts (case-insensitive): \(count) — patterns: \(run.plan.aggregatePatterns.joined(separator: ", "))"
        }
        atlasLoading = false
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

private struct AtlasRefreshKey: Equatable {
    let mode: DatabaseWorkspaceMode
    let filter: DatabaseWorkspaceFilterState
    let contentVersion: String
}

private struct AtlasCorpusRow: Identifiable, Equatable {
    let id: String
    let sourceKind: SearchSourceKind
    let sourceID: String
    let providerLabel: String
    let projectName: String?
    let title: String
    let subtitle: String?
    let preview: String
    let displayDate: Date
    let indexedAt: Date
    let selection: DatabaseWorkspaceSelection

    init(retrievalResult: RetrievalResult) {
        id = retrievalResult.id
        sourceKind = retrievalResult.sourceKind
        sourceID = retrievalResult.sourceID
        providerLabel = retrievalResult.provider?.displayName
            ?? retrievalResult.providerRawValue
            ?? "—"
        projectName = retrievalResult.projectName
        title = retrievalResult.title
        subtitle = AtlasCorpusRow.cleanText(retrievalResult.subtitle)
        preview = AtlasCorpusRow.cleanText(retrievalResult.snippet)
        displayDate = retrievalResult.sourceUpdatedAt ?? retrievalResult.indexedAt
        indexedAt = retrievalResult.indexedAt
        selection = .indexedDocument(retrievalResult.documentID)
    }

    init(document: SearchDocumentRecord) {
        id = document.id
        sourceKind = document.sourceKind
        sourceID = document.sourceID
        providerLabel = document.provider.flatMap(AgentProvider.init(rawValue:))?.displayName
            ?? document.provider
            ?? "—"
        projectName = document.projectName
        title = document.title
        subtitle = AtlasCorpusRow.cleanText(document.subtitle)
        preview = AtlasCorpusRow.cleanText(document.bodyPreview)
        displayDate = document.sourceUpdatedAt ?? document.indexedAt
        indexedAt = document.indexedAt
        selection = .indexedDocument(document.id)
    }

    private static func cleanText(_ value: String?) -> String {
        guard let value else { return "" }
        return value
            .replacingOccurrences(of: "<b>", with: "")
            .replacingOccurrences(of: "</b>", with: "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension SearchSourceKind {
    var databaseDisplayName: String {
        switch self {
        case .conversation:
            return "Conversation"
        case .skillDoc:
            return "Skill"
        case .agentDoc:
            return "Agent Doc"
        case .sharedArtifact:
            return "Shared"
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
