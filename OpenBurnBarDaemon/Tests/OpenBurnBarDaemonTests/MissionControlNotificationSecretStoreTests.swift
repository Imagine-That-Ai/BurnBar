import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import Foundation
import XCTest

final class MissionControlNotificationSecretStoreTests: XCTestCase {
    func testNotificationConfigUpdateKeepsTelegramTokenOutOfJournalAndProjection() async throws {
        let dummyToken = "dummy-journal-token"
        let recorder = NotificationSecretTransportRecorder()
        let harness = try makeHarness(
            name: "notification-secret-persistence",
            transport: BurnBarMissionControlTransport(
                deliverLocalNotification: { _, _ in },
                sendTelegramMessage: { token, chatID, text in
                    await recorder.recordTelegram(token: token, chatID: chatID, text: text)
                },
                fetchTelegramUpdates: { _, _ in [] },
                applyCalendarEntry: { _, entry, _ in entry }
            )
        )

        let updated = try await harness.service.notificationConfigUpdate(
            BurnBarNotificationConfigUpdateRequest(
                config: BurnBarNotificationConfig(
                    defaultSnoozeMinutes: 30,
                    nudgeHoursLocal: [9, 13, 17],
                    local: BurnBarLocalNotificationConfig(isEnabled: false),
                    telegram: BurnBarTelegramNotificationConfig(
                        isEnabled: true,
                        botTokenConfigured: true,
                        botToken: dummyToken,
                        botTokenHint: "configured",
                        chatID: "chat-1"
                    ),
                    calendar: BurnBarCalendarNotificationConfig(isEnabled: false, defaultDurationMinutes: 30)
                )
            )
        )
        XCTAssertNil(updated.config.telegram.botToken)
        XCTAssertTrue(updated.config.telegram.botTokenConfigured)

        let fetched = try await harness.service.notificationConfigGet(BurnBarNotificationConfigGetRequest())
        XCTAssertNil(fetched.config.telegram.botToken)
        XCTAssertTrue(fetched.config.telegram.botTokenConfigured)

        _ = try await harness.service.controllerProjectUpsert(
            BurnBarControllerProjectUpsertRequest(project: project(slug: "apollo"))
        )
        _ = try await harness.service.followupCreate(
            BurnBarFollowupCreateRequest(
                followup: BurnBarFollowupSnapshot(
                    id: BurnBarFollowupID(rawValue: "followup-secret-persistence"),
                    projectSlug: "apollo",
                    title: "Review notification routing",
                    summary: "Telegram should still deliver with a redacted persisted config.",
                    status: .open,
                    kind: .controllerNudge,
                    createdAt: Date().addingTimeInterval(-600),
                    nextNudgeAt: Date().addingTimeInterval(-60)
                )
            )
        )
        try await harness.service.runTransportCycle(now: Date())

        let telegram = await recorder.telegramMessages
        XCTAssertTrue(telegram.contains(where: { $0.token == dummyToken && $0.chatID == "chat-1" && $0.text.contains("Followup due") }))

        try assertFile(at: harness.rootURL.appendingPathComponent("controller-events.jsonl"), doesNotContain: dummyToken)
        try assertFile(at: harness.rootURL.appendingPathComponent("controller-projection.json"), doesNotContain: dummyToken)
    }

