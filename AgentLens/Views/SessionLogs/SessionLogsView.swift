import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import OpenBurnBarCore

// MARK: - Source Filter

// The filter/group enums and `SessionLogGroup` are internal (not private) so
// `SessionLogGroupsCacheTests` can drive the pure compute functions below.
enum SessionLogSourceFilter: String, CaseIterable, Identifiable {
    case all      = "All"
    case provider = "Provider"
    case assistant = "Assistant"
    var id: String { rawValue }
}

// MARK: - Group Mode

enum SessionLogGroupMode: String, CaseIterable, Identifiable {
    case time = "Time"
    case provider = "Provider"
    case project = "Project"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .time: return "clock"
        case .provider: return "cpu"
        case .project: return "folder"
        }
    }
}

// MARK: - Data Source

enum SessionLogDataSource: String, CaseIterable, Identifiable {
    case local  = "Local"
    case cloud  = "Cloud"
    case iCloud = "iCloud"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .local:  return "internaldrive"
        case .cloud:  return "cloud"
        case .iCloud: return "icloud"
        }
    }
}

// MARK: - Session Log Group

struct SessionLogGroup: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let accentColor: Color
    let provider: AgentProvider?
    let logs: [ConversationRecord]
}

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

    @State private var allLogs: [ConversationRecord] = []
    @State private var searchText = ""
    @State private var sourceFilter: SessionLogSourceFilter = .all
    @State private var groupMode: SessionLogGroupMode = .time
    @State private var expandedSections: Set<String> = []
    @State private var sectionDisplayLimits: [String: Int] = [:]
    @State private var selectedId: String?
    @State private var isLoading = false
    @State private var appeared = false
    @State private var dataSource: SessionLogDataSource = .local
    @State private var cloudBodyCache: [String: String] = [:]
    @State private var dataSourceError: String?
    @State private var retrievalSearchService: SearchService?
    @State private var retrievalHealthService: RetrievalHealthService?
    @State private var retrievalMatchedIDs: [String] = []
    @State private var isRetrievalSearching = false
    @State private var retrievalHealthSnapshot: RetrievalSystemHealthSnapshot = .empty
    @State private var deviceFilter: String?
    @State private var knownDevices: [DeviceRecord] = []
    @State private var sessionModelMap: [String: String] = [:]
    @State private var iconPickerDeviceId: String?
    @State private var selectedDetailLog: ConversationRecord?
    @State private var resumeRequest: SessionResumeRequest?
    @State private var isExporting = false
    /// Explicit ticker bumped once per `allLogs` assignment (in `loadLogs`).
    /// `allLogs.count` is not enough — a reload can replace the contents with
    /// the same number of records.
    @State private var allLogsVersion = 0
    /// Bumped by `NSCalendarDayChanged` so the memoized time buckets
    /// re-derive at midnight (or timezone change) without other input changes.
    @State private var dayChangeTick = 0
    @State private var logGroupsCache = LogGroupsCache()

    private let defaultDisplayLimit = 15
    private var hasMultipleDevices: Bool { knownDevices.count > 1 }
    private var hasAnyDevices: Bool { !knownDevices.isEmpty }

    // MARK: - Filtering

    /// Cache key for the memoized filter → group pipeline. `localDeviceId`
    /// covers the `knownDevices` dependency of device filtering; `dayStamp`
    /// re-derives the Today/Yesterday/This Week buckets after midnight or a
    /// timezone change, matching the old recompute-on-every-body-eval
    /// behaviour.
    private struct LogGroupsCacheKey: Equatable {
        let allLogsVersion: Int
        let searchText: String
        let sourceFilter: SessionLogSourceFilter
        let deviceFilter: String?
        let localDeviceId: String?
        let groupMode: SessionLogGroupMode
        let dataSource: SessionLogDataSource
        let retrievalMatchedIDs: [String]
        let dayStamp: Date
        let dayChangeTick: Int
    }

    /// Reference-typed store so the memo can refresh mid-body without
    /// re-entering SwiftUI's state graph.
    private final class LogGroupsCache {
        var key: LogGroupsCacheKey?
        var filteredLogs: [ConversationRecord] = []
        var groups: [SessionLogGroup] = []
    }

    // Memoized filter + group pipeline. Pre-cache these were chained computed
    // properties re-evaluated on every read: a single body evaluation reads
    // `filteredLogs` ~6 times and `logGroups` twice, so each keystroke or
    // selection change cost 8+ full filter/group/sort passes over the loaded
    // records. The key is checked on read (rather than rebuilt via
    // `.onChange` — see docs/architecture/macos-performance.md §2) because
    // `handleSourceFilterChange`/`loadLogs` read the groups synchronously
    // right after mutating their inputs.
    private var filteredLogs: [ConversationRecord] {
        rebuildLogGroupsIfNeeded()
        return logGroupsCache.filteredLogs
    }

    private var logGroups: [SessionLogGroup] {
        rebuildLogGroupsIfNeeded()
        return logGroupsCache.groups
    }

    private var logGroupsCacheKey: LogGroupsCacheKey {
        LogGroupsCacheKey(
            allLogsVersion: allLogsVersion,
            searchText: searchText,
            sourceFilter: sourceFilter,
            deviceFilter: deviceFilter,
            localDeviceId: knownDevices.first(where: { $0.isLocal })?.deviceId,
            groupMode: groupMode,
            dataSource: dataSource,
            retrievalMatchedIDs: retrievalMatchedIDs,
            dayStamp: Calendar.current.startOfDay(for: Date()),
            dayChangeTick: dayChangeTick
        )
    }

    private func rebuildLogGroupsIfNeeded() {
        let key = logGroupsCacheKey
        guard key != logGroupsCache.key else { return }
        let filtered = Self.computeFilteredLogs(
            allLogs: allLogs,
            sourceFilter: key.sourceFilter,
            deviceFilter: key.deviceFilter,
            localDeviceId: key.localDeviceId,
            searchText: key.searchText,
            dataSource: key.dataSource,
            retrievalMatchedIDs: key.retrievalMatchedIDs
        )
        logGroupsCache.filteredLogs = filtered
        logGroupsCache.groups = Self.computeLogGroups(from: filtered, groupMode: key.groupMode)
        logGroupsCache.key = key
    }

    /// Pure, deterministic filter pass. `internal` (with the enums above) so
    /// `AgentLensTests/Active/SessionLogGroupsCacheTests.swift` can pin the
    /// matrix down without a SwiftUI host — mirrors
    /// `ProjectsView.computeMergedProjects`.
    static func computeFilteredLogs(
        allLogs: [ConversationRecord],
        sourceFilter: SessionLogSourceFilter,
        deviceFilter: String?,
        localDeviceId: String?,
        searchText: String,
        dataSource: SessionLogDataSource,
        retrievalMatchedIDs: [String]
    ) -> [ConversationRecord] {
        var result: [ConversationRecord]
        switch sourceFilter {
        case .all:
            result = allLogs
        case .provider:
            result = allLogs.filter { $0.sourceType == .providerLog }
        case .assistant:
            result = allLogs.filter { $0.sourceType == .cliAssistant }
        }
        if let deviceFilter {
            result = result.filter { record in
                if record.isRemote { return record.sourceDeviceId == deviceFilter }
                return localDeviceId == deviceFilter
            }
        }

        let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return result }

        if dataSource == .local {
            let byID = Dictionary(uniqueKeysWithValues: result.map { ($0.id, $0) })
            return retrievalMatchedIDs.compactMap { byID[$0] }
        }

        return substringFilteredLogs(from: result, query: trimmedQuery)
    }

    private var visibleDegradedModes: [RetrievalDegradedState] {
        retrievalHealthSnapshot.degradedModes.filter { state in
            if dataSource == .local {
                return state.mode != .cloudSharedUnavailable
            }
            return true
        }
    }

    private var selectedLog: ConversationRecord? {
        guard let id = selectedId else { return nil }
        if let selectedDetailLog, selectedDetailLog.id == id {
            return selectedDetailLog
        }
        return allLogs.first { $0.id == id }
    }

    // MARK: - Grouping

    /// Pure, deterministic grouping pass — see `computeFilteredLogs`.
    /// `now` is injectable so the time buckets are unit-testable.
    static func computeLogGroups(
        from logs: [ConversationRecord],
        groupMode: SessionLogGroupMode,
        now: Date = Date()
    ) -> [SessionLogGroup] {
        switch groupMode {
        case .time: return timeGroups(from: logs, now: now)
        case .provider: return providerGroups(from: logs)
        case .project: return projectGroups(from: logs)
        }
    }

    private static func timeGroups(from logs: [ConversationRecord], now: Date) -> [SessionLogGroup] {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday)!
        let startOfWeek = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))!
        let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!

        var buckets: [String: [ConversationRecord]] = [
            "today": [], "yesterday": [], "week": [], "month": [], "older": []
        ]
        for log in logs {
            // Bucket by when the session actually occurred — start first, then end.
            // Avoid preferring endTime alone (some pipelines align it with re-import);
            // fileModifiedAt beats indexedAt for "last known log activity" when times are missing.
            let date = log.startTime ?? log.endTime ?? log.fileModifiedAt ?? log.indexedAt
            if date >= startOfToday {
                buckets["today"]!.append(log)
            } else if date >= startOfYesterday {
                buckets["yesterday"]!.append(log)
            } else if date >= startOfWeek {
                buckets["week"]!.append(log)
            } else if date >= startOfMonth {
                buckets["month"]!.append(log)
            } else {
                buckets["older"]!.append(log)
            }
        }

        let defs: [(id: String, title: String, icon: String, color: Color)] = [
            ("today", "Today", "sun.max.fill", DesignSystem.Colors.ember),
            ("yesterday", "Yesterday", "moon.fill", DesignSystem.Colors.amber),
            ("week", "This Week", "calendar", DesignSystem.Colors.blaze),
            ("month", "This Month", "calendar.badge.clock", DesignSystem.Colors.whimsy),
            ("older", "Older", "archivebox.fill", DesignSystem.Colors.textMuted)
        ]
        return defs.compactMap { d in
            guard let logs = buckets[d.id], !logs.isEmpty else { return nil }
            return SessionLogGroup(id: d.id, title: d.title, systemImage: d.icon, accentColor: d.color, provider: nil, logs: logs)
        }
    }

    private static func providerGroups(from logs: [ConversationRecord]) -> [SessionLogGroup] {
        Dictionary(grouping: logs) { $0.provider }
            .map { provider, logs in
                SessionLogGroup(
                    id: "provider-\(provider.rawValue)",
                    title: provider.displayName,
                    systemImage: provider.iconName,
                    accentColor: DesignSystem.Colors.primary(for: provider),
                    provider: provider,
                    logs: logs
                )
            }
            .sorted { $0.logs.count > $1.logs.count }
    }

    private static func projectGroups(from logs: [ConversationRecord]) -> [SessionLogGroup] {
        Dictionary(grouping: logs) { $0.projectName }
            .map { project, logs in
                SessionLogGroup(
                    id: "project-\(project)",
                    title: project.isEmpty ? "Unknown" : project,
                    systemImage: "folder.fill",
                    accentColor: DesignSystem.Colors.amber,
                    provider: nil,
                    logs: logs
                )
            }
            .sorted { $0.logs.count > $1.logs.count }
    }

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

    // MARK: - Command Center

    private var commandCenter: some View {
        VStack(spacing: 0) {
            statsHeader
                .padding(.horizontal, DesignSystem.Spacing.lg)
                .padding(.top, DesignSystem.Spacing.lg)
                .padding(.bottom, DesignSystem.Spacing.md)

            searchBar
                .padding(.horizontal, DesignSystem.Spacing.lg)
                .padding(.bottom, DesignSystem.Spacing.sm)

            filterBar
                .padding(.horizontal, DesignSystem.Spacing.lg)
                .padding(.bottom, hasMultipleDevices ? DesignSystem.Spacing.xs : DesignSystem.Spacing.md)

            if hasAnyDevices {
                deviceFilterBar
                    .padding(.horizontal, DesignSystem.Spacing.lg)
                    .padding(.bottom, DesignSystem.Spacing.md)
            }

            if dataSource == .local, !visibleDegradedModes.isEmpty {
                retrievalDegradedModeBanner
                    .padding(.horizontal, DesignSystem.Spacing.lg)
                    .padding(.bottom, DesignSystem.Spacing.md)
            }

            Divider().background(DesignSystem.Colors.border.opacity(0.6))

            if isLoading {
                Spacer()
                ProgressView()
                Spacer()
            } else if filteredLogs.isEmpty {
                emptyListState
            } else {
                groupedList
            }
        }
        .background {
            if settingsManager.useWebsiteBackground {
                Color.clear.background(.ultraThinMaterial)
            } else {
                ZStack {
                    DesignSystem.Colors.surface.opacity(0.92)
                    LinearGradient(
                        colors: [
                            DesignSystem.Colors.textPrimary.opacity(0.015),
                            Color.clear
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
            }
        }
        .onAppear { appeared = true }
    }

    // MARK: - Stats Header

    private var statsHeader: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.xs) {
                Image(systemName: "scroll")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.ember)
                Text("Session Logs")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .textCase(.uppercase)
            }

            Text("\(filteredLogs.count) log\(filteredLogs.count == 1 ? "" : "s")")
                .font(DesignSystem.Typography.headline)
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            HStack(spacing: DesignSystem.Spacing.lg) {
                let providerCount = Set(filteredLogs.map(\.provider)).count
                let projectCount = Set(filteredLogs.map(\.projectName)).count
                statPill(value: "\(providerCount)", label: "providers")
                statPill(value: "\(projectCount)", label: "projects")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statPill(value: String, label: String) -> some View {
        HStack(spacing: DesignSystem.Spacing.xxs) {
            Text(value)
                .font(DesignSystem.Typography.monoSmall)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
            Text(label)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DesignSystem.Colors.textMuted)

            TextField("Search by title, project, provider, or keyword…", text: $searchText)
                .font(DesignSystem.Typography.caption)
                .textFieldStyle(.plain)
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
                .buttonStyle(.plain)
            }

            if dataSource == .local, isRetrievalSearching {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.full, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.full, style: .continuous)
                        .strokeBorder(DesignSystem.Colors.border.opacity(0.5), lineWidth: 0.5)
                )
        )
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            ForEach(SessionLogSourceFilter.allCases) { filter in
                sourceFilterButton(filter)
            }

            Spacer()

            groupModePicker

            if hasMultipleDevices {
                deviceFilterMenu
            }

            exportButton

            dataSourceMenu
        }
    }

    private var exportButton: some View {
        Button {
            Task { await exportAllConversations() }
        } label: {
            if isExporting {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 24, height: 20)
            } else {
                filterIconButton(
                    systemImage: "square.and.arrow.up",
                    isActive: false,
                    activeColor: DesignSystem.Colors.teal
                )
            }
        }
        .buttonStyle(.plain)
        .disabled(isExporting || filteredLogs.isEmpty)
        .help("Export \(filteredLogs.count) conversation\(filteredLogs.count == 1 ? "" : "s") to a folder (JSON + Markdown)")
    }

    private func sourceFilterButton(_ filter: SessionLogSourceFilter) -> some View {
        let isActive = sourceFilter == filter
        let accent = filterAccent(for: filter)
        return Button {
            withAnimation(DesignSystem.Animation.snappy) {
                sourceFilter = filter
            }
        } label: {
            Text(filter.rawValue)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(isActive ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textMuted)
                .padding(.horizontal, DesignSystem.Spacing.md)
                .padding(.vertical, DesignSystem.Spacing.xs)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.full, style: .continuous)
                        .fill(isActive ? AnyShapeStyle(accent.opacity(0.18)) : AnyShapeStyle(DesignSystem.Colors.surfaceElevated.opacity(0.4)))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.full, style: .continuous)
                        .strokeBorder(isActive ? accent.opacity(0.45) : DesignSystem.Colors.border.opacity(0.3), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }

    private var groupModePicker: some View {
        HStack(spacing: 2) {
            ForEach(SessionLogGroupMode.allCases) { mode in
                groupModeButton(mode)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.4))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                .strokeBorder(DesignSystem.Colors.border.opacity(0.3), lineWidth: 0.5)
        )
    }

    private func groupModeButton(_ mode: SessionLogGroupMode) -> some View {
        let isActive = groupMode == mode
        return Button {
            withAnimation(DesignSystem.Animation.snappy) {
                groupMode = mode
            }
        } label: {
            Image(systemName: mode.icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isActive ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textMuted)
                .frame(width: 24, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isActive ? DesignSystem.Colors.surfaceElevated : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help("Group by \(mode.rawValue.lowercased())")
    }

    private var deviceFilterMenu: some View {
        Menu {
            Button {
                withAnimation(DesignSystem.Animation.snappy) {
                    deviceFilter = nil
                }
            } label: {
                Label("All Devices", systemImage: "desktopcomputer")
            }
            Divider()
            ForEach(knownDevices) { device in
                Button {
                    withAnimation(DesignSystem.Animation.snappy) {
                        deviceFilter = device.deviceId
                    }
                } label: {
                    Label(device.deviceName, systemImage: device.sfSymbolName)
                }
            }
        } label: {
            filterIconButton(
                systemImage: "desktopcomputer",
                isActive: deviceFilter != nil,
                activeColor: DesignSystem.Colors.teal
            )
        }
        .menuStyle(.borderlessButton)
        .help(activeDeviceName)
    }

    private var dataSourceMenu: some View {
        Menu {
            ForEach(SessionLogDataSource.allCases) { source in
                Button {
                    withAnimation(DesignSystem.Animation.snappy) {
                        dataSource = source
                    }
                } label: {
                    Label(source.rawValue, systemImage: source.icon)
                }
            }
        } label: {
            filterIconButton(
                systemImage: dataSource.icon,
                isActive: dataSource != .local,
                activeColor: DesignSystem.Colors.ember
            )
        }
        .menuStyle(.borderlessButton)
        .help("Data source: \(dataSource.rawValue)")
    }

    private func filterIconButton(systemImage: String, isActive: Bool, activeColor: Color) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(isActive ? activeColor : DesignSystem.Colors.textMuted)
            .frame(width: 24, height: 20)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isActive ? activeColor.opacity(0.12) : Color.clear)
            )
    }

    private var activeDeviceName: String {
        guard let deviceFilter else { return "All Devices" }
        return knownDevices.first { $0.deviceId == deviceFilter }?.deviceName ?? "All Devices"
    }

    private func filterAccent(for filter: SessionLogSourceFilter) -> Color {
        switch filter {
        case .all:       return DesignSystem.Colors.ember
        case .provider:  return DesignSystem.Colors.amber
        case .assistant: return DesignSystem.Colors.whimsy
        }
    }

    private var deviceFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DesignSystem.Spacing.xs) {
                deviceFilterPill(label: "All", icon: "rectangle.stack", id: nil)

                ForEach(knownDevices) { device in
                    deviceFilterPill(label: device.deviceName, icon: device.sfSymbolName, id: device.deviceId)
                }
            }
        }
    }

    private func deviceFilterPill(label: String, icon: String, id: String?) -> some View {
        let isActive = deviceFilter == id
        return Button {
            withAnimation(DesignSystem.Animation.snappy) {
                deviceFilter = id
            }
        } label: {
            HStack(spacing: DesignSystem.Spacing.xxs) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .medium))
                Text(label)
                    .lineLimit(1)
            }
            .font(DesignSystem.Typography.tiny)
            .foregroundStyle(isActive ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textMuted)
            .padding(.horizontal, DesignSystem.Spacing.sm)
            .padding(.vertical, DesignSystem.Spacing.xxs + 1)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.full, style: .continuous)
                    .fill(isActive ? DesignSystem.Colors.teal.opacity(0.18) : DesignSystem.Colors.surfaceElevated.opacity(0.4))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.full, style: .continuous)
                    .strokeBorder(
                        isActive ? DesignSystem.Colors.teal.opacity(0.45) : DesignSystem.Colors.border.opacity(0.3),
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                if let id { iconPickerDeviceId = id }
            }
        )
        .popover(isPresented: Binding(
            get: { iconPickerDeviceId == id && id != nil },
            set: { if !$0 { iconPickerDeviceId = nil } }
        )) {
            if let id {
                DeviceIconPicker(
                    deviceId: id,
                    currentIcon: icon,
                    dataStore: dataStore
                ) {
                    iconPickerDeviceId = nil
                    knownDevices = (try? dataStore.fetchDevices()) ?? []
                }
            }
        }
    }

    private var retrievalDegradedModeBanner: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            ForEach(visibleDegradedModes) { state in
                HStack(alignment: .top, spacing: DesignSystem.Spacing.xs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(DesignSystem.Colors.warning)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.title)
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                        Text(state.message)
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, DesignSystem.Spacing.sm)
                .padding(.vertical, DesignSystem.Spacing.xs)
                .background(DesignSystem.Colors.warning.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
            }
        }
    }

    // MARK: - Grouped List

    private var groupedList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(logGroups) { group in
                        Section {
                            if expandedSections.contains(group.id) {
                                sectionContent(for: group)
                            }
                        } header: {
                            sectionHeader(for: group)
                        }
                    }
                }
                .padding(.vertical, DesignSystem.Spacing.xs)
            }
            .defaultScrollAnchor(.top)
            .scrollContentBackground(.hidden)
            .onChange(of: logGroups.first?.id) { _, _ in
                if let firstId = logGroups.first?.id {
                    withAnimation { proxy.scrollTo(firstId, anchor: .top) }
                }
            }
        }
        .frame(minHeight: 0, maxHeight: .infinity)
    }

    private func sectionHeader(for group: SessionLogGroup) -> some View {
        let isExpanded = expandedSections.contains(group.id)
        return Button {
            withAnimation(DesignSystem.Animation.snappy) {
                if isExpanded {
                    expandedSections.remove(group.id)
                } else {
                    expandedSections.insert(group.id)
                }
            }
        } label: {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(group.accentColor)
                    .frame(width: 12, alignment: .center)

                if let provider = group.provider {
                    ProviderLogoView(provider: provider, size: 16, useFallbackColor: true)
                } else {
                    Image(systemName: group.systemImage)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(group.accentColor)
                }

                Text(group.title)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineLimit(1)

                Spacer()

                Text("\(group.logs.count)")
                    .font(DesignSystem.Typography.monoSmall)
                    .foregroundStyle(group.accentColor)
                    .padding(.horizontal, DesignSystem.Spacing.sm)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(group.accentColor.opacity(0.12))
                    )
            }
            .padding(.horizontal, DesignSystem.Spacing.lg)
            .padding(.vertical, DesignSystem.Spacing.sm)
            .background(DesignSystem.Colors.surface.opacity(0.95))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(group.id)
    }

    @ViewBuilder
    private func sectionContent(for group: SessionLogGroup) -> some View {
        let limit = sectionDisplayLimits[group.id] ?? defaultDisplayLimit
        let showing = Array(group.logs.prefix(limit))

        VStack(spacing: DesignSystem.Spacing.xxs) {
            ForEach(showing) { record in
                CompactSessionRow(
                    record: record,
                    isSelected: selectedId == record.id,
                    showDeviceIndicator: hasMultipleDevices,
                    modelName: sessionModelMap[record.id],
                    deviceIcon: record.sourceDeviceId.flatMap { did in
                        knownDevices.first { $0.deviceId == did }?.sfSymbolName
                    }
                ) {
                    withAnimation(DesignSystem.Animation.snappy) {
                        selectedId = record.id
                    }
                } onResume: { targetHarness in
                    resumeRequest = SessionResumeRequest(record: record, targetHarness: targetHarness)
                }
            }

            if group.logs.count > limit {
                let remaining = group.logs.count - limit
                Button {
                    withAnimation(DesignSystem.Animation.gentle) {
                        sectionDisplayLimits[group.id] = limit + min(30, remaining)
                    }
                } label: {
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 9))
                        Text("Show \(min(30, remaining)) more of \(remaining) remaining")
                            .font(DesignSystem.Typography.tiny)
                    }
                    .foregroundStyle(group.accentColor)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DesignSystem.Spacing.sm)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.bottom, DesignSystem.Spacing.sm)
        .transition(.opacity)
    }

    // MARK: - Empty State

    private var emptyListState: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            Spacer()
            Image(systemName: dataSource.icon)
                .font(.system(size: 36))
                .foregroundStyle(DesignSystem.Colors.textMuted.opacity(0.5))

            if let error = dataSourceError {
                Text("Could not load \(dataSource.rawValue) logs")
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(error)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DesignSystem.Spacing.lg)
            } else if dataSource == .cloud {
                if !accountManager.isSignedIn {
                    Text("Sign in to load cloud logs")
                        .font(DesignSystem.Typography.headline)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text("Cloud logs require a OpenBurnBar account. Sign in via Settings.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, DesignSystem.Spacing.lg)
                } else {
                    Text(searchText.isEmpty ? "No cloud logs yet" : "No results")
                        .font(DesignSystem.Typography.headline)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text(searchText.isEmpty
                            ? "Enable session log cloud backup in Settings to store logs here."
                            : "Try a different search term."
                    )
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DesignSystem.Spacing.lg)
                }
            } else if dataSource == .iCloud {
                if !(iCloudMirrorService?.hasUbiquityIdentity ?? false) {
                    Text("Sign in to iCloud")
                        .font(DesignSystem.Typography.headline)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text("Sign in to iCloud in System Settings to access your mirrored sessions.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, DesignSystem.Spacing.lg)
                } else {
                    Text(searchText.isEmpty ? "No mirrored files found" : "No results")
                        .font(DesignSystem.Typography.headline)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text(searchText.isEmpty
                            ? "Enable iCloud session mirror in Settings and run a sync first."
                            : "Try a different search term."
                    )
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DesignSystem.Spacing.lg)
                }
            } else if !settingsManager.conversationIndexingEnabled && sourceFilter != .assistant {
                Text("Enable conversation indexing")
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("Turn on indexing in Settings to track your provider sessions here.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DesignSystem.Spacing.lg)
            } else {
                Text(searchText.isEmpty ? "No logs yet" : "No results")
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(searchText.isEmpty
                        ? "Start a chat with the OpenBurnBar Assistant, or scan your provider sessions."
                        : "Try a different search term."
                )
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DesignSystem.Spacing.lg)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Detail Pane

    @ViewBuilder
    private var detailPane: some View {
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

    private func initializeSessionLogs() async {
        knownDevices = (try? dataStore.fetchDevices()) ?? []
        await loadLogs()
        applyJumpTargetIfNeeded(jumpTarget)
    }

    private func handleSearchTextChange() {
        Task {
            if dataSource == .cloud {
                await loadLogs()
            } else {
                await runLocalRetrievalSearchIfNeeded()
            }
        }
    }

    private func handleSourceFilterChange() {
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

    private func handleGroupModeChange() {
        sectionDisplayLimits = [:]
        expandedSections = Set(logGroups.prefix(1).map(\.id))
    }

    private func handleDataSourceChange() {
        selectedId = nil
        cloudBodyCache = [:]
        Task { await loadLogs() }
    }

    private func handleConversationIndexingChange() {
        refreshRetrievalHealth()
        Task { await runLocalRetrievalSearchIfNeeded() }
    }

    private func handleEmbeddingVersionChange() {
        retrievalSearchService = SearchService.makeConversationSearchService(
            dataStore: dataStore,
            settingsManager: settingsManager
        )
        refreshRetrievalHealth()
        Task { await runLocalRetrievalSearchIfNeeded() }
    }

    // MARK: - Export

    /// Exports the currently visible conversations into a self-contained folder
    /// bundle (JSON manifest + per-conversation Markdown). Bodies are resolved
    /// against the active data source so cloud/iCloud transcripts are downloaded
    /// before writing.
    @MainActor
    private func exportAllConversations() async {
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
    private func resolveExportBody(for record: ConversationRecord) async -> String {
        switch dataSource {
        case .local:
            if let full = try? dataStore.fetchConversation(id: record.id)?.fullText, !full.isEmpty {
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

    private static func substringFilteredLogs(from logs: [ConversationRecord], query: String) -> [ConversationRecord] {
        let q = query.lowercased()
        return logs.filter {
            $0.inferredTaskTitle.lowercased().contains(q)
                || ($0.summaryTitle?.lowercased().contains(q) ?? false)
                || $0.projectName.lowercased().contains(q)
                || $0.provider.displayName.lowercased().contains(q)
                || ($0.summary?.lowercased().contains(q) ?? false)
                || $0.fullText.lowercased().contains(q)
        }
    }

    private func selectedConversationSources() -> Set<ConversationSourceType>? {
        switch sourceFilter {
        case .all:
            return nil
        case .provider:
            return [.providerLog]
        case .assistant:
            return [.cliAssistant]
        }
    }

    private func handleSelectedIdChange(_ newId: String?) {
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

    private func refreshRetrievalHealth() {
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

        retrievalHealthSnapshot = retrievalHealthService.snapshot(
            indexingEnabled: settingsManager.conversationIndexingEnabled,
            sharedFeaturesAvailable: sharedFeaturesAvailable
        )
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

    private func applyJumpTargetIfNeeded(_ target: ConversationJumpTarget?) {
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
            selectedDetailLog = try dataStore.fetchConversation(id: id)
        } catch {
            selectedDetailLog = allLogs.first { $0.id == id }
        }
    }

    private func loadLogs() async {
        isLoading = true
        dataSourceError = nil
        refreshRetrievalHealth()
        knownDevices = (try? dataStore.fetchDevices()) ?? []
        sessionModelMap = (try? dataStore.sessionModelMap()) ?? [:]
        selectedDetailLog = nil
        do {
            switch dataSource {
            case .local:
                let messages = try dataStore.fetchChatMessages()
                if !messages.isEmpty { try dataStore.upsertCLIConversation(from: messages) }
                allLogs = try dataStore.fetchSessionLogSummaries()

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

// MARK: - Compact Session Row

private struct CompactSessionRow: View {
    let record: ConversationRecord
    let isSelected: Bool
    var showDeviceIndicator: Bool = false
    var modelName: String?
    var deviceIcon: String?
    let action: () -> Void
    let onResume: (AgentProvider) -> Void

    private var accentColor: Color {
        record.sourceType == .cliAssistant
            ? DesignSystem.Colors.whimsy
            : DesignSystem.Colors.primary(for: record.provider)
    }

    /// Short display model name, e.g. "claude-opus-4" → "Opus 4"
    private var shortModelLabel: String? {
        guard let model = modelName, !model.isEmpty else { return nil }
        return model
    }

    private var timeLabel: String {
        guard let date = record.endTime ?? record.startTime else {
            return record.indexedAt.relativeLabel
        }
        return date.relativeLabel
    }

    private var displayTitle: String {
        if let summaryTitle = record.summaryTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summaryTitle.isEmpty {
            return summaryTitle
        }
        return record.inferredTaskTitle.isEmpty ? "Session" : record.inferredTaskTitle
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                ZStack(alignment: .bottomTrailing) {
                    ZStack {
                        Circle()
                            .fill(isSelected ? accentColor.opacity(0.18) : DesignSystem.Colors.surfaceElevated.opacity(0.6))
                            .frame(width: 28, height: 28)

                        if record.sourceType == .cliAssistant {
                            Image(systemName: "terminal.fill")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(isSelected ? accentColor : DesignSystem.Colors.textSecondary)
                        } else {
                            ProviderLogoView(provider: record.provider, size: 16, useFallbackColor: false)
                        }
                    }

                    // Model vendor badge — small overlay in bottom-right
                    if let model = modelName, !model.isEmpty {
                        ModelProviderLogoView(modelKey: model, size: 13)
                            .background(
                                Circle()
                                    .fill(DesignSystem.Colors.surface)
                                    .frame(width: 15, height: 15)
                            )
                            .offset(x: 3, y: 3)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: DesignSystem.Spacing.xxs) {
                        Text(displayTitle)
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(isSelected ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary)
                            .lineLimit(1)

                        if let label = shortModelLabel {
                            Text(label)
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(LLMModelBrand.infer(fromModelKey: label).emblemColor.opacity(0.7))
                                .lineLimit(1)
                                .layoutPriority(-1)
                        }
                    }

                    HStack(spacing: DesignSystem.Spacing.xs) {
                        if showDeviceIndicator, record.isRemote, let deviceName = record.sourceDeviceName {
                            Image(systemName: deviceIcon ?? "desktopcomputer")
                                .font(.system(size: 8))
                            Text(deviceName)
                                .lineLimit(1)
                            Text("·")
                        }
                        Text(record.projectName)
                            .lineLimit(1)
                        Text("·")
                        Text("\(record.messageCount) msgs")
                    }
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                }

                Spacer(minLength: 0)

                Text(timeLabel)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            .padding(.horizontal, DesignSystem.Spacing.sm)
            .padding(.vertical, DesignSystem.Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.sm)
                    .fill(isSelected ? accentColor.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Menu {
                ForEach(AgentProvider.allCases) { provider in
                    Button {
                        onResume(provider)
                    } label: {
                        Label(provider.rawValue, systemImage: provider == record.provider ? "arrow.uturn.forward.circle.fill" : provider.iconName)
                    }
                }
            } label: {
                Label("Resume in...", systemImage: "arrow.triangle.2.circlepath")
            }
        }
    }
}

private struct SessionResumeRequest: Identifiable {
    let id = UUID()
    let record: ConversationRecord
    let targetHarness: AgentProvider
}

private struct ResumeConversationSheet: View {
    let record: ConversationRecord
    let initialTargetHarness: AgentProvider
    var daemonManager: OpenBurnBarDaemonManager

    @Environment(\.dismiss) private var dismiss
    @State private var targetHarness: AgentProvider
    @State private var response: BurnBarRunResumeResponse?
    @State private var isLoading = false
    @State private var isOpening = false
    @State private var isSpawning = false
    @State private var errorMessage: String?
    @State private var openedPath: String?

    init(
        record: ConversationRecord,
        initialTargetHarness: AgentProvider,
        daemonManager: OpenBurnBarDaemonManager
    ) {
        self.record = record
        self.initialTargetHarness = initialTargetHarness
        self.daemonManager = daemonManager
        _targetHarness = State(initialValue: initialTargetHarness)
    }

    private var title: String {
        record.summaryTitle?.nonEmpty ?? record.inferredTaskTitle.nonEmpty ?? "Session"
    }

    private var previewText: String {
        guard let response else {
            return errorMessage ?? "Rendering resume briefing..."
        }
        switch response.kind {
        case "native":
            let cwd = response.workingDirectory.map { "# Run from: \($0)\n" } ?? ""
            return cwd + (response.argv ?? []).joined(separator: " ")
        case "ported":
            let note = response.note.map { "# note: \($0)\n" } ?? ""
            return note + (response.briefingMD ?? "")
        case "error":
            return "error: \(response.errorCode ?? "unknown")\n\(response.errorRecovery ?? "")"
        case "spawned":
            return "Spawned \(response.targetHarness ?? "target") pid=\(response.pid.map(String.init) ?? "unknown")"
        default:
            return "error: unknown response kind '\(response.kind)'"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            header

            Picker("Harness", selection: $targetHarness) {
                ForEach(AgentProvider.allCases) { provider in
                    Text(provider.rawValue).tag(provider)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: targetHarness) { _, _ in
                Task { await loadPreview() }
            }

            previewPane

            HStack(spacing: DesignSystem.Spacing.md) {
                if let openedPath {
                    Text(openedPath)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button {
                    Task { await spawnResume() }
                } label: {
                    if isSpawning {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Spawn", systemImage: "play.fill")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isLoading || isOpening || isSpawning)

                Button {
                    Task { await openResume() }
                } label: {
                    if isOpening {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Open", systemImage: "arrow.up.forward.app")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignSystem.Colors.ember)
                .disabled(isLoading || isOpening || isSpawning)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DesignSystem.Spacing.xl)
        .frame(minWidth: 680, minHeight: 560)
        .background(DesignSystem.Colors.surface)
        .task { await loadPreview() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            ProviderLogoView(provider: record.provider, size: 30, useFallbackColor: false)

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text("Resume Session")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .textCase(.uppercase)

                Text(title)
                    .font(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineLimit(2)

                HStack(spacing: DesignSystem.Spacing.xs) {
                    Text(record.provider.rawValue)
                    Text("->")
                    Text(targetHarness.rawValue)
                    if let workingDirectory = record.workingDirectory?.nonEmpty {
                        Text("·")
                        Text(workingDirectory)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            }

            Spacer()
        }
    }

    private var previewPane: some View {
        ZStack(alignment: .topLeading) {
            ScrollView {
                Text(previewText)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(errorMessage == nil ? DesignSystem.Colors.textSecondary : DesignSystem.Colors.error)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DesignSystem.Spacing.md)
            }
            .background(DesignSystem.Colors.background.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .strokeBorder(DesignSystem.Colors.border.opacity(0.45), lineWidth: 0.5)
            )

            if isLoading {
                ProgressView()
                    .padding(DesignSystem.Spacing.md)
            }
        }
        .frame(minHeight: 360)
    }

    private func loadPreview() async {
        isLoading = true
        errorMessage = nil
        openedPath = nil
        do {
            let result = try await daemonManager.runResume(
                sessionID: record.id,
                targetHarness: targetHarness.rawValue,
                mode: .print
            )
            response = result
            if result.kind == "error" {
                errorMessage = result.errorRecovery
            }
        } catch {
            response = nil
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func openResume() async {
        isOpening = true
        errorMessage = nil
        do {
            let result = try await daemonManager.runResume(
                sessionID: record.id,
                targetHarness: targetHarness.rawValue,
                mode: .open
            )
            response = result
            switch result.kind {
            case "native":
                openedPath = (result.argv ?? []).joined(separator: " ")
            case "ported":
                openedPath = result.briefingPath
            case "error":
                errorMessage = result.errorRecovery ?? result.errorCode
            default:
                errorMessage = "Unknown response kind '\(result.kind)'."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isOpening = false
    }

    private func spawnResume() async {
        isSpawning = true
        errorMessage = nil
        do {
            let result = try await daemonManager.runResume(
                sessionID: record.id,
                targetHarness: targetHarness.rawValue,
                mode: .spawn
            )
            response = result
            switch result.kind {
            case "spawned":
                openedPath = "Spawned \(result.targetHarness ?? "target") pid=\(result.pid.map(String.init) ?? "unknown")"
            case "error":
                errorMessage = result.errorRecovery ?? result.errorCode
            default:
                errorMessage = "Expected spawned response, got '\(result.kind)'."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isSpawning = false
    }
}

// MARK: - Device Icon Picker

private struct DeviceIconPicker: View {
    let deviceId: String
    let currentIcon: String
    var dataStore: DataStore
    var onDismiss: () -> Void

    private let columns = Array(repeating: GridItem(.fixed(36), spacing: DesignSystem.Spacing.sm), count: 5)

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack {
                Text("Device Icon")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .textCase(.uppercase)
                Spacer()
            }

            LazyVGrid(columns: columns, spacing: DesignSystem.Spacing.sm) {
                ForEach(DeviceHardwareIcon.allIcons, id: \.symbol) { item in
                    let isSelected = currentIcon == item.symbol
                    Button {
                        try? dataStore.updateDeviceIcon(deviceId: deviceId, customIcon: item.symbol)
                        onDismiss()
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(isSelected ? DesignSystem.Colors.teal : DesignSystem.Colors.textPrimary)
                                .frame(width: 32, height: 32)
                                .background(
                                    RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                                        .fill(isSelected ? DesignSystem.Colors.teal.opacity(0.15) : DesignSystem.Colors.surfaceElevated)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                                        .strokeBorder(
                                            isSelected ? DesignSystem.Colors.teal.opacity(0.5) : DesignSystem.Colors.border.opacity(0.3),
                                            lineWidth: isSelected ? 1.5 : 0.5
                                        )
                                )
                            Text(item.label)
                                .font(.system(size: 8, weight: .medium, design: .rounded))
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            Button {
                try? dataStore.updateDeviceIcon(deviceId: deviceId, customIcon: nil)
                onDismiss()
            } label: {
                Text("Reset to Auto")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(width: 220)
        .background(DesignSystem.Colors.surface)
    }
}

struct SessionLogCloudConsentSheet: View {
    @Bindable var settingsManager: SettingsManager
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    DesignSystem.Colors.ember.opacity(0.4),
                                    DesignSystem.Colors.amber.opacity(0.25)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 52, height: 52)

                    Image(systemName: "scroll.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    Text("Back up session logs to the cloud?")
                        .font(DesignSystem.Typography.title)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("OpenBurnBar can securely back up your full conversation logs — including provider sessions and OpenBurnBar Assistant history — to your private cloud storage. Access and export them from any device.")
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                featureBullet(
                    icon: "lock.icloud",
                    iconColor: DesignSystem.Colors.whimsy,
                    text: "Stored under your account — no other user can access your logs."
                )
                featureBullet(
                    icon: "arrow.triangle.2.circlepath",
                    iconColor: DesignSystem.Colors.amber,
                    text: "Existing logs are backfilled automatically on first enable."
                )
                featureBullet(
                    icon: "gearshape",
                    iconColor: DesignSystem.Colors.textMuted,
                    text: "Toggle off anytime in Settings → Account."
                )
            }

            Divider().background(DesignSystem.Colors.border.opacity(0.5))

            HStack(spacing: DesignSystem.Spacing.md) {
                Button("Not now") {
                    settingsManager.conversationBackupEnabled = false
                    settingsManager.sessionLogCloudBackupConsentShown = true
                    onDismiss()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Enable Cloud Backup") {
                    settingsManager.conversationBackupEnabled = true
                    settingsManager.sessionLogCloudBackupConsentShown = true
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignSystem.Colors.ember)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DesignSystem.Spacing.xl)
        .frame(minWidth: 440, maxWidth: 520)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .fill(DesignSystem.Colors.surfaceElevated.opacity(0.55))

                LinearGradient(
                    colors: [
                        DesignSystem.Colors.ember.opacity(0.06),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .center
                )
                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous))
            }
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.16), DesignSystem.Colors.border.opacity(0.35)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.5
                    )
            )
        }
    }

    private func featureBullet(icon: String, iconColor: Color, text: String) -> some View {
        Label {
            Text(text)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: 20, alignment: .center)
        }
    }
}
