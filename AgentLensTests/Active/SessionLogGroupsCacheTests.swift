import XCTest
@testable import OpenBurnBar
@testable import OpenBurnBarCore

/// Pins the pure filter→group pipeline behind `SessionLogsView`'s memoized
/// `filteredLogs`/`logGroups` (`computeFilteredLogs` / `computeLogGroups`),
/// mirroring `ProjectsMergedProjectsCacheTests` for
/// `ProjectsView.computeMergedProjects`.
@MainActor
final class SessionLogGroupsCacheTests: XCTestCase {

    // MARK: - Fixtures

    private func record(
        id: String,
        provider: AgentProvider = .claudeCode,
        project: String = "alpha",
        sourceType: ConversationSourceType = .providerLog,
        startTime: Date? = Date(),
        fileModifiedAt: Date? = nil,
        title: String = "Session",
        fullText: String = "",
        sourceDeviceId: String? = nil,
        isRemote: Bool = false
    ) -> ConversationRecord {
        ConversationRecord(
            id: id,
            provider: provider,
            sessionId: id,
            projectName: project,
            startTime: startTime,
            endTime: nil,
            messageCount: 1,
            userWordCount: 0,
            assistantWordCount: 0,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: title,
            lastAssistantMessage: "",
            fullText: fullText,
            fileModifiedAt: fileModifiedAt,
            sourceType: sourceType,
            sourceDeviceId: sourceDeviceId,
            isRemote: isRemote
        )
    }

    private func filtered(
        _ logs: [ConversationRecord],
        sourceFilter: SessionLogSourceFilter = .all,
        deviceFilter: String? = nil,
        localDeviceId: String? = nil,
        searchText: String = "",
        dataSource: SessionLogDataSource = .local,
        retrievalMatchedIDs: [String] = []
    ) -> [ConversationRecord] {
        SessionLogsView.computeFilteredLogs(
            allLogs: logs,
            sourceFilter: sourceFilter,
            deviceFilter: deviceFilter,
            localDeviceId: localDeviceId,
            searchText: searchText,
            dataSource: dataSource,
            retrievalMatchedIDs: retrievalMatchedIDs
        )
    }

    // MARK: - Filtering

    func testFilter_sourceFilter_partitionsProviderAndAssistant() {
        let logs = [
            record(id: "p1", sourceType: .providerLog),
            record(id: "a1", sourceType: .cliAssistant),
            record(id: "p2", sourceType: .providerLog)
        ]
        XCTAssertEqual(filtered(logs, sourceFilter: .all).map(\.id), ["p1", "a1", "p2"])
        XCTAssertEqual(filtered(logs, sourceFilter: .provider).map(\.id), ["p1", "p2"])
        XCTAssertEqual(filtered(logs, sourceFilter: .assistant).map(\.id), ["a1"])
    }

    func testFilter_deviceFilter_matchesRemoteByIdAndLocalByLocalDevice() {
        let logs = [
            record(id: "remote-match", sourceDeviceId: "dev-2", isRemote: true),
            record(id: "remote-other", sourceDeviceId: "dev-1", isRemote: true),
            record(id: "local", sourceDeviceId: nil, isRemote: false)
        ]
        XCTAssertEqual(
            filtered(logs, deviceFilter: "dev-2", localDeviceId: "dev-2").map(\.id),
            ["remote-match", "local"]
        )
        XCTAssertEqual(
            filtered(logs, deviceFilter: "dev-2", localDeviceId: "dev-9").map(\.id),
            ["remote-match"]
        )
    }

    func testFilter_localSearch_followsRetrievalOrderAndDropsUnknownIDs() {
        let logs = [record(id: "a"), record(id: "b"), record(id: "c")]
        XCTAssertEqual(
            filtered(logs, searchText: "query", retrievalMatchedIDs: ["c", "missing", "a"]).map(\.id),
            ["c", "a"]
        )
    }

    func testFilter_localSearch_noMatchesYieldsEmpty() {
        let logs = [record(id: "a")]
        XCTAssertTrue(filtered(logs, searchText: "query").isEmpty)
    }

    func testFilter_blankQuery_skipsSearchEntirely() {
        let logs = [record(id: "a"), record(id: "b")]
        XCTAssertEqual(
            filtered(logs, searchText: "   ", retrievalMatchedIDs: ["b"]).map(\.id),
            ["a", "b"]
        )
    }

