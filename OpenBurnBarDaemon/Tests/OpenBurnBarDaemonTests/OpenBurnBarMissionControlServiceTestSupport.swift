import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import Foundation

extension BurnBarMissionControlServiceTests {
    func makeHarness(
        name: String,
        transport: BurnBarMissionControlTransport = .live(),
        activitySnapshot: BurnBarControllerActivitySnapshot? = nil,
        reviewRunLauncher: BurnBarMissionControlReviewRunLauncher? = nil,
        runSnapshotLookup: BurnBarMissionControlRunSnapshotLookup? = nil,
        executionReadinessGate: BurnBarExecutionReadinessGate? = { _, _ in nil },
        performanceGuardrails: BurnBarMissionControlPerformanceGuardrails? = nil,
        notificationSecretStore: any BurnBarNotificationSecretStoring = BurnBarInMemoryNotificationSecretStore()
    ) throws -> (service: BurnBarMissionControlService, rootURL: URL) {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-mission-control-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let activitySnapshotURL = rootURL.appendingPathComponent("controller-activity-snapshot.json")
        if let activitySnapshot {
            let data = try JSONEncoder().encode(activitySnapshot)
            try data.write(to: activitySnapshotURL, options: .atomic)
        }

        let store = BurnBarMissionControlStore(
            eventsFileURL: rootURL.appendingPathComponent("controller-events.jsonl"),
            projectionFileURL: rootURL.appendingPathComponent("controller-projection.json"),
            logger: BurnBarDaemonLogger(category: "mission-control-tests"),
            notificationSecretStore: notificationSecretStore
        )
        let service = BurnBarMissionControlService(
            store: store,
            logger: BurnBarDaemonLogger(category: "mission-control-tests"),
            transport: transport,
            activitySnapshotURL: activitySnapshot == nil ? nil : activitySnapshotURL,
            reviewRunLauncher: reviewRunLauncher,
            runSnapshotLookup: runSnapshotLookup,
            usageLedgerURL: rootURL.appendingPathComponent("usage-events.jsonl"),
            executionReadinessGate: executionReadinessGate,
            performanceGuardrails: performanceGuardrails
        )
        return (service, rootURL)
    }

    func makeHarnessWithStore(
        name: String,
        transport: BurnBarMissionControlTransport = .live(),
        executionReadinessGate: BurnBarExecutionReadinessGate? = nil,
        performanceGuardrails: BurnBarMissionControlPerformanceGuardrails? = nil,
        notificationSecretStore: any BurnBarNotificationSecretStoring = BurnBarInMemoryNotificationSecretStore()
    ) throws -> (service: BurnBarMissionControlService, store: BurnBarMissionControlStore, rootURL: URL) {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-mission-control-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let store = BurnBarMissionControlStore(
            eventsFileURL: rootURL.appendingPathComponent("controller-events.jsonl"),
            projectionFileURL: rootURL.appendingPathComponent("controller-projection.json"),
            logger: BurnBarDaemonLogger(category: "mission-control-tests"),
            notificationSecretStore: notificationSecretStore
        )
        let service = BurnBarMissionControlService(
            store: store,
            logger: BurnBarDaemonLogger(category: "mission-control-tests"),
            transport: transport,
            activitySnapshotURL: nil,
            reviewRunLauncher: nil,
            runSnapshotLookup: nil,
            usageLedgerURL: rootURL.appendingPathComponent("usage-events.jsonl"),
            executionReadinessGate: executionReadinessGate,
            performanceGuardrails: performanceGuardrails
        )
        return (service, store, rootURL)
    }

    func makeSeededHarness(
        name: String,
        events: [BurnBarControllerEvent],
        transport: BurnBarMissionControlTransport = .live(),
        executionReadinessGate: BurnBarExecutionReadinessGate? = nil,
        performanceGuardrails: BurnBarMissionControlPerformanceGuardrails? = nil,
        notificationSecretStore: any BurnBarNotificationSecretStoring = BurnBarInMemoryNotificationSecretStore()
    ) throws -> (service: BurnBarMissionControlService, rootURL: URL) {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-mission-control-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let eventsFileURL = rootURL.appendingPathComponent("controller-events.jsonl")
        try writeControllerEvents(events, to: eventsFileURL)

        let store = BurnBarMissionControlStore(
            eventsFileURL: eventsFileURL,
            projectionFileURL: rootURL.appendingPathComponent("controller-projection.json"),
            logger: BurnBarDaemonLogger(category: "mission-control-tests"),
            notificationSecretStore: notificationSecretStore
        )
        let service = BurnBarMissionControlService(
            store: store,
            logger: BurnBarDaemonLogger(category: "mission-control-tests"),
            transport: transport,
            activitySnapshotURL: nil,
            reviewRunLauncher: nil,
            runSnapshotLookup: nil,
            usageLedgerURL: rootURL.appendingPathComponent("usage-events.jsonl"),
            executionReadinessGate: executionReadinessGate,
            performanceGuardrails: performanceGuardrails
        )
        return (service, rootURL)
    }

