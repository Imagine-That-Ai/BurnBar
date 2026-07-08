import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import OpenBurnBarCore

// MARK: - Session Logs View

struct SessionLogsView: View {
    var dataStore: DataStore
    var accountManager: AccountManager
    var settingsManager: SettingsManager
    var operatingLayer: OpenBurnBarOperatingLayer?
    var cloudSyncService: CloudSyncService?
    var iCloudMirrorService: ICloudSessionMirrorService?
    var jumpTarget: ConversationJumpTarget?
    /// Fallback when usage-derived `sessionModelMap` has no model (e.g. in-app Hermes chat).
    var preferredChatModelKey: String?

    @State var allLogs: [ConversationRecord] = []
    @State var searchText = ""
    @State var sourceFilter: SessionLogSourceFilter = .all
    @State var groupMode: SessionLogGroupMode = .time
    @State var expandedSections: Set<String> = []
    @State var sectionDisplayLimits: [String: Int] = [:]
    @State var selectedId: String?
    @State var isLoading = false
    @State var appeared = false
    @State var dataSource: SessionLogDataSource = .local
    @State var cloudBodyCache: [String: String] = [:]
    @State var dataSourceError: String?
    @State var retrievalSearchService: SearchService?
    @State var retrievalHealthService: RetrievalHealthService?
    @State var retrievalMatchedIDs: [String] = []
    @State var isRetrievalSearching = false
    @State var retrievalHealthSnapshot: RetrievalSystemHealthSnapshot = .empty
    @State var deviceFilter: String?
    @State var knownDevices: [DeviceRecord] = []
    @State var sessionModelMap: [String: String] = [:]
    @State var iconPickerDeviceId: String?
    @State var selectedDetailLog: ConversationRecord?
    @State var resumeRequest: SessionResumeRequest?
    @State var isExporting = false
    /// Explicit ticker bumped once per `allLogs` assignment (in `loadLogs`).
    /// `allLogs.count` is not enough — a reload can replace the contents with
    /// the same number of records.
    @State var allLogsVersion = 0
    /// Bumped by `NSCalendarDayChanged` so the memoized time buckets
    /// re-derive at midnight (or timezone change) without other input changes.
    @State var dayChangeTick = 0
    @State var logGroupsCache = LogGroupsCache()
    @Environment(\.dashboardLiveBackdropActive) var dashboardLiveBackdropActive

    let defaultDisplayLimit = 15
    var hasMultipleDevices: Bool { knownDevices.count > 1 }
    var hasAnyDevices: Bool { !knownDevices.isEmpty }

    // MARK: - Body

    var body: some View {
        mainLayout
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.clear)
            .task { await initializeSessionLogs() }
            .onChange(of: searchText) { _, _ in handleSearchTextChange() }
            .onChange(of: sourceFilter) { _, _ in handleSourceFilterChange() }
            .onChange(of: groupMode) { _, _ in handleGroupModeChange() }
            .onChange(of: dataSource) { _, _ in handleDataSourceChange() }
            .onChange(of: settingsManager.conversationIndexingEnabled) { _, _ in handleConversationIndexingChange() }
            .onChange(of: settingsManager.preferredIndexEmbeddingVersionID) { _, _ in handleEmbeddingVersionChange() }
            .onChange(of: accountManager.isSignedIn) { _, _ in refreshRetrievalHealth() }
            .onChange(of: selectedId) { _, newId in handleSelectedIdChange(newId) }
            .onChange(of: jumpTarget?.id) { _, _ in applyJumpTargetIfNeeded(jumpTarget) }
            .onReceive(
                NotificationCenter.default
                    .publisher(for: .NSCalendarDayChanged)
                    .receive(on: RunLoop.main)
            ) { _ in
                dayChangeTick &+= 1
            }
            .sheet(item: $resumeRequest) { request in
                ResumeConversationSheet(
                    record: request.record,
                    initialTargetHarness: request.targetHarness,
                    daemonManager: .shared
                )
            }
    }

    private var mainLayout: some View {
        HStack(spacing: 0) {
            commandCenter
                .frame(width: 340)
                .frame(minHeight: 0, maxHeight: .infinity)

            Divider().background(DesignSystem.Colors.border)

            detailPane
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
    }
}
