import OpenBurnBarCore
import Foundation

public enum BurnBarAgentLoopServiceError: Error, LocalizedError {
    case maxIterationsExceeded(Int)
    case invalidDecision(String)
    case unsupportedAction(String)
    case noProgress(String)

    public var errorDescription: String? {
        switch self {
        case .maxIterationsExceeded(let count):
            return "OpenBurnBar agent loop exceeded the maximum of \(count) iterations."
        case .invalidDecision(let message):
            return "OpenBurnBar agent loop received an invalid model decision: \(message)"
        case .unsupportedAction(let message):
            return "OpenBurnBar agent loop received an unsupported action: \(message)"
        case .noProgress(let message):
            return "OpenBurnBar agent loop detected no progress: \(message)"
        }
    }
}

public struct BurnBarAgentLoopRequest: Sendable {
    public let objective: String
    public let intent: BurnBarAgentIntent
    public let planOutline: BurnBarPlanOutline
    public let loopState: BurnBarAgentLoopState
    public let contextSnapshot: BurnBarAgentContextSnapshot
    public let journalTail: [BurnBarRunJournalEvent]

    public init(
        objective: String,
        intent: BurnBarAgentIntent,
        planOutline: BurnBarPlanOutline,
        loopState: BurnBarAgentLoopState,
        contextSnapshot: BurnBarAgentContextSnapshot,
        journalTail: [BurnBarRunJournalEvent]
    ) {
        self.objective = objective
        self.intent = intent
        self.planOutline = planOutline
        self.loopState = loopState
        self.contextSnapshot = contextSnapshot
        self.journalTail = journalTail
    }
}

public struct BurnBarAgentLoopService: Sendable {
    public let maxIterations: Int
    private let logger = BurnBarDaemonLogger(category: "agent-loop")

    public init(maxIterations: Int = 8) {
        self.maxIterations = maxIterations
    }

    public func decideNextAction(
        request: BurnBarAgentLoopRequest,
        route: BurnBarProviderRoute,
        providerExecutor: any BurnBarProviderExecuting
    ) async throws -> BurnBarAgentLoopDecision {
        guard request.loopState.iterationCount < maxIterations else {
            throw BurnBarAgentLoopServiceError.maxIterationsExceeded(maxIterations)
        }

        let prompt = buildPrompt(for: request)
        let structuredRequest = BurnBarStructuredPromptRequest(
            systemPrompt: systemPrompt(),
            userPrompt: prompt,
            jsonOnly: true
        )

        let firstResult = try await providerExecutor.completeStructured(structuredRequest, route: route)
        if let parsed = tryParseDecision(
            from: firstResult.outputText,
            request: request
        ) {
            return parsed
        }

        let repairRequest = BurnBarStructuredPromptRequest(
            systemPrompt: systemPrompt(repairMode: true),
            userPrompt: prompt,
            jsonOnly: true
        )
        let repairedResult = try await providerExecutor.completeStructured(repairRequest, route: route)
        if let parsed = tryParseDecision(
            from: repairedResult.outputText,
            request: request
        ) {
            return parsed
        }

        throw BurnBarAgentLoopServiceError.invalidDecision("Model did not return valid single-action JSON after repair retry.")
    }

    private func systemPrompt(repairMode: Bool = false) -> String {
        let base = """
        You are OpenBurnBar's daemon-side coding agent loop.
        Respond with exactly one JSON object and no surrounding prose.
        Allowed actions:
        - complete
        - search_workspace
        - read_file
        - apply_patch
        - run_terminal
        - request_approval
        - fail

        Required keys:
        - action
        - rationale
        Optional keys:
        - requestedTool
        - arguments
        - message
        """

        if repairMode {
            return base + "\nYour previous response was invalid. Output strict JSON only."
        }
        return base
    }