    func testLegacyNotificationConfigEventMigratesTelegramTokenOutOfJournal() async throws {
        let dummyToken = "dummy-legacy-token"
        let secretStore = BurnBarInMemoryNotificationSecretStore()
        let legacyConfig = BurnBarNotificationConfig(
            defaultSnoozeMinutes: 30,
            nudgeHoursLocal: [9, 13, 17],
            local: BurnBarLocalNotificationConfig(isEnabled: false),
            telegram: BurnBarTelegramNotificationConfig(
                isEnabled: true,
                botTokenConfigured: true,
                botToken: dummyToken,
                botTokenHint: "configured",
                chatID: "chat-1"
            ),
            calendar: BurnBarCalendarNotificationConfig(isEnabled: false, defaultDurationMinutes: 30)
        )
        let legacyEvent = BurnBarControllerEvent(
            id: BurnBarControllerEventID(rawValue: "controller-event-legacy-secret"),
            family: .notification,
            eventType: "notification_config_updated",
            projectSlug: "openburnbar",
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sequence: 1,
            summary: "Notification configuration updated",
            metadata: ["payload": try BurnBarJSONValue.fromEncodable(legacyConfig)]
        )
        let harness = try makeSeededHarness(
            name: "legacy-notification-secret",
            events: [legacyEvent],
            notificationSecretStore: secretStore
        )

        let fetched = try await harness.service.notificationConfigGet(BurnBarNotificationConfigGetRequest())
        XCTAssertNil(fetched.config.telegram.botToken)
        XCTAssertTrue(fetched.config.telegram.botTokenConfigured)
        XCTAssertEqual(try secretStore.telegramBotToken(), dummyToken)

        let projection = try decodeProjection(from: harness.rootURL)
        XCTAssertEqual(
            projection.notificationSecretMigrationVersion,
            BurnBarMissionControlStore.currentNotificationSecretMigrationVersion
        )
        try assertFile(at: harness.rootURL.appendingPathComponent("controller-events.jsonl"), doesNotContain: dummyToken)
        try assertFile(at: harness.rootURL.appendingPathComponent("controller-projection.json"), doesNotContain: dummyToken)
    }

    func testCompletedLegacyMigrationDoesNotRescanJournalOnProjectionReload() async throws {
        let dummyToken = "dummy-legacy-token"
        let secondToken = "dummy-second-token"
        let secretStore = BurnBarInMemoryNotificationSecretStore()
        let legacyConfig = notificationConfig(botToken: dummyToken, botTokenConfigured: true)
        let harness = try makeSeededHarness(
            name: "legacy-notification-marker",
            events: [try notificationConfigEvent(id: "controller-event-marker-secret", sequence: 1, config: legacyConfig)],
            notificationSecretStore: secretStore
        )

        _ = try await harness.service.notificationConfigGet(BurnBarNotificationConfigGetRequest())
        XCTAssertEqual(try secretStore.telegramBotToken(), dummyToken)

        let poisonedJournalConfig = notificationConfig(botToken: secondToken, botTokenConfigured: true)
        try writeControllerEvents(
            [try notificationConfigEvent(id: "controller-event-marker-second-secret", sequence: 1, config: poisonedJournalConfig)],
            to: harness.rootURL.appendingPathComponent("controller-events.jsonl")
        )

        let reloaded = try makeHarness(
            rootURL: harness.rootURL,
            notificationSecretStore: secretStore
        )
        _ = try await reloaded.service.notificationConfigGet(BurnBarNotificationConfigGetRequest())
        XCTAssertEqual(try secretStore.telegramBotToken(), dummyToken)
    }

    func testConfiguredTelegramWithoutBackingSecretReportsUnauthorized() async throws {
        let secretStore = BurnBarInMemoryNotificationSecretStore()
        let config = notificationConfig(botToken: nil, botTokenConfigured: true)
        let harness = try makeSeededHarness(
            name: "missing-notification-secret",
            events: [try notificationConfigEvent(id: "controller-event-missing-secret", sequence: 1, config: config)],
            notificationSecretStore: secretStore
        )

        let fetched = try await harness.service.notificationConfigGet(BurnBarNotificationConfigGetRequest())
        XCTAssertNil(fetched.config.telegram.botToken)
        XCTAssertFalse(fetched.config.telegram.botTokenConfigured)
        XCTAssertNil(fetched.config.telegram.botTokenHint)

        let health = try await harness.service.notificationHealth(BurnBarNotificationHealthRequest())
        let telegram = try XCTUnwrap(health.health.channels.first(where: { $0.channel == .telegram }))
        XCTAssertEqual(telegram.status, .unauthorized)
        XCTAssertEqual(telegram.detail?.contains("bot token"), true)
    }