    func testFilter_cloudSearch_substringMatchesAcrossFields() {
        let logs = [
            record(id: "title", title: "Fix Login Crash"),
            record(id: "project", project: "burnbar-website", title: "Other"),
            record(id: "body", title: "Other", fullText: "stack trace mentions login token"),
            record(id: "none", project: "misc", title: "Other", fullText: "irrelevant")
        ]
        XCTAssertEqual(
            filtered(logs, searchText: "login", dataSource: .cloud).map(\.id),
            ["title", "body"]
        )
        XCTAssertEqual(
            filtered(logs, searchText: "WEBSITE", dataSource: .cloud).map(\.id),
            ["project"]
        )
    }

    // MARK: - Grouping

    func testGroups_timeMode_bucketsByOccurrenceAndOmitsEmptyBuckets() {
        let calendar = Calendar.current
        // Thursday 2026-06-18 noon: mid-week and mid-month, so every bucket
        // boundary is distinct for Sat/Sun/Mon week-start locales.
        let now = calendar.date(from: DateComponents(year: 2026, month: 6, day: 18, hour: 12))!
        func day(_ d: Int, month: Int = 6, hour: Int = 12) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: month, day: d, hour: hour))!
        }

        let logs = [
            record(id: "today", startTime: day(18, hour: 13)),
            record(id: "yesterday", startTime: day(17)),
            record(id: "week", startTime: day(16)),
            record(id: "month", startTime: day(2)),
            record(id: "older", startTime: day(15, month: 5)),
            // startTime/endTime nil → bucketing falls back to fileModifiedAt.
            record(id: "fallback", startTime: nil, fileModifiedAt: day(17))
        ]
        let groups = SessionLogsView.computeLogGroups(from: logs, groupMode: .time, now: now)

        XCTAssertEqual(groups.map(\.id), ["today", "yesterday", "week", "month", "older"])
        XCTAssertEqual(groups.map(\.title), ["Today", "Yesterday", "This Week", "This Month", "Older"])
        XCTAssertEqual(groups[0].logs.map(\.id), ["today"])
        XCTAssertEqual(groups[1].logs.map(\.id), ["yesterday", "fallback"])

        // Empty buckets are omitted entirely, not rendered as zero-count rows.
        let olderOnly = SessionLogsView.computeLogGroups(
            from: [record(id: "older", startTime: day(15, month: 5))],
            groupMode: .time,
            now: now
        )
        XCTAssertEqual(olderOnly.map(\.id), ["older"])
    }

    func testGroups_providerMode_sortsByCountDescending() {
        let logs = [
            record(id: "f1", provider: .factory),
            record(id: "f2", provider: .factory),
            record(id: "f3", provider: .factory),
            record(id: "c1", provider: .claudeCode)
        ]
        let groups = SessionLogsView.computeLogGroups(from: logs, groupMode: .provider)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].provider, .factory)
        XCTAssertEqual(groups[0].logs.count, 3)
        XCTAssertEqual(groups[0].id, "provider-\(AgentProvider.factory.rawValue)")
        XCTAssertEqual(groups[1].provider, .claudeCode)
        XCTAssertEqual(groups[1].logs.count, 1)
    }

    func testGroups_projectMode_titlesEmptyProjectUnknown() {
        let logs = [
            record(id: "a1", project: "alpha"),
            record(id: "a2", project: "alpha"),
            record(id: "u1", project: "")
        ]
        let groups = SessionLogsView.computeLogGroups(from: logs, groupMode: .project)
        XCTAssertEqual(groups.map(\.title), ["alpha", "Unknown"])
        XCTAssertEqual(groups.map(\.id), ["project-alpha", "project-"])
        XCTAssertEqual(groups[0].logs.count, 2)
    }

    // MARK: - Determinism

    func testCompute_isPure_sameInputsProduceSameOutputs() {
        let logs = [
            record(id: "p1", provider: .factory, project: "alpha"),
            record(id: "p2", provider: .claudeCode, project: "beta"),
            record(id: "a1", sourceType: .cliAssistant)
        ]
        let now = Date()
        for mode in SessionLogGroupMode.allCases {
            let a = SessionLogsView.computeLogGroups(from: logs, groupMode: mode, now: now)
            let b = SessionLogsView.computeLogGroups(from: logs, groupMode: mode, now: now)
            XCTAssertEqual(a.map(\.id), b.map(\.id))
            XCTAssertEqual(a.map { $0.logs.map(\.id) }, b.map { $0.logs.map(\.id) })
        }
        let f1 = filtered(logs, sourceFilter: .provider)
        let f2 = filtered(logs, sourceFilter: .provider)
        XCTAssertEqual(f1.map(\.id), f2.map(\.id))
    }
}
