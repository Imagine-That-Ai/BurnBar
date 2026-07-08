import SwiftUI
import OpenBurnBarCore

extension SessionLogsView {
    // MARK: - Filtering

    /// Cache key for the memoized filter → group pipeline. `localDeviceId`
    /// covers the `knownDevices` dependency of device filtering; `dayStamp`
    /// re-derives the Today/Yesterday/This Week buckets after midnight or a
    /// timezone change, matching the old recompute-on-every-body-eval
    /// behaviour.
    struct LogGroupsCacheKey: Equatable {
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
    final class LogGroupsCache {
        var key: LogGroupsCacheKey?
        var filteredLogs: [OpenBurnBarCore.ConversationRecord] = []
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
    var filteredLogs: [OpenBurnBarCore.ConversationRecord] {
        rebuildLogGroupsIfNeeded()
        return logGroupsCache.filteredLogs
    }

    var logGroups: [SessionLogGroup] {
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
        allLogs: [OpenBurnBarCore.ConversationRecord],
        sourceFilter: SessionLogSourceFilter,
        deviceFilter: String?,
        localDeviceId: String?,
        searchText: String,
        dataSource: SessionLogDataSource,
        retrievalMatchedIDs: [String]
    ) -> [OpenBurnBarCore.ConversationRecord] {
        var result: [OpenBurnBarCore.ConversationRecord]
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

    var visibleDegradedModes: [RetrievalDegradedState] {
        retrievalHealthSnapshot.degradedModes.filter { state in
            if dataSource == .local {
                return state.mode != .cloudSharedUnavailable
            }
            return true
        }
    }

    var selectedLog: OpenBurnBarCore.ConversationRecord? {
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
        from logs: [OpenBurnBarCore.ConversationRecord],
        groupMode: SessionLogGroupMode,
        now: Date = Date()
    ) -> [SessionLogGroup] {
        switch groupMode {
        case .time: return timeGroups(from: logs, now: now)
        case .provider: return providerGroups(from: logs)
        case .project: return projectGroups(from: logs)
        }
    }

    private static func timeGroups(from logs: [OpenBurnBarCore.ConversationRecord], now: Date) -> [SessionLogGroup] {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday)!
        let startOfWeek = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))!
        let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!

        var buckets: [String: [OpenBurnBarCore.ConversationRecord]] = [
            "today": [], "yesterday": [], "week": [], "month": [], "older": []
        ]
        for log in logs {
            // Bucket by when the session actually occurred — start first, then end.
            // Avoid preferring endTime alone (some pipelines align it with re-import);
            // fileModifiedAt beats indexedAt for "last known log activity" when times are missing.
            let date = log.startTime ?? log.endTime ?? log.fileModifiedAt ?? log.indexedAt
            if date >= startOfToday {
                buckets["today", default: []].append(log)
            } else if date >= startOfYesterday {
                buckets["yesterday", default: []].append(log)
            } else if date >= startOfWeek {
                buckets["week", default: []].append(log)
            } else if date >= startOfMonth {
                buckets["month", default: []].append(log)
            } else {
                buckets["older", default: []].append(log)
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

    private static func providerGroups(from logs: [OpenBurnBarCore.ConversationRecord]) -> [SessionLogGroup] {
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

    private static func projectGroups(from logs: [OpenBurnBarCore.ConversationRecord]) -> [SessionLogGroup] {
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

    private static func substringFilteredLogs(from logs: [OpenBurnBarCore.ConversationRecord], query: String) -> [OpenBurnBarCore.ConversationRecord] {
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
}
