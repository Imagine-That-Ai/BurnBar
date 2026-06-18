import SwiftUI

// MARK: - Database Workspace View

// Inspector panel.
// Extracted from DatabaseWorkspaceView.swift (god-type decomposition) — same module, same isolation, verbatim.

extension DatabaseWorkspaceView {

    @ViewBuilder
    func inspectorPanel(for sel: DatabaseWorkspaceSelection) -> some View {
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
                    Group {
                        if let document = indexedDocumentDetailCache[id] {
                            let chunks = indexedChunksCache[document.id] ?? []
                        let embeddedChunkCount: Int? = nil

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
                        case .code:
                            Divider().foregroundStyle(DesignSystem.Colors.borderSubtle)
                            inspectorSectionTitle("Code")
                            inspectorRow("Source ID", document.sourceID)
                            inspectorRow("Version", document.sourceVersionID.isEmpty ? "-" : document.sourceVersionID)
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
                        } else if let indexedDetailError {
                            inspectorRow("Error", indexedDetailError)
                        } else {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    .task(id: id) {
                        await loadIndexedDocumentDetail(id: id)
                    }

                case .conversation(let id):
                    Group {
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
                        } else if let conversationDetailError {
                            inspectorRow("Error", conversationDetailError)
                        } else {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    .task(id: id) {
                        await loadConversationDetail(id: id)
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

                        let permissionCount = snapshot.permissions.filter { $0.sourceArtifactID == id }.count
                        if permissionCount > 0 {
                            inspectorRow("Permissions", "\(permissionCount)")
                        }

                        let auditCount = snapshot.auditEvents.filter { $0.sourceArtifactID == id }.count
                        if auditCount > 0 {
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
}
