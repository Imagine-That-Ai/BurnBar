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

extension BurnBarMissionControlService {
    func deliverDueFollowups(_ followups: [BurnBarFollowupSnapshot]) async throws {
        guard followups.isEmpty == false else { return }
        let config = try await store.notificationConfig()

        if config.local.isEnabled {
            do {
                for followup in followups {
                    try await transport.deliverLocalNotification(
                        "OpenBurnBar followup due",
                        "\(followup.title)\n\(followup.summary)"
                    )
                }
                try await store.recordTransportError(channel: .local, error: nil)
            } catch {
                try await store.recordTransportError(channel: .local, error: error.localizedDescription)
                throw error
            }
        }

        guard config.telegram.isEnabled,
              let botToken = config.telegram.botToken?.nonEmpty,
              let chatID = config.telegram.chatID?.nonEmpty else {
            return
        }

        do {
            for followup in followups {
                let project = followup.projectSlug.capitalized
                let message = "[\(project)] Followup due\n\(followup.title)\n\(followup.summary)"
                try await transport.sendTelegramMessage(botToken, chatID, message)
            }
            try await store.recordTransportError(channel: .telegram, error: nil)
        } catch {
            try await store.recordTransportError(channel: .telegram, error: error.localizedDescription)
            throw error
        }
    }

    func pollTelegramCommands() async throws {
        let config = try await store.notificationConfig()
        guard config.telegram.isEnabled,
              let botToken = config.telegram.botToken?.nonEmpty,
              let configuredChatID = config.telegram.chatID?.nonEmpty else {
            return
        }

        do {
            let updates = try await transport.fetchTelegramUpdates(botToken, try await store.telegramUpdateOffset())
            guard updates.isEmpty == false else { return }

            for update in updates.sorted(by: { $0.updateID < $1.updateID }) {
                try await store.setTelegramUpdateOffset(update.updateID + 1)
                guard update.chatID == configuredChatID,
                      let request = parseTelegramCommand(text: update.text, actor: "telegram") else {
                    continue
                }
                let response = try await notificationCommand(request)
                try await transport.sendTelegramMessage(botToken, configuredChatID, response.message)
            }
            try await store.recordTransportError(channel: .telegram, error: nil)
        } catch {
            try await store.recordTransportError(channel: .telegram, error: error.localizedDescription)
            throw error
        }
    }

    func parseTelegramCommand(text: String, actor: String) -> BurnBarNotificationCommandRequest? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }

        let parts = trimmed
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard let rawCommand = parts.first else { return nil }

        let normalized = rawCommand
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()

        let command: BurnBarTelegramCommand?
        switch normalized {
        case "daily": command = .runDaily
        case "weekly": command = .runWeekly
        default: command = BurnBarTelegramCommand(rawValue: normalized)
        }

        guard let command else { return nil }
        return BurnBarNotificationCommandRequest(
            command: command,
            arguments: Array(parts.dropFirst()),
            actor: actor
        )
    }
}