    func testNotificationConfigClearRemovesRuntimeTelegramToken() async throws {
        let dummyToken = "dummy-clear-token"
        let secretStore = BurnBarInMemoryNotificationSecretStore()
        let recorder = NotificationSecretTransportRecorder()
        let harness = try makeHarness(
            name: "notification-secret-clear",
            transport: BurnBarMissionControlTransport(
                deliverLocalNotification: { _, _ in },
                sendTelegramMessage: { token, chatID, text in
                    await recorder.recordTelegram(token: token, chatID: chatID, text: text)
                },
                fetchTelegramUpdates: { _, _ in [] },
                applyCalendarEntry: { _, entry, _ in entry }
            ),
            notificationSecretStore: secretStore
        )

        _ = try await harness.service.notificationConfigUpdate(
            BurnBarNotificationConfigUpdateRequest(
                config: BurnBarNotificationConfig(
                    defaultSnoozeMinutes: 30,
                    nudgeHoursLocal: [9, 13, 17],
                    local: BurnBarLocalNotificationConfig(isEnabled: false),
                    telegram: BurnBarTelegramNotificationConfig(
                        isEnabled: true,
                        botTokenConfigured: true,
                        botToken: dummyToken,
                        botTokenHint: "configured",
                        chatID: "chat-1"
                    ),
                    calendar: BurnBarCalendarNotificationConfig(isEnabled: false, defaultDurationMinutes: 30)
                )
            )
        )
        XCTAssertEqual(try secretStore.telegramBotToken(), dummyToken)

        let cleared = try await harness.service.notificationConfigUpdate(
            BurnBarNotificationConfigUpdateRequest(
                config: BurnBarNotificationConfig(
                    defaultSnoozeMinutes: 30,
                    nudgeHoursLocal: [9, 13, 17],
                    local: BurnBarLocalNotificationConfig(isEnabled: false),
                    telegram: BurnBarTelegramNotificationConfig(
                        isEnabled: true,
                        botTokenConfigured: false,
                        botToken: nil,
                        botTokenHint: nil,
                        chatID: "chat-1"
                    ),
                    calendar: BurnBarCalendarNotificationConfig(isEnabled: false, defaultDurationMinutes: 30)
                )
            )
        )
        XCTAssertNil(cleared.config.telegram.botToken)
        XCTAssertFalse(cleared.config.telegram.botTokenConfigured)
        XCTAssertNil(try secretStore.telegramBotToken())

        _ = try await harness.service.controllerProjectUpsert(
            BurnBarControllerProjectUpsertRequest(project: project(slug: "apollo"))
        )
        _ = try await harness.service.followupCreate(
            BurnBarFollowupCreateRequest(
                followup: BurnBarFollowupSnapshot(
                    id: BurnBarFollowupID(rawValue: "followup-secret-clear"),
                    projectSlug: "apollo",
                    title: "Review notification clear",
                    summary: "Telegram should not deliver after the token is cleared.",
                    status: .open,
                    kind: .controllerNudge,
                    createdAt: Date().addingTimeInterval(-600),
                    nextNudgeAt: Date().addingTimeInterval(-60)
                )
            )
        )
        try await harness.service.runTransportCycle(now: Date())

        let telegram = await recorder.telegramMessages
        XCTAssertFalse(telegram.contains(where: { $0.token == dummyToken }))
        try assertFile(at: harness.rootURL.appendingPathComponent("controller-events.jsonl"), doesNotContain: dummyToken)
        try assertFile(at: harness.rootURL.appendingPathComponent("controller-projection.json"), doesNotContain: dummyToken)
    }

