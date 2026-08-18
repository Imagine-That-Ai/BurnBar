import OpenBurnBarEngine
import Foundation

struct BurnBarMissionControlProjectionFile: Codable, Sendable {
    var lastSequence: Int
    var projects: [String: BurnBarReviewProjectSnapshot]
    var reviewRuns: [String: BurnBarReviewRunSnapshot]
    var questions: [String: BurnBarPendingQuestionSnapshot]
    var followups: [String: BurnBarFollowupSnapshot]
    var missions: [String: BurnBarMissionSnapshot]
    var notificationConfig: BurnBarNotificationConfig
    var simulatorRuns: [String: BurnBarSimulatorRunSnapshot]
    var projectionStatus: [String: BurnBarProjectionStatusSnapshot]
    var telegramUpdateOffset: Int?
    var transportErrors: [String: String]
    var notificationSecretMigrationVersion: Int?
    /// Permanent project-identity tombstones. `nil` identifies a legacy
    /// projection that must be rebuilt once from the journal.
    var projectDeletionTombstones: [String: String]?
    var rebuiltAt: Date

    static func empty(now: Date = Date()) -> BurnBarMissionControlProjectionFile {
        let status = BurnBarMissionControlProjectionFile.defaultProjectionStatus(
            eventSequence: 0,
            recordedAt: now
        )
        return BurnBarMissionControlProjectionFile(
            lastSequence: 0,
            projects: [:],
            reviewRuns: [:],
            questions: [:],
            followups: [:],
            missions: [:],
            notificationConfig: Self.defaultNotificationConfig(),
            simulatorRuns: [:],
            projectionStatus: status,
            telegramUpdateOffset: nil,
            transportErrors: [:],
            notificationSecretMigrationVersion: BurnBarMissionControlStore.currentNotificationSecretMigrationVersion,
            projectDeletionTombstones: [:],
            rebuiltAt: now
        )
    }

    static func defaultNotificationConfig() -> BurnBarNotificationConfig {
        BurnBarNotificationConfig(
            defaultSnoozeMinutes: 90,
            nudgeHoursLocal: [9, 13, 17],
            local: BurnBarLocalNotificationConfig(
                isEnabled: true,
                quietHoursStart: 22,
                quietHoursEnd: 7
            ),
            telegram: BurnBarTelegramNotificationConfig(
                isEnabled: false,
                botTokenConfigured: false,
                botToken: nil,
                botTokenHint: nil,
                chatID: nil
            ),
            calendar: BurnBarCalendarNotificationConfig(
                isEnabled: false,
                defaultDurationMinutes: 30,
                defaultCalendarName: nil
            )
        )
    }

    static func defaultProjectionStatus(
        eventSequence: Int,
        recordedAt: Date
    ) -> [String: BurnBarProjectionStatusSnapshot] {
        let names = [
            "controller_summary",
            "conversation_home",
            "followups",
            "pending_questions",
            "missions",
            "governance_history"
        ]

        return Dictionary(uniqueKeysWithValues: names.map { name in
            let checkpoint = BurnBarReplayCheckpoint(
                id: BurnBarProjectionCheckpointID(rawValue: "checkpoint-\(name)-\(eventSequence)"),
                projectionName: name,
                eventSequence: eventSequence,
                recordedAt: recordedAt
            )
            let snapshot = BurnBarProjectionStatusSnapshot(
                projectionName: name,
                status: .upToDate,
                freshness: eventSequence == 0 ? .missing : .fresh,
                lastMaterializedAt: recordedAt,
                lastEventSequence: eventSequence,
                checkpoint: checkpoint
            )
            return (name, snapshot)
        })
    }
}