    private func buildPrompt(for request: BurnBarAgentLoopRequest) -> String {
        let planSummary = request.planOutline.steps
            .enumerated()
            .map { index, step in
                "\(index + 1). [\(step.status.rawValue)] \(step.title): \(step.detail)"
            }
            .joined(separator: "\n")

        let contextSummary = """
        Candidate paths: \(request.contextSnapshot.candidatePaths.joined(separator: ", "))
        Active file: \(request.contextSnapshot.activeFilePath ?? "none")
        Last read file: \(request.contextSnapshot.lastReadFilePath ?? "none")
        Search hints: \(request.contextSnapshot.searchHints.joined(separator: " | "))
        Search result paths: \(request.contextSnapshot.searchResultPaths.joined(separator: ", "))
        """

        let journalSummary = request.journalTail
            .suffix(6)
            .map { event in
                "\(event.kind.rawValue) @ \(event.phase?.rawValue ?? "none")"
            }
            .joined(separator: "\n")

        return """
        Objective:
        \(request.objective)

        Intent:
        \(request.intent.summary)

        Plan:
        \(planSummary)

        Loop iteration:
        \(request.loopState.iterationCount)

        Context:
        \(contextSummary)

        Recent journal:
        \(journalSummary.isEmpty ? "none" : journalSummary)
        """
    }

    private func tryParseDecision(
        from rawOutput: String,
        request: BurnBarAgentLoopRequest
    ) -> BurnBarAgentLoopDecision? {
        guard let jsonObject = extractJSONObject(from: rawOutput),
              let data = jsonObject.data(using: .utf8) else {
            return nil
        }
        let parsed: RawLoopDecision
        do {
            parsed = try JSONDecoder().decode(RawLoopDecision.self, from: data)
        } catch {
            logger.silentFailure("decode_agent_loop_decision", error: error)
            return nil
        }
        guard let action = BurnBarAgentLoopActionKind(rawValue: parsed.action) else {
            return nil
        }

        let requestedTool = parsed.requestedTool.flatMap(BurnBarToolKind.init(rawValue:))
        let arguments = parsed.arguments

        switch action {
        case .searchWorkspace:
            guard arguments?.objectValue()?["query"]?.stringValue() != nil else {
                return nil
            }
        case .readFile:
            let path = arguments?.objectValue()?["path"]?.stringValue()
                ?? request.contextSnapshot.activeFilePath
                ?? request.contextSnapshot.candidatePaths.first
            guard let path else {
                return nil
            }
            return BurnBarAgentLoopDecision(
                action: action,
                requestedTool: .readFile,
                arguments: .object(["path": .string(path)]),
                rationale: parsed.rationale,
                message: parsed.message
            )
        case .applyPatch:
            guard arguments?.objectValue()?["changes"] != nil else {
                return nil
            }
        case .runTerminal:
            guard arguments?.objectValue()?["command"]?.stringValue() != nil else {
                return nil
            }
        case .requestApproval:
            guard requestedTool != nil else {
                return nil
            }
        case .complete, .fail:
            break
        }

        if action == .searchWorkspace,
           arguments?.objectValue()?["query"]?.stringValue() == request.loopState.lastDecision?.arguments?.objectValue()?["query"]?.stringValue(),
           request.contextSnapshot.searchResultPaths == request.loopState.lastContextSnapshot?.searchResultPaths,
           request.loopState.iterationCount >= 2 {
            return BurnBarAgentLoopDecision(
                action: .fail,
                requestedTool: nil,
                arguments: nil,
                rationale: "Repeated identical search with no new context.",
                message: "OpenBurnBar detected repeated search churn without new progress."
            )
        }

        return BurnBarAgentLoopDecision(
            action: action,
            requestedTool: requestedTool,
            arguments: arguments,
            rationale: parsed.rationale,
            message: parsed.message
        )
    }

    private func extractJSONObject(from rawOutput: String) -> String? {
        guard let startIndex = rawOutput.firstIndex(of: "{") else {
            return nil
        }

        var depth = 0
        var currentIndex = startIndex
        while currentIndex < rawOutput.endIndex {
            let character = rawOutput[currentIndex]
            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(rawOutput[startIndex...currentIndex])
                }
            }
            currentIndex = rawOutput.index(after: currentIndex)
        }

        return nil
    }
}

private struct RawLoopDecision: Codable {
    let action: String
    let requestedTool: String?
    let arguments: BurnBarJSONValue?
    let rationale: String
    let message: String?
}

private extension BurnBarJSONValue {
    func objectValue() -> [String: BurnBarJSONValue]? {
        guard case .object(let value) = self else {
            return nil
        }
        return value
    }

    func stringValue() -> String? {
        guard case .string(let value) = self else {
            return nil
        }
        return value
    }
}
