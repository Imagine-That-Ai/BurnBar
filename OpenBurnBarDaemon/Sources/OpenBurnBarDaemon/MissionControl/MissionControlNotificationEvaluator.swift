import OpenBurnBarCore
import Foundation

/// Pure helpers for followup notification evaluation (snooze expiry and nudges).
enum MissionControlNotificationEvaluator {
    static func reopenedFollowupAfterSnoozeExpired(
        followup: BurnBarFollowupSnapshot,
        snoozeUntil: Date
    ) -> BurnBarFollowupSnapshot {
        BurnBarFollowupSnapshot(
            id: followup.id,
            projectSlug: followup.projectSlug,
            questionID: followup.questionID,
            title: followup.title,
            summary: followup.summary,
            stageLabel: followup.stageLabel,
            status: .open,
            kind: followup.kind,
            createdAt: followup.createdAt,
            nextNudgeAt: snoozeUntil,
            snoozeUntil: nil,
            calendarEntry: followup.calendarEntry,
            deepLink: followup.deepLink,
            metadata: followup.metadata
        )
    }

    static func nudgedFollowupRescheduled(
        followup: BurnBarFollowupSnapshot,
        config: BurnBarNotificationConfig,
        now: Date
    ) -> BurnBarFollowupSnapshot {
        BurnBarFollowupSnapshot(
            id: followup.id,
            projectSlug: followup.projectSlug,
            questionID: followup.questionID,
            title: followup.title,
            summary: followup.summary,
            stageLabel: followup.stageLabel,
            status: .open,
            kind: followup.kind,
            createdAt: followup.createdAt,
            nextNudgeAt: now.addingTimeInterval(Double(config.defaultSnoozeMinutes * 60)),
            snoozeUntil: followup.snoozeUntil,
            calendarEntry: followup.calendarEntry,
            deepLink: followup.deepLink,
            metadata: followup.metadata
        )
    }
}
