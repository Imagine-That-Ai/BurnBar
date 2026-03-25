import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Source Filter

private enum SessionLogSourceFilter: String, CaseIterable, Identifiable {
    case all      = "All"
    case provider = "Provider"
    case assistant = "Assistant"
    var id: String { rawValue }
}

// MARK: - Group Mode

private enum SessionLogGroupMode: String, CaseIterable, Identifiable {
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

private enum SessionLogDataSource: String, CaseIterable, Identifiable {
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

private struct SessionLogGroup: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let accentColor: Color
    let logs: [ConversationRecord]
}

// MARK: - Session Logs View

struct SessionLogsView: View {
    var dataStore: DataStore
    var accountManager: AccountManager
    var settingsManager: SettingsManager
    var cloudSyncService: CloudSyncService?
    var iCloudMirrorService: ICloudSessionMirrorService?

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

    private let defaultDisplayLimit = 15

    // MARK: - Filtering

    private var sourceFilteredLogs: [ConversationRecord] {
        switch sourceFilter {
        case .all:
            return allLogs
        case .provider:
            return allLogs.filter { $0.sourceType == .providerLog }
        case .assistant:
            return allLogs.filter { $0.sourceType == .cliAssistant }
        }
    }

    private var filteredLogs: [ConversationRecord] {
        let result = sourceFilteredLogs
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
        return allLogs.first { $0.id == id }
    }

    // MARK: - Grouping

    private var logGroups: [SessionLogGroup] {
        let logs = filteredLogs
        switch groupMode {
        case .time: return timeGroups(from: logs)
        case .provider: return providerGroups(from: logs)
        case .project: return projectGroups(from: logs)
        }
    }

    private func timeGroups(from logs: [ConversationRecord]) -> [SessionLogGroup] {
        let calendar = Calendar.current
        let now = Date()
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
            ("older", "Older", "archivebox.fill", DesignSystem.Colors.textMuted),
        ]
        return defs.compactMap { d in
            guard let logs = buckets[d.id], !logs.isEmpty else { return nil }
            return SessionLogGroup(id: d.id, title: d.title, systemImage: d.icon, accentColor: d.color, logs: logs)
        }
    }

    private func providerGroups(from logs: [ConversationRecord]) -> [SessionLogGroup] {
        Dictionary(grouping: logs) { $0.provider }
            .map { provider, logs in
                SessionLogGroup(
                    id: "provider-\(provider.rawValue)",
                    title: provider.displayName,
                    systemImage: provider.iconName,
                    accentColor: DesignSystem.Colors.primary(for: provider),
                    logs: logs
                )
            }
            .sorted { $0.logs.count > $1.logs.count }
    }

    private func projectGroups(from logs: [ConversationRecord]) -> [SessionLogGroup] {
        Dictionary(grouping: logs) { $0.projectName }
            .map { project, logs in
                SessionLogGroup(
                    id: "project-\(project)",
                    title: project.isEmpty ? "Unknown" : project,
                    systemImage: "folder.fill",
                    accentColor: DesignSystem.Colors.amber,
                    logs: logs
                )
            }
            .sorted { $0.logs.count > $1.logs.count }
    }

    // MARK: - Body

