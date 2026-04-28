import Foundation
import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

// MARK: - MockBurnBarDaemonSocketClient

/// Test double conforming to `BurnBarDaemonSocketClientProtocol`.
/// Every method has a configurable closure so tests can inject canned
/// responses or thrown errors without a live daemon process.
struct MockBurnBarDaemonSocketClient: BurnBarDaemonSocketClientProtocol {

    var healthHandler: (URL) throws -> BurnBarHealthResponse = { _ in
        BurnBarHealthResponse(ok: true, daemonVersion: "mock", protocolVersion: BurnBarProtocolVersion.current, socketPath: nil)
    }

    var configHandler: (URL) throws -> BurnBarProviderConfigurationSnapshot = { _ in
        BurnBarProviderConfigurationSnapshot(providers: [])
    }

    var updateConfigHandler: (BurnBarProviderConfigurationSnapshot, URL) throws -> BurnBarProviderConfigurationSnapshot = { snapshot, _ in
        snapshot
    }

    var recentUsageHandler: (URL, Int) throws -> [BurnBarUsageEvent] = { _, _ in
        []
    }

    var connectorPlaneHandler: (URL) throws -> BurnBarConnectorPlaneSnapshot = { _ in
        BurnBarConnectorPlaneSnapshot(updatedAt: Date(), connectors: [])
    }

    var updateConnectorConfigHandler: (BurnBarConnectorConfigUpdateRequest, URL) throws -> BurnBarConnectorPlaneSnapshot = { _, _ in
        BurnBarConnectorPlaneSnapshot(updatedAt: Date(), connectors: [])
    }

    var performConnectorActionHandler: (BurnBarConnectorActionRequest, URL) throws -> BurnBarConnectorActionResponse = { request, _ in
        BurnBarConnectorActionResponse(
            kind: request.kind,
            action: request.action,
            ok: true,
            summary: "OK",
            detail: nil,
            payload: nil,
            recordedAt: Date()
        )
    }

    var browserToolingHandler: (URL) throws -> BurnBarBrowserToolingSnapshot = { _ in
        BurnBarBrowserToolingSnapshot(
            updatedAt: Date(),
            preferredEngine: .systemBrowser,
            allowExternalNavigation: false,
            engines: []
        )
    }

    var updateBrowserToolingHandler: (BurnBarBrowserToolingUpdateRequest, URL) throws -> BurnBarBrowserToolingSnapshot = { _, _ in
        BurnBarBrowserToolingSnapshot(
            updatedAt: Date(),
            preferredEngine: .systemBrowser,
            allowExternalNavigation: false,
            engines: []
        )
    }

    var performBrowserActionHandler: (BurnBarBrowserActionRequest, URL) throws -> BurnBarBrowserActionResponse = { request, _ in
        BurnBarBrowserActionResponse(
            action: request.action,
            engine: request.preferredEngine ?? .systemBrowser,
            ok: true,
            summary: "OK",
            detail: nil,
            title: nil,
            document: nil,
            links: [],
            recordedAt: Date()
        )
    }

    var updateNotificationConfigHandler: (BurnBarNotificationConfig, URL) throws -> BurnBarNotificationConfig = { config, _ in
        config
    }

    var controllerProjectsHandler: (URL) throws -> [BurnBarReviewProjectSnapshot] = { _ in
        []
    }

    var upsertControllerProjectHandler: (BurnBarReviewProjectSnapshot, URL) throws -> BurnBarReviewProjectSnapshot? = { project, _ in
        project
    }

    var missionCreateHandler: (BurnBarMissionCreateRequest, URL) throws -> BurnBarMissionMutationResponse = { _, _ in
        BurnBarMissionMutationResponse(
            mission: BurnBarMissionSnapshot(
                id: BurnBarMissionID(rawValue: "mock-mission"),
                projectSlug: "mock",
                title: "Mock Mission",
                summary: "Mock",
                status: .draft,
                recommendation: .proceed,
                createdAt: Date(),
                updatedAt: Date(),
                approval: BurnBarMissionApprovalSnapshot(approved: false, approvedAt: nil, approvedBy: nil),
                packets: [],
                results: [],
                burnRecords: [],
                takeoverHistory: nil,
                prLinkage: nil,
                metadata: [:]
            ),
            emittedEvent: nil
        )
    }

    var recordControllerReviewRunHandler: (BurnBarReviewRunSnapshot, URL) throws -> BurnBarControllerReviewRunRecordResponse = { run, _ in
        BurnBarControllerReviewRunRecordResponse(
            run: run,
            summary: BurnBarControllerSummary(
                updatedAt: Date(),
                activeProjectSlug: run.projectSlug,
                counts: BurnBarControllerCounts(
                    projectCount: 1,
                    pendingQuestionCount: run.questionCount,
                    openFollowupCount: run.followupCount,
                    activeMissionCount: run.missionCount,
                    staleProjectCount: 0
                ),
                freshness: .fresh
            )
        )
    }

    var controllerRuntimeSnapshotHandler: (URL) throws -> OpenBurnBarControllerRuntimeSnapshot = { _ in
        OpenBurnBarControllerRuntimeSnapshot(
            source: .daemon,
            updatedAt: Date(),
            summary: OpenBurnBarControllerSummary(
                headline: "Mock controller runtime",
                detail: "Mock",
                pendingQuestions: 0,
                unresolvedFollowups: 0,
                openMissions: 0,
                replayLabel: "Replay idle",
                notificationLabel: "Notifications optional"
            ),
            questions: [],
            followups: [],
            missions: [],
            recentEvents: []
        )
    }

