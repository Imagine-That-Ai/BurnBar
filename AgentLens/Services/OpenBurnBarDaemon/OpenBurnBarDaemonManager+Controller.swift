import Foundation
import OpenBurnBarCore

extension OpenBurnBarDaemonManager {

    func fetchControllerRuntimeSnapshot() async throws -> OpenBurnBarControllerRuntimeSnapshot {
        let socketURL = paths.socketURL
        return try await daemonRPC {
            try OpenBurnBarDaemonSocketClient.controllerRuntimeSnapshot(at: socketURL)
        }
    }

    func answerControllerQuestion(
        questionID: String,
        answer: String,
        selectedOptionID: String? = nil
    ) async throws -> OpenBurnBarControllerRuntimeSnapshot? {
        let socketURL = paths.socketURL
        return try await daemonRPC {
            try OpenBurnBarDaemonSocketClient.answerControllerQuestion(
                questionID: questionID,
                answer: answer,
                selectedOptionID: selectedOptionID,
                at: socketURL
            )
        }
    }

    func completeControllerFollowup(
        followupID: String
    ) async throws -> OpenBurnBarControllerRuntimeSnapshot? {
        let socketURL = paths.socketURL
        return try await daemonRPC {
            try OpenBurnBarDaemonSocketClient.completeControllerFollowup(
                followupID: followupID,
                at: socketURL
            )
        }
    }

    func snoozeControllerFollowup(
        followupID: String,
        until: Date
    ) async throws -> OpenBurnBarControllerRuntimeSnapshot? {
        let socketURL = paths.socketURL
        return try await daemonRPC {
            try OpenBurnBarDaemonSocketClient.snoozeControllerFollowup(
                followupID: followupID,
                until: until,
                at: socketURL
            )
        }
    }

    func scheduleControllerFollowupCalendar(
        followupID: String,
        title: String?,
        start: Date,
        durationMinutes: Int
    ) async throws -> OpenBurnBarControllerRuntimeSnapshot? {
        let socketURL = paths.socketURL
        return try await daemonRPC {
            try OpenBurnBarDaemonSocketClient.scheduleControllerFollowupCalendar(
                followupID: followupID,
                title: title,
                start: start,
                durationMinutes: durationMinutes,
                at: socketURL
            )
        }
    }

    func refreshControllerProjects() async throws -> [BurnBarReviewProjectSnapshot] {
        guard case .healthy = status else {
            controllerProjects = []
            return []
        }

        exportControllerActivitySnapshot()
        let socketURL = paths.socketURL
        let projects = try await daemonRPC {
            try OpenBurnBarDaemonSocketClient.controllerProjects(at: socketURL)
        }
        controllerProjects = projects
        return projects
    }

    func saveControllerProject(
        _ project: BurnBarReviewProjectSnapshot
    ) async throws -> BurnBarReviewProjectSnapshot? {
        guard case .healthy = status else {
            throw OpenBurnBarDaemonManagerError.rpcError("OpenBurnBar daemon must be healthy before saving controller projects.")
        }

        let socketURL = paths.socketURL
        let saved = try await daemonRPC {
            try OpenBurnBarDaemonSocketClient.upsertControllerProject(project, at: socketURL)
        }
        _ = try await refreshControllerProjects()
        return saved
    }

    func createMission(
        projectSlug: String,
        title: String,
        summary: String,
        createdBy: String,
        recommendation: BurnBarMissionRecommendation
    ) async throws -> BurnBarMissionMutationResponse {
        guard case .healthy = status else {
            throw OpenBurnBarDaemonManagerError.rpcError("OpenBurnBar daemon must be healthy before creating missions.")
        }

        let socketURL = paths.socketURL
        let request = BurnBarMissionCreateRequest(
            projectSlug: projectSlug,
            title: title,
            summary: summary,
            createdBy: createdBy,
            recommendation: recommendation
        )
        return try await daemonRPC {
            try OpenBurnBarDaemonSocketClient.missionCreate(request, at: socketURL)
        }
    }

    func launchControllerReview(
        projectSlug: String,
        cadence: BurnBarControllerReviewCadence,
        origin: BurnBarControllerReviewRunOrigin = .projects,
        triggeredBy: String = "operator"
    ) async throws -> BurnBarControllerReviewRunRecordResponse {
        guard case .healthy = status else {
            throw OpenBurnBarDaemonManagerError.rpcError("OpenBurnBar daemon must be healthy before launching controller reviews.")
        }

        let summary: String
        switch origin {
        case .dashboard:
            summary = "Triggered from the OpenBurnBar dashboard."
        case .projects:
            summary = "Triggered from the OpenBurnBar projects registry."
        case .telegram:
            summary = "Triggered from the OpenBurnBar Telegram bridge."
        case .scheduled:
            summary = "Triggered from OpenBurnBar's scheduled review loop."
        case .ingestion:
            summary = "Triggered while ingesting OpenBurnBar activity."
        case .manual:
            summary = "Triggered manually from OpenBurnBar."
        }

        let socketURL = paths.socketURL
        let run = BurnBarReviewRunSnapshot(
            id: "review-\(UUID().uuidString)",
            projectSlug: projectSlug,
            cadence: cadence,
            recordedAt: Date(),
            summary: summary,
            questionCount: 0,
            followupCount: 0,
            missionCount: 0,
            origin: origin,
            triggeredBy: triggeredBy
        )
        let response = try await daemonRPC {
            try OpenBurnBarDaemonSocketClient.recordControllerReviewRun(run, at: socketURL)
        }
        _ = try await refreshControllerProjects()
        return response
    }

    func syncControllerNotificationConfiguration(
        from settingsManager: SettingsManager
    ) async throws {
        let trimmedToken = settingsManager.controllerTelegramBotToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedChatID = settingsManager.controllerTelegramChatID.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedToken.isEmpty {
            try Self.controllerRuntimeSecrets.delete(account: OpenBurnBarIdentity.controllerTelegramBotTokenAccount)
        } else {
            try Self.controllerRuntimeSecrets.set(
                trimmedToken,
                for: OpenBurnBarIdentity.controllerTelegramBotTokenAccount
            )
        }

        guard case .healthy = status else { return }

        let config = BurnBarNotificationConfig(
            defaultSnoozeMinutes: settingsManager.controllerDefaultSnoozeMinutes,
            nudgeHoursLocal: [9, 13, 17],
            local: BurnBarLocalNotificationConfig(
                isEnabled: settingsManager.controllerLocalNotificationsEnabled,
                quietHoursStart: 22,
                quietHoursEnd: 7
            ),
            telegram: BurnBarTelegramNotificationConfig(
                isEnabled: settingsManager.controllerTelegramEnabled,
                botTokenConfigured: trimmedToken.isEmpty == false,
                botToken: trimmedToken.isEmpty ? nil : trimmedToken,
                botTokenHint: trimmedToken.isEmpty ? nil : Self.telegramTokenHint(for: trimmedToken),
                chatID: trimmedChatID.isEmpty ? nil : trimmedChatID
            ),
            calendar: BurnBarCalendarNotificationConfig(
                isEnabled: settingsManager.controllerCalendarIntegrationEnabled,
                defaultDurationMinutes: settingsManager.controllerCalendarDefaultMinutes,
                defaultCalendarName: "OpenBurnBar Ops"
            )
        )

        let socketURL = paths.socketURL
        _ = try await daemonRPC {
            try OpenBurnBarDaemonSocketClient.updateNotificationConfig(config, at: socketURL)
        }
    }
}