    var body: some View {
        HStack(spacing: 0) {
            commandCenter
                .frame(width: 340)

            Divider().background(DesignSystem.Colors.border)

            detailPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.clear)
        .task {
            await loadLogs()
        }
        .onChange(of: searchText) { _, _ in
            Task { await runLocalRetrievalSearchIfNeeded() }
        }
        .onChange(of: sourceFilter) { _, _ in
            Task {
                await runLocalRetrievalSearchIfNeeded()
                reconcileSelectionWithFilteredLogs()
            }
        }
        .onChange(of: groupMode) { _, _ in
            sectionDisplayLimits = [:]
            let groups = logGroups
            expandedSections = Set(groups.prefix(1).map(\.id))
        }
        .onChange(of: dataSource) { _, _ in
            selectedId = nil
            cloudBodyCache = [:]
            Task { await loadLogs() }
        }
        .onChange(of: settingsManager.conversationIndexingEnabled) { _, _ in
            refreshRetrievalHealth()
            Task { await runLocalRetrievalSearchIfNeeded() }
        }
        .onChange(of: settingsManager.preferredIndexEmbeddingVersionID) { _, _ in
            retrievalSearchService = SearchService.makeConversationSearchService(
                dataStore: dataStore,
                settingsManager: settingsManager
            )
            refreshRetrievalHealth()
            Task { await runLocalRetrievalSearchIfNeeded() }
        }
        .onChange(of: accountManager.isSignedIn) { _, _ in
            refreshRetrievalHealth()
        }
        .onChange(of: selectedId) { _, newId in
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
                .padding(.bottom, DesignSystem.Spacing.md)

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
                Button {
                    withAnimation(DesignSystem.Animation.snappy) {
                        sourceFilter = filter
                    }
                } label: {
                    Text(filter.rawValue)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(
                            sourceFilter == filter
                                ? DesignSystem.Colors.textPrimary
                                : DesignSystem.Colors.textMuted
                        )
                        .padding(.horizontal, DesignSystem.Spacing.md)
                        .padding(.vertical, DesignSystem.Spacing.xs)
                        .background(
                            RoundedRectangle(cornerRadius: DesignSystem.Radius.full, style: .continuous)
                                .fill(
                                    sourceFilter == filter
                                        ? AnyShapeStyle(filterAccent(for: filter).opacity(0.18))
                                        : AnyShapeStyle(DesignSystem.Colors.surfaceElevated.opacity(0.4))
                                )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DesignSystem.Radius.full, style: .continuous)
                                .strokeBorder(
                                    sourceFilter == filter
                                        ? filterAccent(for: filter).opacity(0.45)
                                        : DesignSystem.Colors.border.opacity(0.3),
                                    lineWidth: 0.5
                                )
                        )
                }
                .buttonStyle(.plain)
            }

            Spacer()

