import AppKit
import SwiftUI
import OpenBurnBarCore

extension SessionLogsView {
    // MARK: - Detail Pane

    @ViewBuilder
    var detailPane: some View {
        if let log = selectedLog {
            SessionLogDetailPane(
                record: log,
                dataStore: dataStore,
                operatingLayer: operatingLayer,
                overrideBody: dataSource == .cloud ? cloudBodyCache[log.sessionId] : nil,
                jumpTarget: jumpTarget?.conversation.id == log.id ? jumpTarget : nil,
                dominantModelKey: sessionModelMap[log.id],
                preferredChatModelKey: preferredChatModelKey
            )
            .id(log.id)
        } else {
            VStack(spacing: DesignSystem.Spacing.lg) {
                Spacer()
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 48))
                    .foregroundStyle(DesignSystem.Colors.textMuted.opacity(0.4))
                Text("Select a session log")
                    .font(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("Pick any log from the list to preview its full Markdown.")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - View Events

    func initializeSessionLogs() async {
        knownDevices = (try? await dataStore.fetchDevices()) ?? []
        await loadLogs()
        applyJumpTargetIfNeeded(jumpTarget)
    }

    func handleSearchTextChange() {
        Task {
            if dataSource == .cloud {
                await loadLogs()
            } else {
                await runLocalRetrievalSearchIfNeeded()
            }
        }
    }

    func handleSourceFilterChange() {
        sectionDisplayLimits = [:]
        expandedSections = Set(logGroups.prefix(1).map(\.id))
        selectedId = nil
        cloudBodyCache = [:]
        Task {
            await runLocalRetrievalSearchIfNeeded()
            reconcileSelectionWithFilteredLogs()
            await loadLogs()
        }
    }

    func handleGroupModeChange() {
        sectionDisplayLimits = [:]
        expandedSections = Set(logGroups.prefix(1).map(\.id))
    }

    func handleDataSourceChange() {
        selectedId = nil
        cloudBodyCache = [:]
        Task { await loadLogs() }
    }

    func handleConversationIndexingChange() {
        refreshRetrievalHealth()
        Task { await runLocalRetrievalSearchIfNeeded() }
    }

    func handleEmbeddingVersionChange() {
        Task { @MainActor in
            retrievalSearchService = await SearchService.makeConversationSearchServiceUsingStoredEmbeddings(
                dataStore: dataStore,
                settingsManager: settingsManager
            )
            refreshRetrievalHealth()
            await runLocalRetrievalSearchIfNeeded()
        }
    }

    // MARK: - Export

    /// Exports the currently visible conversations into a self-contained folder
    /// bundle (JSON manifest + per-conversation Markdown). Bodies are resolved
    /// against the active data source so cloud/iCloud transcripts are downloaded
    /// before writing.
    @MainActor
    func exportAllConversations() async {
        let records = filteredLogs
        guard !records.isEmpty else { return }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export"
        panel.message = "Choose a folder to export \(records.count) conversation\(records.count == 1 ? "" : "s")"
        guard panel.runModal() == .OK, let directory = panel.url else { return }

        isExporting = true
        defer { isExporting = false }

        var bodies: [String: String] = [:]
        for record in records {
            bodies[record.id] = await resolveExportBody(for: record)
        }
        let resolvedBodies = bodies

        do {
            let result = try await ConversationBundleExporter.exportBundle(
                records: records,
                to: directory,
                bodyProvider: { resolvedBodies[$0.id] ?? $0.fullText }
            )
            NSWorkspace.shared.activateFileViewerSelecting([result.jsonURL])
        } catch {
            dataSourceError = "Export failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func resolveExportBody(for record: OpenBurnBarCore.ConversationRecord) async -> String {
        switch dataSource {
        case .local:
            if let full = try? await dataStore.fetchConversation(id: record.id)?.fullText, !full.isEmpty {
                return full
            }
            return record.fullText
        case .cloud:
            if let cached = cloudBodyCache[record.sessionId], !cached.isEmpty { return cached }
            if let body = try? await cloudSyncService?.fetchCloudSessionLogBody(docId: record.sessionId),
               !body.isEmpty {
                return body
            }
            return record.fullText
        case .iCloud:
            return record.fullText
        }
    }

    // MARK: - Data Loading

    private func selectedConversationSources() -> Set<OpenBurnBarCore.ConversationSourceType>? {
        switch sourceFilter {
        case .all:
            return nil
        case .provider:
            return [.providerLog]
        case .assistant:
            return [.cliAssistant]
        }
    }

    func handleSelectedIdChange(_ newId: String?) {
        if dataSource == .local {
            Task { await loadSelectedLogDetailIfNeeded(for: newId) }
            return
        }

        guard dataSource == .cloud,
              let id = newId,
              let record = allLogs.first(where: { $0.id == id }),
              cloudBodyCache[record.sessionId] == nil else { return }
        Task {
            if let body = try? await cloudSyncService?.fetchCloudSessionLogBody(docId: record.sessionId) {
                cloudBodyCache[record.sessionId] = body
            }
        }
    }

    private func ensureRetrievalServices() {
        if retrievalSearchService == nil {
            retrievalSearchService = SearchService.makeConversationSearchService(
                dataStore: dataStore,
                settingsManager: settingsManager
            )
        }
        if retrievalHealthService == nil {
            retrievalHealthService = RetrievalHealthService(dataStore: dataStore)
        }
    }

    func refreshRetrievalHealth() {
        ensureRetrievalServices()
        guard let retrievalHealthService else {
            retrievalHealthSnapshot = .empty
            return
        }

        let sharedFeaturesAvailable: Bool
        switch dataSource {
        case .cloud:
            sharedFeaturesAvailable = accountManager.isSignedIn
        case .local, .iCloud:
            sharedFeaturesAvailable = true
        }

        Task { @MainActor in
            retrievalHealthSnapshot = await retrievalHealthService.snapshot(
                indexingEnabled: settingsManager.conversationIndexingEnabled,
                sharedFeaturesAvailable: sharedFeaturesAvailable
            )
        }
    }

    private func runLocalRetrievalSearchIfNeeded() async {
        refreshRetrievalHealth()
        guard dataSource == .local else {
            retrievalMatchedIDs = []
            isRetrievalSearching = false
            return
        }

        let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            retrievalMatchedIDs = []
            isRetrievalSearching = false
            return
        }

        ensureRetrievalServices()
        guard let retrievalSearchService else {
            retrievalMatchedIDs = []
            isRetrievalSearching = false
            return
        }

        let activeSources = selectedConversationSources()
        let expectedFilter = sourceFilter
        isRetrievalSearching = true
        let results = await retrievalSearchService.search(
            query: trimmedQuery,
            conversationSources: activeSources
        )

        guard dataSource == .local,
              searchText.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedQuery,
              sourceFilter == expectedFilter else {
            isRetrievalSearching = false
            return
        }

        retrievalMatchedIDs = results.map(\.conversation.id)
        isRetrievalSearching = false
        refreshRetrievalHealth()
    }

    private func reconcileSelectionWithFilteredLogs() {
        guard let selectedId else {
            self.selectedId = filteredLogs.first?.id
            return
        }
        if filteredLogs.contains(where: { $0.id == selectedId }) == false {
            self.selectedId = filteredLogs.first?.id
        }
    }

    func applyJumpTargetIfNeeded(_ target: ConversationJumpTarget?) {
        guard let target else { return }
        dataSource = .local
        sourceFilter = .all
        searchText = ""
        retrievalMatchedIDs = []
        selectedId = target.conversation.id
    }

    private func loadSelectedLogDetailIfNeeded(for id: String?) async {
        guard dataSource == .local, let id else {
            selectedDetailLog = nil
            return
        }

        if let selectedDetailLog, selectedDetailLog.id == id, !selectedDetailLog.fullText.isEmpty {
            return
        }

        do {
            selectedDetailLog = try await dataStore.fetchConversation(id: id)
        } catch {
            selectedDetailLog = allLogs.first { $0.id == id }
        }
    }

    private func loadLogs() async {
        isLoading = true
        dataSourceError = nil
        refreshRetrievalHealth()
        knownDevices = (try? await dataStore.fetchDevices()) ?? []
        sessionModelMap = (try? await dataStore.sessionModelMap()) ?? [:]
        selectedDetailLog = nil
        do {
            switch dataSource {
            case .local:
                let messages = try await dataStore.fetchChatMessages()
                if !messages.isEmpty { try await dataStore.upsertCLIConversation(from: messages) }
                allLogs = try await dataStore.fetchSessionLogSummaries()

            case .cloud:
                if let svc = cloudSyncService {
                    let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                    allLogs = trimmedQuery.isEmpty
                        ? try await svc.fetchCloudSessionLogs()
                        : try await svc.searchCloudSessionLogs(query: trimmedQuery)
                } else {
                    allLogs = []
                }

            case .iCloud:
                if let svc = iCloudMirrorService {
                    allLogs = await svc.fetchConversations()
                } else {
                    allLogs = []
                }
            }
        } catch {
            dataSourceError = error.localizedDescription
            allLogs = []
        }
        // Every loadLogs path assigns `allLogs` exactly once, so one bump per
        // call keeps the group-cache key honest even when a reload returns
        // the same number of records.
        allLogsVersion &+= 1

        await runLocalRetrievalSearchIfNeeded()
        reconcileSelectionWithFilteredLogs()
        if expandedSections.isEmpty, let firstId = logGroups.first?.id {
            expandedSections = [firstId]
        }
        await loadSelectedLogDetailIfNeeded(for: selectedId)
        isLoading = false
    }
}
