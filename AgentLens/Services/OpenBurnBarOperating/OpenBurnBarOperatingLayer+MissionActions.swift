import Foundation
import OpenBurnBarCore

extension OpenBurnBarOperatingLayer {
    func approveMission(note: String = "") {
        let current = snapshot
        guard let action = current.availableActions.first(where: { $0.kind == .missionApproval }) else {
            actionFeedback = OpenBurnBarActionFeedback(
                kind: .missionApproval,
                tone: .error,
                message: "Mission approval is unavailable.",
                detail: nil
            )
            return
        }
        guard action.available else {
            actionFeedback = OpenBurnBarActionFeedback(
                kind: .missionApproval,
                tone: .error,
                message: "Mission approval is unavailable.",
                detail: action.reason
            )
            return
        }
        guard let projectName = current.projectName else {
            actionFeedback = OpenBurnBarActionFeedback(
                kind: .missionApproval,
                tone: .error,
                message: "OpenBurnBar could not resolve a project to approve.",
                detail: nil
            )
            return
        }

        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try dataStore.appendOperatingActionRecord(
                OpenBurnBarOperatingActionRecord(
                    projectName: projectName,
                    missionFingerprint: current.mission.missionID,
                    actionKind: .missionApproval,
                    summary: "Mission approved",
                    detail: trimmedNote.isEmpty ? current.mission.recommendationSummary : trimmedNote
                )
            )
        } catch {
            actionFeedback = OpenBurnBarActionFeedback(
                kind: .missionApproval,
                tone: .error,
                message: "Mission approval could not be recorded.",
                detail: error.localizedDescription
            )
            return
        }
        stateRevision += 1
        actionFeedback = OpenBurnBarActionFeedback(
            kind: .missionApproval,
            tone: .success,
            message: "Mission approved for \(projectName).",
            detail: trimmedNote.isEmpty ? "OpenBurnBar will treat this mission as operator-approved until the checkpoint changes." : trimmedNote
        )
    }

    /// Approve a specific mission by ID — used when multiple missions are pending in the Queue tab.
    func approveMission(id: String, projectName: String, note: String = "") {
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try dataStore.appendOperatingActionRecord(
                OpenBurnBarOperatingActionRecord(
                    projectName: projectName,
                    missionFingerprint: id,
                    actionKind: .missionApproval,
                    summary: "Mission approved",
                    detail: trimmedNote.isEmpty ? nil : trimmedNote
                )
            )
        } catch {
            actionFeedback = OpenBurnBarActionFeedback(
                kind: .missionApproval,
                tone: .error,
                message: "Mission approval could not be recorded.",
                detail: error.localizedDescription
            )
            return
        }
        stateRevision += 1
        actionFeedback = OpenBurnBarActionFeedback(
            kind: .missionApproval,
            tone: .success,
            message: "Mission approved for \(projectName).",
            detail: trimmedNote.isEmpty ? "OpenBurnBar will treat this mission as operator-approved until the checkpoint changes." : trimmedNote
        )
    }

    func saveDirectionOverride(
        mode: OpenBurnBarDirectionOverrideModeKind,
        forcedStatus: OpenBurnBarDirectionAssessment?,
        summary: String,
        rationale: String
    ) {
        let current = snapshot
        guard let action = current.availableActions.first(where: { $0.kind == .directionOverride }) else {
            actionFeedback = OpenBurnBarActionFeedback(
                kind: .directionOverride,
                tone: .error,
                message: "Direction override is unavailable.",
                detail: nil
            )
            return
        }
        guard action.available else {
            actionFeedback = OpenBurnBarActionFeedback(
                kind: .directionOverride,
                tone: .error,
                message: "Direction override is unavailable.",
                detail: action.reason
            )
            return
        }
        guard let projectName = current.projectName else {
            actionFeedback = OpenBurnBarActionFeedback(
                kind: .directionOverride,
                tone: .error,
                message: "OpenBurnBar could not resolve a project to steer.",
                detail: nil
            )
            return
        }

        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRationale = rationale.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedSummary.isEmpty == false, trimmedRationale.isEmpty == false else {
            actionFeedback = OpenBurnBarActionFeedback(
                kind: .directionOverride,
                tone: .error,
                message: "Direction override needs both a summary and a rationale.",
                detail: nil
            )
            return
        }
        if mode == .supersedeStatus, forcedStatus == nil {
            actionFeedback = OpenBurnBarActionFeedback(
                kind: .directionOverride,
                tone: .error,
                message: "Choose the status you want OpenBurnBar to force.",
                detail: nil
            )
            return
        }

        do {
            try dataStore.appendOperatingActionRecord(
                OpenBurnBarOperatingActionRecord(
                    projectName: projectName,
                    actionKind: .directionOverride,
                    summary: trimmedSummary,
                    detail: trimmedRationale,
                    overrideMode: mode,
                    forcedDirectionStatus: forcedStatus
                )
            )
        } catch {
            actionFeedback = OpenBurnBarActionFeedback(
                kind: .directionOverride,
                tone: .error,
                message: "Direction override could not be recorded.",
                detail: error.localizedDescription
            )
            return
        }
        stateRevision += 1

        let detail: String
        if mode == .annotate {
            detail = "OpenBurnBar will keep showing the inferred status, but it will carry your note alongside it."
        } else {
            detail = "OpenBurnBar will surface \(forcedStatus?.label ?? "your override") until you update it."
        }
        actionFeedback = OpenBurnBarActionFeedback(
            kind: .directionOverride,
            tone: .success,
            message: "Direction override saved for \(projectName).",
            detail: detail
        )
    }

    /// Creates a daemon mission with the given parameters.
    /// - Parameters:
    ///   - projectSlug: The project slug (identifier)
    ///   - title: Mission title
    ///   - summary: Mission summary/description
    ///   - recommendation: Recommendation kind (proceed, review, pause)
    /// - Returns: The created mission ID if successful
    @discardableResult
    func createMission(
        projectSlug: String,
        title: String,
        summary: String,
        recommendation: BurnBarMissionRecommendation
    ) async throws -> String {
        let trimmedProjectSlug = projectSlug.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmedProjectSlug.isEmpty == false else {
            actionFeedback = OpenBurnBarActionFeedback(
                kind: .missionCreation,
                tone: .error,
                message: "Project identifier is required.",
                detail: nil
            )
            throw MissionAuthoringError.validationFailed("Project identifier is required.")
        }

        guard trimmedTitle.isEmpty == false else {
            actionFeedback = OpenBurnBarActionFeedback(
                kind: .missionCreation,
                tone: .error,
                message: "Mission title is required.",
                detail: nil
            )
            throw MissionAuthoringError.validationFailed("Mission title is required.")
        }

        guard trimmedSummary.isEmpty == false else {
            actionFeedback = OpenBurnBarActionFeedback(
                kind: .missionCreation,
                tone: .error,
                message: "Mission summary is required.",
                detail: nil
            )
            throw MissionAuthoringError.validationFailed("Mission summary is required.")
        }

        do {
            let response = try await daemonManager.createMission(
                projectSlug: trimmedProjectSlug,
                title: trimmedTitle,
                summary: trimmedSummary,
                createdBy: "operator",
                recommendation: recommendation
            )

            stateRevision += 1
            actionFeedback = OpenBurnBarActionFeedback(
                kind: .missionCreation,
                tone: .success,
                message: "Mission created for \(trimmedProjectSlug).",
                detail: "Mission \"\(trimmedTitle)\" is awaiting approval."
            )

            // Record in local history as well
            do {
                try dataStore.appendOperatingActionRecord(
                    OpenBurnBarOperatingActionRecord(
                        projectName: trimmedProjectSlug,
                        missionFingerprint: response.mission.id.rawValue,
                        actionKind: .missionCreation,
                        summary: "Mission created: \(trimmedTitle)",
                        detail: trimmedSummary
                    )
                )
            } catch {
                AppLogger.dataStore.silentFailure("appendOperatingActionRecord", error: error)
            }

            return response.mission.id.rawValue
        } catch {
            actionFeedback = OpenBurnBarActionFeedback(
                kind: .missionCreation,
                tone: .error,
                message: "Mission creation failed.",
                detail: error.localizedDescription
            )
            throw MissionAuthoringError.daemonError(error.localizedDescription)
        }
    }
}

enum MissionAuthoringError: Error, LocalizedError {
    case validationFailed(String)
    case daemonError(String)

    var errorDescription: String? {
        switch self {
        case .validationFailed(let message): return message
        case .daemonError(let message): return message
        }
    }
}
