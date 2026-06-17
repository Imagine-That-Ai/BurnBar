import SwiftUI

// MARK: - Database Workspace View

// Story mode view.
// Extracted from DatabaseWorkspaceView.swift (god-type decomposition) — same module, same isolation, verbatim.

extension DatabaseWorkspaceView {

    @ViewBuilder
    var storyContent: some View {
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

    var storyCorpusBand: some View {
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

    var storyActivityBand: some View {
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

    var storySearchCoverageBand: some View {
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

    var storyRecentSessionsBand: some View {
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

    var storyDevicesBand: some View {
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
        .task { deviceSummaries = (try? await dataStore.deviceUsageSummaries()) ?? [] }
    }

    var storySharedBand: some View {
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

    var storySystemTrustBand: some View {
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
}