    var answerControllerQuestionHandler: (String, String, String?, URL) throws -> OpenBurnBarControllerRuntimeSnapshot? = { _, _, _, _ in
        nil
    }

    var completeControllerFollowupHandler: (String, URL) throws -> OpenBurnBarControllerRuntimeSnapshot? = { _, _ in
        nil
    }

    var snoozeControllerFollowupHandler: (String, Date, URL) throws -> OpenBurnBarControllerRuntimeSnapshot? = { _, _, _ in
        nil
    }

    var scheduleControllerFollowupCalendarHandler: (String, String?, Date, Int, URL) throws -> OpenBurnBarControllerRuntimeSnapshot? = { _, _, _, _, _ in
        nil
    }

    // MARK: - Protocol Conformance

    func health(at socketURL: URL) throws -> BurnBarHealthResponse {
        try healthHandler(socketURL)
    }

    func config(at socketURL: URL) throws -> BurnBarProviderConfigurationSnapshot {
        try configHandler(socketURL)
    }

    func updateConfig(
        _ snapshot: BurnBarProviderConfigurationSnapshot,
        at socketURL: URL
    ) throws -> BurnBarProviderConfigurationSnapshot {
        try updateConfigHandler(snapshot, socketURL)
    }

    func recentUsage(at socketURL: URL, limit: Int) throws -> [BurnBarUsageEvent] {
        try recentUsageHandler(socketURL, limit)
    }

    func connectorPlane(at socketURL: URL) throws -> BurnBarConnectorPlaneSnapshot {
        try connectorPlaneHandler(socketURL)
    }

    func updateConnectorConfig(
        _ request: BurnBarConnectorConfigUpdateRequest,
        at socketURL: URL
    ) throws -> BurnBarConnectorPlaneSnapshot {
        try updateConnectorConfigHandler(request, socketURL)
    }

    func performConnectorAction(
        _ request: BurnBarConnectorActionRequest,
        at socketURL: URL
    ) throws -> BurnBarConnectorActionResponse {
        try performConnectorActionHandler(request, socketURL)
    }

    func browserTooling(at socketURL: URL) throws -> BurnBarBrowserToolingSnapshot {
        try browserToolingHandler(socketURL)
    }

    func updateBrowserTooling(
        _ request: BurnBarBrowserToolingUpdateRequest,
        at socketURL: URL
    ) throws -> BurnBarBrowserToolingSnapshot {
        try updateBrowserToolingHandler(request, socketURL)
    }

    func performBrowserAction(
        _ request: BurnBarBrowserActionRequest,
        at socketURL: URL
    ) throws -> BurnBarBrowserActionResponse {
        try performBrowserActionHandler(request, socketURL)
    }

    func updateNotificationConfig(
        _ config: BurnBarNotificationConfig,
        at socketURL: URL
    ) throws -> BurnBarNotificationConfig {
        try updateNotificationConfigHandler(config, socketURL)
    }

    func controllerProjects(at socketURL: URL) throws -> [BurnBarReviewProjectSnapshot] {
        try controllerProjectsHandler(socketURL)
    }

    func upsertControllerProject(
        _ project: BurnBarReviewProjectSnapshot,
        at socketURL: URL
    ) throws -> BurnBarReviewProjectSnapshot? {
        try upsertControllerProjectHandler(project, socketURL)
    }

    func missionCreate(
        _ request: BurnBarMissionCreateRequest,
        at socketURL: URL
    ) throws -> BurnBarMissionMutationResponse {
        try missionCreateHandler(request, socketURL)
    }

    func recordControllerReviewRun(
        _ run: BurnBarReviewRunSnapshot,
        at socketURL: URL
    ) throws -> BurnBarControllerReviewRunRecordResponse {
        try recordControllerReviewRunHandler(run, socketURL)
    }

    func controllerRuntimeSnapshot(at socketURL: URL) throws -> OpenBurnBarControllerRuntimeSnapshot {
        try controllerRuntimeSnapshotHandler(socketURL)
    }

    func answerControllerQuestion(
        questionID: String,
        answer: String,
        selectedOptionID: String?,
        at socketURL: URL
    ) throws -> OpenBurnBarControllerRuntimeSnapshot? {
        try answerControllerQuestionHandler(questionID, answer, selectedOptionID, socketURL)
    }

    func completeControllerFollowup(
        followupID: String,
        at socketURL: URL
    ) throws -> OpenBurnBarControllerRuntimeSnapshot? {
        try completeControllerFollowupHandler(followupID, socketURL)
    }

    func snoozeControllerFollowup(
        followupID: String,
        until: Date,
        at socketURL: URL
    ) throws -> OpenBurnBarControllerRuntimeSnapshot? {
        try snoozeControllerFollowupHandler(followupID, until, socketURL)
    }

    func scheduleControllerFollowupCalendar(
        followupID: String,
        title: String?,
        start: Date,
        durationMinutes: Int,
        at socketURL: URL
    ) throws -> OpenBurnBarControllerRuntimeSnapshot? {
        try scheduleControllerFollowupCalendarHandler(followupID, title, start, durationMinutes, socketURL)
    }
}
