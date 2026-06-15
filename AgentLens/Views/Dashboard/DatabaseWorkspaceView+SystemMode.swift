import SwiftUI

// MARK: - Database Workspace View

// System mode view.
// Extracted from DatabaseWorkspaceView.swift (god-type decomposition) — same module, same isolation, verbatim.

extension DatabaseWorkspaceView {

    @ViewBuilder
    var systemContent: some View {
        if snapshot.loadIssues.isEmpty == false {
            partialDataBand
        }
        systemIndexingControlBand
        systemProjectionQueueBand
        systemRetrievalHealthBand
        systemAuditFeedBand
        systemSyncBand
    }

    var systemIndexingControlBand: some View {
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

    var systemProjectionQueueBand: some View {
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

    var systemRetrievalHealthBand: some View {
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

    var systemAuditFeedBand: some View {
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

    var systemSyncBand: some View {
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
}
