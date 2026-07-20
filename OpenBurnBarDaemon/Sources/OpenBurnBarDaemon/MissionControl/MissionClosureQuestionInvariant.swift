import OpenBurnBarEngine
import Foundation

enum MissionClosureQuestionInvariant {
    static func enforce(
        _ incoming: BurnBarPendingQuestionSnapshot,
        in projection: BurnBarMissionControlProjectionFile?
    ) -> BurnBarPendingQuestionSnapshot {
        guard let missionID = missionID(for: incoming) else {
            return incoming
        }
        guard let existing = activeQuestion(for: missionID, in: projection),
              existing.id != incoming.id else {
            return incoming
        }

        return mergedQuestion(existing: existing, incoming: incoming)
    }

    static func normalize(in projection: inout BurnBarMissionControlProjectionFile) -> Bool {
        var groupedClosureQuestions: [String: [BurnBarPendingQuestionSnapshot]] = [:]
        for question in projection.questions.values {
            guard let missionID = missionID(for: question) else { continue }
            groupedClosureQuestions[missionID, default: []].append(question)
        }

        var didChange = false
        for (_, groupedQuestions) in groupedClosureQuestions {
            let questions = groupedQuestions.sorted(by: questionSort)
            guard questions.count > 1, var canonical = questions.first else {
                continue
            }

            var duplicateQuestionIDs: Set<BurnBarQuestionID> = []
            for duplicate in questions.dropFirst() {
                duplicateQuestionIDs.insert(duplicate.id)
                canonical = mergedQuestion(existing: canonical, incoming: duplicate)
            }

            projection.questions[canonical.id.rawValue] = canonical
            for duplicateID in duplicateQuestionIDs {
                projection.questions.removeValue(forKey: duplicateID.rawValue)
            }

            didChange = true
            didChange = normalizeFollowups(
                in: &projection,
                canonicalQuestion: canonical,
                duplicateQuestionIDs: duplicateQuestionIDs
            ) || didChange
        }
        return didChange
    }

    private static func questionSort(
        lhs: BurnBarPendingQuestionSnapshot,
        rhs: BurnBarPendingQuestionSnapshot
    ) -> Bool {
        if lhs.askedAt != rhs.askedAt {
            return lhs.askedAt < rhs.askedAt
        }
        return lhs.id.rawValue < rhs.id.rawValue
    }

    private static func mergedQuestion(
        existing: BurnBarPendingQuestionSnapshot,
        incoming: BurnBarPendingQuestionSnapshot
    ) -> BurnBarPendingQuestionSnapshot {
        let mergedEvidenceRefs = incoming.evidenceRefs.isEmpty ? existing.evidenceRefs : incoming.evidenceRefs
        let mergedSuggestedOptions = incoming.suggestedOptions.isEmpty ? existing.suggestedOptions : incoming.suggestedOptions
        let mergedTracker = existing.tracker ?? incoming.tracker
        let mergedMetadata = existing.metadata
            .merging(incoming.metadata) { _, new in new }
            .merging(
                [
                    "invariant_reason_code": .string("CLOSURE_SINGLE_QUESTION_ENFORCED"),
                    "closure_merged_from_question_id": .string(incoming.id.rawValue)
                ]
            ) { _, new in new }

        return BurnBarPendingQuestionSnapshot(
            id: existing.id,
            projectSlug: existing.projectSlug,
            sessionID: incoming.sessionID ?? existing.sessionID,
            title: incoming.title,
            prompt: incoming.prompt,
            stageLabel: incoming.stageLabel ?? existing.stageLabel,
            status: .pending,
            priority: incoming.priority,
            askedAt: existing.askedAt,
            dueAt: incoming.dueAt ?? existing.dueAt,
            latestAnswer: nil,
            answerPlaceholder: incoming.answerPlaceholder ?? existing.answerPlaceholder,
            contextSummary: incoming.contextSummary ?? existing.contextSummary,
            evidenceRefs: mergedEvidenceRefs,
            suggestedOptions: mergedSuggestedOptions,
            deepLink: incoming.deepLink ?? existing.deepLink,
            tracker: mergedTracker,
            metadata: mergedMetadata
        )
    }