    func writeControllerEvents(
        _ events: [BurnBarControllerEvent],
        to url: URL
    ) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        var data = Data()
        for event in events {
            data.append(try encoder.encode(event))
            data.append(Data([0x0A]))
        }
        try data.write(to: url, options: .atomic)
    }

    struct BurnBarPublicProjectionSurfaceSnapshot: Equatable {
        let counts: BurnBarControllerCounts
        let missions: [BurnBarMissionSnapshot]
        let questions: [BurnBarPendingQuestionSnapshot]
        let followups: [CanonicalFollowup]
    }

    struct CanonicalFollowup: Equatable {
        let id: BurnBarFollowupID
        let projectSlug: String
        let questionID: BurnBarQuestionID?
        let title: String
        let summary: String
        let stageLabel: String?
        let status: BurnBarFollowupStatus
        let kind: BurnBarFollowupKind
        let createdAt: Date
        let metadata: BurnBarMetadata
    }

    func capturePublicProjectionSurface(
        service: BurnBarMissionControlService,
        projectSlug: String
    ) async throws -> BurnBarPublicProjectionSurfaceSnapshot {
        let summary = try await service.controllerSummary(
            BurnBarControllerSummaryRequest(
                projectSlug: projectSlug,
                includeRecentEvents: false,
                includeProjectionStatus: false
            )
        )
        let questions = try await service.questionsList(
            BurnBarQuestionsListRequest(
                projectSlug: projectSlug,
                statuses: BurnBarPendingQuestionStatus.allCases,
                limit: 500
            )
        )
        let followups = try await service.followupsList(
            BurnBarFollowupsListRequest(
                projectSlug: projectSlug,
                statuses: BurnBarFollowupStatus.allCases,
                limit: 500
            )
        )
        let missions = try await service.missionsList(
            BurnBarMissionListRequest(
                projectSlug: projectSlug,
                statuses: BurnBarMissionStatus.allCases,
                limit: 500
            )
        )

        return BurnBarPublicProjectionSurfaceSnapshot(
            counts: summary.summary.counts,
            missions: missions.missions.sorted { $0.id.rawValue < $1.id.rawValue },
            questions: questions.questions.sorted { $0.id.rawValue < $1.id.rawValue },
            followups: followups.followups
                .sorted { $0.id.rawValue < $1.id.rawValue }
                .map { followup in
                    CanonicalFollowup(
                        id: followup.id,
                        projectSlug: followup.projectSlug,
                        questionID: followup.questionID,
                        title: followup.title,
                        summary: followup.summary,
                        stageLabel: followup.stageLabel,
                        status: followup.status,
                        kind: followup.kind,
                        createdAt: followup.createdAt,
                        metadata: followup.metadata
                    )
                }
        )
    }

    func writeUsageRecord(_ record: BurnBarUsageRecord, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(record) + Data([0x0A])
        try data.write(to: url, options: .atomic)
    }

    func project(slug: String) -> BurnBarReviewProjectSnapshot {
        BurnBarReviewProjectSnapshot(
            id: "project-\(slug)",
            projectSlug: slug,
            displayName: slug.capitalized,
            summary: "Native OpenBurnBar mission-control test project.",
            status: .healthy,
            preferredCadence: .daily,
            freshness: .provisional,
            pendingQuestionCount: 0,
            openFollowupCount: 0,
            activeMissionCount: 0,
            needsOperatorAttention: false
        )
    }

    func project(slug: String, revision: Int) -> BurnBarReviewProjectSnapshot {
        BurnBarReviewProjectSnapshot(
            id: "project-\(slug)",
            projectSlug: slug,
            displayName: "\(slug.capitalized) revision \(revision)",
            summary: "Native OpenBurnBar mission-control test project revision \(revision).",
            status: .healthy,
            preferredCadence: .daily,
            freshness: .provisional,
            pendingQuestionCount: 0,
            openFollowupCount: 0,
            activeMissionCount: 0,
            needsOperatorAttention: false
        )
    }

    func projectUpsertEvent(
        id: String,
        sequence: Int,
        recordedAt: Date,
        project: BurnBarReviewProjectSnapshot
    ) throws -> BurnBarControllerEvent {
        BurnBarControllerEvent(
            id: BurnBarControllerEventID(rawValue: id),
            family: .controller,
            eventType: "project_upserted",
            projectSlug: project.projectSlug,
            recordedAt: recordedAt,
            sequence: sequence,
            summary: project.displayName,
            metadata: ["payload": try BurnBarJSONValue.fromEncodable(project)]
        )
    }

    func boolValue(_ value: BurnBarJSONValue?) -> Bool? {
        guard case .bool(let rawValue)? = value else { return nil }
        return rawValue
    }

    func stringValue(_ value: BurnBarJSONValue?) -> String? {
        guard case .string(let rawValue)? = value else { return nil }
        return rawValue
    }

    func numberValue(_ value: BurnBarJSONValue?) -> Double? {
        guard case .number(let rawValue)? = value else { return nil }
        return rawValue
    }

    func objectValue(_ value: BurnBarJSONValue?) -> [String: BurnBarJSONValue]? {
        guard case .object(let rawValue)? = value else { return nil }
        return rawValue
    }

    func stringArrayValue(_ value: BurnBarJSONValue?) -> [String]? {
        guard case .array(let rawValues)? = value else { return nil }
        return rawValues.compactMap { item in
            guard case .string(let stringValue) = item else { return nil }
            return stringValue
        }
    }

    func waitUntil(
        timeoutNanoseconds: UInt64 = 3_000_000_000,
        pollNanoseconds: UInt64 = 50_000_000,
        condition: @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: pollNanoseconds)
        }

        return await condition()
    }
}

actor TransportRecorder {
    private(set) var localNotifications: [(title: String, body: String)] = []
    private(set) var telegramMessages: [(token: String, chatID: String, text: String)] = []

    func recordLocal(title: String, body: String) {
        localNotifications.append((title, body))
    }

    func recordTelegram(token: String, chatID: String, text: String) {
        telegramMessages.append((token, chatID, text))
    }
}

actor ReviewLauncherRecorder {
    struct Launch: Sendable {
        let prompt: String
        let modelID: String
        let metadata: BurnBarRunCreateMetadata
    }

    private(set) var launches: [Launch] = []

    func record(prompt: String, modelID: String, metadata: BurnBarRunCreateMetadata) {
        launches.append(Launch(prompt: prompt, modelID: modelID, metadata: metadata))
    }
}
