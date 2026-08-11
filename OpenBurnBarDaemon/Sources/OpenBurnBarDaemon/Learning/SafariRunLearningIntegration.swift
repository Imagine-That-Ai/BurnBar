import Foundation
import OpenBurnBarKernel

/// Pure conversion from a completed Safari run journal into the explicit,
/// review-gated observations accepted by `LearningCoordinator`.
///
/// This layer deliberately ignores tool arguments, outputs, screenshots, page
/// context, and DOM extracts. Learning evidence contains only a bounded,
/// sanitized user-task summary and the ordered Safari tool-kind sequence.
struct SafariRunLearningIntegration {
    private static let maximumTaskSummaryBytes = 512

    static func observations(
        runID: BurnBarRunID,
        prompt: String,
        metadata: BurnBarRunCreateMetadata,
        journalEvents: [BurnBarRunJournalEvent],
        observedAt: Date
    ) -> [BurnBarSafariLearningObservation] {
        guard metadata.stringValue(forKey: .surface) == "safari_extension",
              metadata.boolValue(forKey: .learningOptedIn) == true,
              let safariSessionID = metadata.stringValue(
                  forKey: .safariSessionId
              ),
              let rawSourceURL = metadata.stringValue(forKey: .safariURL),
              let sourceURL = normalizedOrigin(rawSourceURL),
              let taskSummary = sanitizedTaskSummary(prompt) else {
            return []
        }

        let sourceTitle = sanitizedSourceTitle(from: metadata)
        let completedCalls = journalEvents.compactMap(toolCompletion)
            .filter { $0.tool.isSafariComputerUse }
        let modifyingCalls = completedCalls.filter {
            $0.status == .completed && $0.tool.isLearningModifyingSafariAction
        }
        let modifyingSequence = modifyingCalls.map(\.tool.rawValue)
        let workflowEvidence = """
        Completed Safari task: \(taskSummary)
        Safari action sequence: \(modifyingSequence.joined(separator: " -> "))
        """
        var observations: [BurnBarSafariLearningObservation] = []

        if modifyingCalls.count >= 5 {
            observations.append(
                observation(
                    id: "safari-run:\(runID.rawValue):long",
                    sessionID: safariSessionID,
                    runID: runID,
                    sourceURL: sourceURL,
                    sourceTitle: sourceTitle,
                    trigger: .longActionSequence,
                    actionCount: modifyingCalls.count,
                    content: workflowEvidence,
                    tags: ["safari_extension", "completed_run", "long_sequence"],
                    observedAt: observedAt
                )
            )
        }

        if let recovery = recoveredFailure(in: completedCalls) {
            let recoveryEvidence = """
            Completed Safari task: \(taskSummary)
            Recovery sequence: \(recovery.failed.tool.rawValue) failed, then \(recovery.recovered.tool.rawValue) succeeded.
            """
            observations.append(
                observation(
                    id: "safari-run:\(runID.rawValue):recovery",
                    sessionID: safariSessionID,
                    runID: runID,
                    sourceURL: sourceURL,
                    sourceTitle: sourceTitle,
                    trigger: .recoveredFailure,
                    actionCount: 2,
                    content: recoveryEvidence,
                    tags: ["safari_extension", "completed_run", "recovered_failure"],
                    observedAt: observedAt
                )
            )
        }

        if modifyingCalls.isEmpty == false {
            observations.append(
                observation(
                    id: "safari-run:\(runID.rawValue):repeat",
                    sessionID: safariSessionID,
                    runID: runID,
                    sourceURL: sourceURL,
                    sourceTitle: sourceTitle,
                    trigger: .repeatedWorkflow,
                    actionCount: modifyingCalls.count,
                    content: workflowEvidence,
                    tags: ["safari_extension", "completed_run", "workflow"],
                    observedAt: observedAt
                )
            )
        }

        return observations
    }

    private static func observation(
        id: String,
        sessionID: String,
        runID: BurnBarRunID,
        sourceURL: String,
        sourceTitle: String,
        trigger: BurnBarSafariLearningTrigger,
        actionCount: Int,
        content: String,
        tags: [String],
        observedAt: Date
    ) -> BurnBarSafariLearningObservation {
        BurnBarSafariLearningObservation(
            observationId: id,
            safariSessionId: sessionID,
            runId: runID.rawValue,
            sourceURL: sourceURL,
            sourceTitle: sourceTitle,
            trigger: trigger,
            actionCount: actionCount,
            content: content,
            tags: tags,
            observedAt: observedAt
        )
    }