    private static func normalizeFollowups(
        in projection: inout BurnBarMissionControlProjectionFile,
        canonicalQuestion: BurnBarPendingQuestionSnapshot,
        duplicateQuestionIDs: Set<BurnBarQuestionID>
    ) -> Bool {
        let canonicalQuestionID = canonicalQuestion.id
        let canonicalFollowups = projection.followups.values
            .filter { $0.questionID == canonicalQuestionID }
            .sorted(by: followupSort)
        let duplicateFollowups = projection.followups.values
            .filter { followup in
                guard let questionID = followup.questionID else { return false }
                return duplicateQuestionIDs.contains(questionID)
            }
            .sorted(by: followupSort)

        guard canonicalFollowups.count > 1 || !duplicateFollowups.isEmpty else {
            return false
        }

        var didChange = false
        if let keeper = canonicalFollowups.first {
            for followup in Array(canonicalFollowups.dropFirst()) + duplicateFollowups {
                guard followup.id != keeper.id else { continue }
                projection.followups.removeValue(forKey: followup.id.rawValue)
                didChange = true
            }
            return didChange
        }

        guard let rebound = duplicateFollowups.first else {
            return didChange
        }
        projection.followups[rebound.id.rawValue] = followup(
            rebound,
            withQuestionID: canonicalQuestionID,
            metadata: [
                "invariant_reason_code": .string("CLOSURE_FOLLOWUP_REBOUND"),
                "closure_rebound_to_question_id": .string(canonicalQuestionID.rawValue)
            ]
        )
        didChange = true

        for followup in duplicateFollowups.dropFirst() {
            projection.followups.removeValue(forKey: followup.id.rawValue)
        }
        return didChange
    }

    private static func followupSort(lhs: BurnBarFollowupSnapshot, rhs: BurnBarFollowupSnapshot) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.id.rawValue < rhs.id.rawValue
    }

    private static func activeQuestion(
        for missionID: String,
        in projection: BurnBarMissionControlProjectionFile?
    ) -> BurnBarPendingQuestionSnapshot? {
        projection?.questions.values
            .filter { question in
                self.missionID(for: question) == missionID
            }
            .min { lhs, rhs in
                if lhs.askedAt != rhs.askedAt {
                    return lhs.askedAt < rhs.askedAt
                }
                return lhs.id.rawValue < rhs.id.rawValue
            }
    }

    private static func missionID(for question: BurnBarPendingQuestionSnapshot) -> String? {
        guard question.status == .pending else { return nil }
        guard let missionID = metadataString(question.metadata["mission_id"])?.nonEmpty else {
            return nil
        }

        let kind = metadataString(question.metadata["question_kind"])?.lowercased()
            ?? metadataString(question.metadata["question_type"])?.lowercased()
            ?? ""
        let closureState = metadataString(question.metadata["closure_state"])?.lowercased() ?? ""
        let closureApproval = metadataBool(question.metadata["closure_approval"]) ?? false
        let stageLabel = question.stageLabel?.lowercased() ?? ""

        let closureKindMatch = kind.contains("closure") && (kind.contains("approval") || kind.contains("question"))
        let closureStateMatch = ["awaiting_approval", "needs_approval", "blocked_approval"].contains(closureState)
        let closureStageMatch = stageLabel.contains("closure") && stageLabel.contains("mission")

        guard closureApproval || closureKindMatch || closureStateMatch || closureStageMatch else {
            return nil
        }
        return missionID
    }

    private static func metadataString(_ value: BurnBarJSONValue?) -> String? {
        guard case .string(let rawValue)? = value else { return nil }
        return rawValue
    }

    private static func metadataBool(_ value: BurnBarJSONValue?) -> Bool? {
        guard case .bool(let rawValue)? = value else { return nil }
        return rawValue
    }

    private static func followup(
        _ followup: BurnBarFollowupSnapshot,
        withQuestionID questionID: BurnBarQuestionID,
        metadata: BurnBarMetadata
    ) -> BurnBarFollowupSnapshot {
        BurnBarFollowupSnapshot(
            id: followup.id,
            projectSlug: followup.projectSlug,
            questionID: questionID,
            title: followup.title,
            summary: followup.summary,
            stageLabel: followup.stageLabel,
            status: followup.status,
            kind: followup.kind,
            createdAt: followup.createdAt,
            nextNudgeAt: followup.nextNudgeAt,
            snoozeUntil: followup.snoozeUntil,
            calendarEntry: followup.calendarEntry,
            deepLink: followup.deepLink,
            metadata: followup.metadata.merging(metadata) { _, new in new }
        )
    }
}