            HStack(spacing: 2) {
                ForEach(SessionLogGroupMode.allCases) { mode in
                    Button {
                        withAnimation(DesignSystem.Animation.snappy) {
                            groupMode = mode
                        }
                    } label: {
                        Image(systemName: mode.icon)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(groupMode == mode ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textMuted)
                            .frame(width: 24, height: 20)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(groupMode == mode ? DesignSystem.Colors.surfaceElevated : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Group by \(mode.rawValue.lowercased())")
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

            Menu {
                ForEach(SessionLogDataSource.allCases) { source in
                    Button {
                        withAnimation(DesignSystem.Animation.snappy) { dataSource = source }
                    } label: {
                        Label(source.rawValue, systemImage: source.icon)
                    }
                }
            } label: {
                Image(systemName: dataSource.icon)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(dataSource == .local ? DesignSystem.Colors.textMuted : DesignSystem.Colors.ember)
                    .frame(width: 24, height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(dataSource == .local ? Color.clear : DesignSystem.Colors.ember.opacity(0.12))
                    )
            }
            .menuStyle(.borderlessButton)
            .help("Data source: \(dataSource.rawValue)")
        }
    }

    private func filterAccent(for filter: SessionLogSourceFilter) -> Color {
        switch filter {
        case .all:       return DesignSystem.Colors.ember
        case .provider:  return DesignSystem.Colors.amber
        case .assistant: return DesignSystem.Colors.whimsy
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
        .scrollContentBackground(.hidden)
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

                Image(systemName: group.systemImage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(group.accentColor)

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
    }

    @ViewBuilder
    private func sectionContent(for group: SessionLogGroup) -> some View {
        let limit = sectionDisplayLimits[group.id] ?? defaultDisplayLimit
        let showing = Array(group.logs.prefix(limit))

        VStack(spacing: DesignSystem.Spacing.xxs) {
            ForEach(showing) { record in
                CompactSessionRow(
                    record: record,
                    isSelected: selectedId == record.id
                ) {
                    withAnimation(DesignSystem.Animation.snappy) {
                        selectedId = record.id
                    }
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
                    Text("Cloud logs require a BurnBar account. Sign in via Settings.")
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
                        ? "Start a chat with the BurnBar Assistant, or scan your provider sessions."
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
                overrideBody: dataSource == .cloud ? cloudBodyCache[log.sessionId] : nil
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

    // MARK: - Data Loading

    private func substringFilteredLogs(from logs: [ConversationRecord], query: String) -> [ConversationRecord] {
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

    private func loadLogs() async {
        isLoading = true
        dataSourceError = nil
        refreshRetrievalHealth()
        do {
            switch dataSource {
            case .local:
                let messages = try dataStore.fetchChatMessages()
                if !messages.isEmpty { try dataStore.upsertCLIConversation(from: messages) }
                allLogs = try dataStore.fetchAllSessionLogs()

            case .cloud:
                if let svc = cloudSyncService {
                    allLogs = try await svc.fetchCloudSessionLogs()
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

        await runLocalRetrievalSearchIfNeeded()
        reconcileSelectionWithFilteredLogs()
        if expandedSections.isEmpty, let firstId = logGroups.first?.id {
            expandedSections = [firstId]
        }
        isLoading = false
    }
}

// MARK: - Compact Session Row

private struct CompactSessionRow: View {
    let record: ConversationRecord
    let isSelected: Bool
    let action: () -> Void

    private var accentColor: Color {
        record.sourceType == .cliAssistant
            ? DesignSystem.Colors.whimsy
            : DesignSystem.Colors.primary(for: record.provider)
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

                VStack(alignment: .leading, spacing: 2) {
                    Text(displayTitle)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(isSelected ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary)
                        .lineLimit(1)

                    HStack(spacing: DesignSystem.Spacing.xs) {
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
    }
}

// MARK: - Session Log Detail Pane

private struct SessionLogDetailPane: View {
    let record: ConversationRecord
    var dataStore: DataStore
    var overrideBody: String?

    @State private var markdownBody = ""
    @State private var copyConfirmed = false

    private var accentColor: Color {
        record.sourceType == .cliAssistant
            ? DesignSystem.Colors.whimsy
            : DesignSystem.Colors.amber
    }

    private var displayTitle: String {
        if let summaryTitle = record.summaryTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summaryTitle.isEmpty {
            return summaryTitle
        }
        return record.inferredTaskTitle.isEmpty ? "Session" : record.inferredTaskTitle
    }

    var body: some View {
        VStack(spacing: 0) {
            detailHeader
            Divider().background(DesignSystem.Colors.border.opacity(0.5))

            ScrollView {
                Text(.init(markdownBody.isEmpty ? "Loading…" : markdownBody))
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(DesignSystem.Spacing.xl)
            }
            .scrollContentBackground(.hidden)

            Divider().background(DesignSystem.Colors.border.opacity(0.5))

            actionBar
        }
        .background(Color.clear)
        .task { buildMarkdown() }
        .onChange(of: overrideBody) { _, newBody in
            if let newBody, !newBody.isEmpty { markdownBody = newBody }
        }
    }

    private var detailHeader: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                HStack(spacing: DesignSystem.Spacing.xs) {
                    if record.sourceType == .cliAssistant {
                        Image(systemName: "terminal.fill")
                            .font(.system(size: 9, weight: .semibold))
                    } else {
                        Image(systemName: "externaldrive.fill")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    Text(record.sourceType == .cliAssistant ? "Assistant" : record.provider.displayName)
                        .font(DesignSystem.Typography.tiny)
                }
                .foregroundStyle(accentColor)
                .padding(.horizontal, DesignSystem.Spacing.sm)
                .padding(.vertical, DesignSystem.Spacing.xxs)
                .background(
                    Capsule().fill(accentColor.opacity(0.14))
                )
                .overlay(
                    Capsule().strokeBorder(accentColor.opacity(0.35), lineWidth: 0.5)
                )

                Text(record.projectName)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)

                Spacer(minLength: 0)

                if let date = record.endTime ?? record.startTime {
                    Text(date.relativeLabel)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            }

            Text(displayTitle)
                .font(DesignSystem.Typography.title)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: DesignSystem.Spacing.sm) {
                metaChip(icon: "bubble.left.and.bubble.right", label: "\(record.messageCount) messages")
                if record.userWordCount > 0 {
                    metaChip(icon: "textformat", label: "\(record.userWordCount + record.assistantWordCount) words")
                }
                if record.sourceType == .providerLog, let start = record.startTime, let end = record.endTime {
                    let duration = end.timeIntervalSince(start)
                    if duration > 60 {
                        metaChip(icon: "clock", label: durationLabel(duration))
                    }
                }
            }
        }
        .padding(DesignSystem.Spacing.xl)
        .background(Color.clear)
    }

    private func metaChip(icon: String, label: String) -> some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .medium))
            Text(label)
                .font(DesignSystem.Typography.tiny)
        }
        .foregroundStyle(DesignSystem.Colors.textMuted)
        .padding(.horizontal, DesignSystem.Spacing.sm)
        .padding(.vertical, DesignSystem.Spacing.xxs)
        .background(
            Capsule().fill(DesignSystem.Colors.surfaceElevated.opacity(0.5))
        )
        .overlay(
            Capsule().strokeBorder(DesignSystem.Colors.border.opacity(0.4), lineWidth: 0.5)
        )
    }

    private var actionBar: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            Spacer()

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(markdownBody, forType: .string)
                withAnimation(DesignSystem.Animation.snappy) { copyConfirmed = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                    withAnimation(DesignSystem.Animation.snappy) { copyConfirmed = false }
                }
            } label: {
                Label(
                    copyConfirmed ? "Copied!" : "Copy Markdown",
                    systemImage: copyConfirmed ? "checkmark" : "doc.on.doc"
                )
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(copyConfirmed ? DesignSystem.Colors.success : accentColor)
            }
            .buttonStyle(.plain)
            .disabled(markdownBody.isEmpty)

            Button {
                exportMarkdown()
            } label: {
                Label("Export .md", systemImage: "arrow.down.doc")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            .buttonStyle(.plain)
            .disabled(markdownBody.isEmpty)
        }
        .padding(.horizontal, DesignSystem.Spacing.xl)
        .padding(.vertical, DesignSystem.Spacing.md)
    }

    private func buildMarkdown() {
        if let body = overrideBody, !body.isEmpty {
            markdownBody = body
        } else {
            markdownBody = SessionLogMarkdownFormatter.markdown(for: record)
        }
    }

    private func exportMarkdown() {
        let panel = NSSavePanel()
        let slug = displayTitle.isEmpty ? "session" : displayTitle
        let safe = slug
            .components(separatedBy: .alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
            .lowercased()
            .prefix(60)
        panel.nameFieldStringValue = "\(safe).md"
        if let mdType = UTType(filenameExtension: "md") {
            panel.allowedContentTypes = [mdType]
        }
        panel.title = "Export session log"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? markdownBody.write(to: url, atomically: true, encoding: .utf8)
    }

    private func durationLabel(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds / 60)
        return mins < 60 ? "\(mins)m" : "\(mins / 60)h \(mins % 60)m"
    }
}

// MARK: - Date Relative Label

private extension Date {
    var relativeLabel: String {
        let interval = Date().timeIntervalSince(self)
        switch interval {
        case ..<60:          return "Just now"
        case ..<3_600:       return "\(Int(interval / 60))m ago"
        case ..<86_400:      return "\(Int(interval / 3_600))h ago"
        case ..<604_800:     return "\(Int(interval / 86_400))d ago"
        default:
            let fmt = DateFormatter()
            fmt.dateStyle = .medium
            fmt.timeStyle = .none
            return fmt.string(from: self)
        }
    }
}

// MARK: - Session Log Cloud Consent Sheet

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

                    Text("BurnBar can securely back up your full conversation logs — including provider sessions and BurnBar Assistant history — to your private cloud storage. Access and export them from any device.")
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
                    settingsManager.sessionLogCloudBackupEnabled = false
                    settingsManager.sessionLogCloudBackupConsentShown = true
                    onDismiss()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Enable Cloud Backup") {
                    settingsManager.sessionLogCloudBackupEnabled = true
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