    private static func toolCompletion(
        _ event: BurnBarRunJournalEvent
    ) -> BurnBarToolCallSnapshot? {
        guard event.kind == .toolCompleted, let payload = event.payload,
              let data = try? JSONEncoder().encode(payload) else {
            return nil
        }
        return try? JSONDecoder().decode(
            BurnBarToolCallSnapshot.self,
            from: data
        )
    }

    private static func recoveredFailure(
        in calls: [BurnBarToolCallSnapshot]
    ) -> (failed: BurnBarToolCallSnapshot, recovered: BurnBarToolCallSnapshot)? {
        for (index, call) in calls.enumerated() where call.status == .failed {
            guard let recovered = calls.dropFirst(index + 1).first(where: {
                $0.status == .completed
                    && $0.tool.isLearningModifyingSafariAction
            }) else {
                continue
            }
            return (call, recovered)
        }
        return nil
    }

    private static func sanitizedTaskSummary(_ prompt: String) -> String? {
        let compact = prompt
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard compact.isEmpty == false else { return nil }
        let bounded = boundedUTF8Prefix(
            compact,
            maximumBytes: maximumTaskSummaryBytes
        )
        guard let sanitized = try? SafariLearningSecurity
            .sanitizeForPersistence(bounded),
              sanitized.text.utf8.count >= 8,
              SafariLearningSecurity.isNoisyObservation(sanitized.text)
                == false else {
            return nil
        }
        return sanitized.text
    }

    private static func sanitizedSourceTitle(
        from metadata: BurnBarRunCreateMetadata
    ) -> String {
        let rawTitle = metadata[.safariPageContext]?
            .objectValue()?["pageState"]?
            .objectValue()?["title"]?
            .stringValue()
            ?? "Safari page"
        return (try? SafariLearningSecurity.sanitizeForPersistence(rawTitle))?
            .text ?? "Safari page"
    }

    private static func normalizedOrigin(_ rawURL: String) -> String? {
        guard var components = URLComponents(string: rawURL),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(),
              host.isEmpty == false,
              components.user == nil,
              components.password == nil else {
            return nil
        }
        components.scheme = scheme
        components.host = host
        components.path = ""
        components.query = nil
        components.fragment = nil
        if (scheme == "https" && components.port == 443)
            || (scheme == "http" && components.port == 80) {
            components.port = nil
        }
        return components.url?.absoluteString
    }

    private static func boundedUTF8Prefix(
        _ value: String,
        maximumBytes: Int
    ) -> String {
        guard value.utf8.count > maximumBytes else { return value }
        var result = ""
        result.reserveCapacity(maximumBytes)
        for character in value {
            let candidate = result + String(character)
            guard candidate.utf8.count <= maximumBytes else { break }
            result = candidate
        }
        return result
    }
}

private extension BurnBarToolKind {
    var isLearningModifyingSafariAction: Bool {
        switch self {
        case .safariClick, .safariType, .safariPressKey, .safariScroll,
             .safariHover, .safariFocus, .safariSelectOption, .safariNavigate,
             .safariOpenTab, .safariCloseTab, .safariRunJavaScript,
             .safariAbort:
            return true
        case .safariPageContext, .safariScreenshot,
             .safariFullPageScreenshot, .safariListTabs, .safariWaitFor,
             .safariExtract:
            return false
        default:
            return false
        }
    }
}

extension BurnBarRunService {
    func emitSafariLearningObservationsIfNeeded(
        for run: BurnBarManagedRun
    ) async {
        guard let safariLearningObservationSink else { return }
        let events: [BurnBarRunJournalEvent]
        do {
            events = try await runJournal.events(for: run.runID)
        } catch {
            logger.warning(
                "safari_learning_observation_journal_unavailable",
                metadata: [
                    "run_id": run.runID.rawValue,
                    "error": error.localizedDescription
                ]
            )
            return
        }
        let observations = SafariRunLearningIntegration.observations(
            runID: run.runID,
            prompt: run.originalPrompt,
            metadata: run.metadata,
            journalEvents: events,
            observedAt: run.snapshot.updatedAt
        )
        for observation in observations {
            do {
                try await safariLearningObservationSink(observation)
            } catch {
                // Learning is review-gated, optional, and downstream of task
                // completion. It must never rewrite a successful run outcome.
                logger.warning(
                    "safari_learning_observation_rejected",
                    metadata: [
                        "run_id": run.runID.rawValue,
                        "trigger": observation.trigger.rawValue,
                        "error": error.localizedDescription
                    ]
                )
            }
        }
    }
}