    private func makeHarness(
        name: String,
        transport: BurnBarMissionControlTransport = .live(),
        notificationSecretStore: any BurnBarNotificationSecretStoring = BurnBarInMemoryNotificationSecretStore()
    ) throws -> (service: BurnBarMissionControlService, rootURL: URL) {
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
            executionReadinessGate: { _, _ in nil },
            performanceGuardrails: nil
        )
        return (service, rootURL)
    }

    private func makeSeededHarness(
        name: String,
        events: [BurnBarControllerEvent],
        notificationSecretStore: any BurnBarNotificationSecretStoring
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
            transport: .live(),
            activitySnapshotURL: nil,
            reviewRunLauncher: nil,
            runSnapshotLookup: nil,
            usageLedgerURL: rootURL.appendingPathComponent("usage-events.jsonl"),
            executionReadinessGate: nil,
            performanceGuardrails: nil
        )
        return (service, rootURL)
    }

    private func makeHarness(
        rootURL: URL,
        notificationSecretStore: any BurnBarNotificationSecretStoring
    ) throws -> (service: BurnBarMissionControlService, rootURL: URL) {
        let store = BurnBarMissionControlStore(
            eventsFileURL: rootURL.appendingPathComponent("controller-events.jsonl"),
            projectionFileURL: rootURL.appendingPathComponent("controller-projection.json"),
            logger: BurnBarDaemonLogger(category: "mission-control-tests"),
            notificationSecretStore: notificationSecretStore
        )
        let service = BurnBarMissionControlService(
            store: store,
            logger: BurnBarDaemonLogger(category: "mission-control-tests"),
            transport: .live(),
            activitySnapshotURL: nil,
            reviewRunLauncher: nil,
            runSnapshotLookup: nil,
            usageLedgerURL: rootURL.appendingPathComponent("usage-events.jsonl"),
            executionReadinessGate: nil,
            performanceGuardrails: nil
        )
        return (service, rootURL)
    }

    private func notificationConfig(
        botToken: String?,
        botTokenConfigured: Bool
    ) -> BurnBarNotificationConfig {
        BurnBarNotificationConfig(
            defaultSnoozeMinutes: 30,
            nudgeHoursLocal: [9, 13, 17],
            local: BurnBarLocalNotificationConfig(isEnabled: false),
            telegram: BurnBarTelegramNotificationConfig(
                isEnabled: true,
                botTokenConfigured: botTokenConfigured,
                botToken: botToken,
                botTokenHint: botTokenConfigured ? "configured" : nil,
                chatID: "chat-1"
            ),
            calendar: BurnBarCalendarNotificationConfig(isEnabled: false, defaultDurationMinutes: 30)
        )
    }

    private func notificationConfigEvent(
        id: String,
        sequence: Int,
        config: BurnBarNotificationConfig
    ) throws -> BurnBarControllerEvent {
        BurnBarControllerEvent(
            id: BurnBarControllerEventID(rawValue: id),
            family: .notification,
            eventType: "notification_config_updated",
            projectSlug: "openburnbar",
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(sequence)),
            sequence: sequence,
            summary: "Notification configuration updated",
            metadata: ["payload": try BurnBarJSONValue.fromEncodable(config)]
        )
    }

    private func decodeProjection(from rootURL: URL) throws -> BurnBarMissionControlProjectionFile {
        let data = try Data(contentsOf: rootURL.appendingPathComponent("controller-projection.json"))
        return try JSONDecoder().decode(BurnBarMissionControlProjectionFile.self, from: data)
    }

    private func writeControllerEvents(
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

    private func assertFile(
        at url: URL,
        doesNotContain forbiddenText: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(
            content.contains(forbiddenText),
            "\(url.lastPathComponent) should not persist sensitive notification credential material",
            file: file,
            line: line
        )
    }

    private func project(slug: String) -> BurnBarReviewProjectSnapshot {
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
}

private actor NotificationSecretTransportRecorder {
    private(set) var telegramMessages: [(token: String, chatID: String, text: String)] = []

    func recordTelegram(token: String, chatID: String, text: String) {
        telegramMessages.append((token, chatID, text))
    }
}
