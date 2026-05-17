import OpenBurnBarCore
import Foundation

public enum BurnBarPlannerServiceError: Error, LocalizedError {
    case invalidIntent(String)
    case invalidPlannerInput(String)
    case unsupportedWorkflow(String)

    public var errorDescription: String? {
        switch self {
        case .invalidIntent(let message):
            return "OpenBurnBar planner could not normalize the requested intent: \(message)"
        case .invalidPlannerInput(let message):
            return "OpenBurnBar planner input is invalid: \(message)"
        case .unsupportedWorkflow(let type):
            return "OpenBurnBar planner does not support workflow type '\(type)'. Supported types: replace_string_in_file."
        }
    }
}

/// Extended planned run that preserves typed planner input fields through planning and dispatch.
public struct BurnBarPlannedRun: Sendable {
    public let intent: BurnBarAgentIntent
    public let outline: BurnBarPlanOutline
    /// Constraints from the typed planner input, preserved for dispatch snapshots.
    public let constraints: [String]
    /// Risk level from the typed planner input, preserved for dispatch snapshots.
    public let riskLevel: BurnBarToolRisk
    /// Desired outputs from the typed planner input, preserved for dispatch snapshots.
    public let desiredOutputs: [String]

    public init(
        intent: BurnBarAgentIntent,
        outline: BurnBarPlanOutline,
        constraints: [String] = [],
        riskLevel: BurnBarToolRisk = .low,
        desiredOutputs: [String] = []
    ) {
        self.intent = intent
        self.outline = outline
        self.constraints = constraints
        self.riskLevel = riskLevel
        self.desiredOutputs = desiredOutputs
    }
}

public struct BurnBarPlannerService {
    private let logger = BurnBarDaemonLogger(category: "planner")
    public init() {}

    /// Plans from a raw run create request (backwards-compatible, no typed input validation).
    public func plan(for request: BurnBarRunCreateRequest) throws -> BurnBarPlannedRun {
        let intent = try normalizeIntent(from: request)
        return BurnBarPlannedRun(
            intent: intent,
            outline: makePlanOutline(for: intent)
        )
    }

    /// Plans from a typed planner input with required field validation.
    /// - Throws: `BurnBarPlannerInputError.missingRequiredField` if constraints, riskLevel, or desiredOutputs are empty.
    public func plan(for input: BurnBarPlannerInput) throws -> BurnBarPlannedRun {
        // Validate required fields per VAL-DAEMON-014
        if input.constraints.isEmpty {
            throw BurnBarPlannerServiceError.invalidPlannerInput(
                "constraints cannot be empty. At least one constraint must be specified."
            )
        }
        if input.desiredOutputs.isEmpty {
            throw BurnBarPlannerServiceError.invalidPlannerInput(
                "desiredOutputs cannot be empty. At least one desired output must be specified."
            )
        }

        // Validate schema version
        guard input.schemaVersion == 1 else {
            throw BurnBarPlannerInputError.unsupportedSchemaVersion(input.schemaVersion)
        }

        return BurnBarPlannedRun(
            intent: input.normalizedIntent,
            outline: makePlanOutline(for: input.normalizedIntent),
            constraints: input.constraints,
            riskLevel: input.riskLevel,
            desiredOutputs: input.desiredOutputs
        )
    }

    public func normalizeIntent(from request: BurnBarRunCreateRequest) throws -> BurnBarAgentIntent {
        if let providedIntent = request.metadata[.agentIntent] {
            var intent = try providedIntent.decode(BurnBarAgentIntent.self)
            // Infer requestedTools from intent kind if not provided
            if intent.requestedTools == nil {
                let inferredTools = inferredRequestedTools(for: intent.kind)
                intent = BurnBarAgentIntent(
                    kind: intent.kind,
                    objective: intent.objective,
                    summary: intent.summary,
                    targetPath: intent.targetPath,
                    searchQuery: intent.searchQuery,
                    replacement: intent.replacement,
                    terminalCommand: intent.terminalCommand,
                    requestedTools: inferredTools,
                    toolArguments: intent.toolArguments
                )
            }
            return intent
        }

        if let workflowIntent = try intentFromWorkflowMetadata(request) {
            return workflowIntent
        }

        if let toolIntent = try intentFromToolMetadata(request) {
            return toolIntent
        }

        if let promptIntent = intentFromPrompt(request.prompt, metadata: request.metadata) {
            return promptIntent
        }

        return BurnBarAgentIntent(
            kind: .generic,
            objective: request.prompt,
            summary: "Investigate the request, perform the next useful action, and verify the outcome."
        )
    }

    private func intentFromWorkflowMetadata(_ request: BurnBarRunCreateRequest) throws -> BurnBarAgentIntent? {
        let workflowValue = request.metadata[.workspaceWorkflow] ?? request.metadata[.workflow]
        guard let workflowValue else {
            return nil
        }

        let workflow = try workflowValue.decode(BurnBarReplaceStringWorkflowPayload.self)
        // Only supported workflow type is replace_string_in_file
        guard workflow.type == "replace_string_in_file" else {
            // Unsupported workflow type is a validation error - fail pre-execution per VAL-DAEMON-008
            throw BurnBarPlannerServiceError.unsupportedWorkflow(workflow.type)
        }

        return BurnBarAgentIntent(
            kind: .replaceStringInFile,
            objective: request.prompt,
            summary: "Inspect the target file, replace the requested text, and verify the edit.",
            targetPath: workflow.path,
            replacement: BurnBarTextReplacement(from: workflow.from, to: workflow.to),
            requestedTools: [.readFile, .applyPatch]
        )
    }

    private func intentFromToolMetadata(_ request: BurnBarRunCreateRequest) throws -> BurnBarAgentIntent? {
        guard let toolKind = request.metadata.toolKindValue(forKey: .toolKind) else {
            return nil
        }

        let toolArguments = request.metadata[.toolArguments]
        switch toolKind {
        case .runTerminal:
            let terminalPayload = (toolArguments ?? .object([:]))
            let terminalIntent = try terminalPayload.decode(BurnBarTerminalCommandIntent.self)
            return BurnBarAgentIntent(
                kind: .runTerminal,
                objective: request.prompt,
                summary: "Prepare and execute the requested terminal command, then verify the outcome.",
                terminalCommand: terminalIntent,
                requestedTools: [.runTerminal],
                toolArguments: toolArguments
            )
        case .searchWorkspace:
            let query: BurnBarSearchQueryPayload?
            do {
                query = try toolArguments?.decode(BurnBarSearchQueryPayload.self)
            } catch {
                logger.silentFailure("decode_search_query_payload", error: error)
                query = nil
            }
            return BurnBarAgentIntent(
                kind: .inspectWorkspace,
                objective: request.prompt,
                summary: "Search the workspace and inspect the most relevant matches.",
                targetPath: nil,
                searchQuery: query?.query,
                requestedTools: [.searchWorkspace],
                toolArguments: toolArguments
            )
        case .readFile, .applyPatch,
             .browserClick, .browserFill, .browserGoto, .browserKey,
             .browserSelect, .browserScreenshot, .browserExtract,
             .macInputClick, .macInputType, .macInputKey,
             .macInputShortcut, .macInputDragDrop, .macInputScroll, .macInspectAccessibility:
            return BurnBarAgentIntent(
                kind: .generic,
                objective: request.prompt,
                summary: "Execute the requested workspace tool and verify the result.",
                targetPath: request.metadata.stringValue(forKey: .filePath) ?? request.metadata.stringValue(forKey: .path),
                requestedTools: [toolKind],
                toolArguments: toolArguments
            )
        }
    }

    private func makePlanOutline(for intent: BurnBarAgentIntent) -> BurnBarPlanOutline {
        switch intent.kind {
        case .replaceStringInFile:
            return BurnBarPlanOutline(
                objective: intent.objective,
                steps: [
                    BurnBarPlanStep(
                        title: "Inspect target file",
                        detail: "Read the target file and confirm the existing text before editing."
                    ),
                    BurnBarPlanStep(
                        title: "Apply requested edit",
                        detail: "Replace the requested text in the target file using the workspace companion."
                    ),
                    BurnBarPlanStep(
                        title: "Verify result",
                        detail: "Confirm the replacement was applied and the run can complete safely."
                    )
                ]
            )
        case .runTerminal:
            return BurnBarPlanOutline(
                objective: intent.objective,
                steps: [
                    BurnBarPlanStep(
                        title: "Prepare terminal action",
                        detail: "Check the command intent, working directory, and approval requirements."
                    ),
                    BurnBarPlanStep(
                        title: "Execute command",
                        detail: "Run the terminal command through the workspace companion."
                    ),
                    BurnBarPlanStep(
                        title: "Verify outcome",
                        detail: "Capture the result and confirm the run can continue or complete."
                    )
                ]
            )
        case .inspectWorkspace:
            return BurnBarPlanOutline(
                objective: intent.objective,
                steps: [
                    BurnBarPlanStep(
                        title: "Search the workspace",
                        detail: "Search for the highest-signal files and symbols related to the request."
                    ),
                    BurnBarPlanStep(
                        title: "Inspect relevant context",
                        detail: "Read the most relevant files before taking any follow-up action."
                    ),
                    BurnBarPlanStep(
                        title: "Summarize findings",
                        detail: "Use the gathered context to decide the next explicit action or final answer."
                    )
                ]
            )
        case .generic:
            return BurnBarPlanOutline(
                objective: intent.objective,
                steps: [
                    BurnBarPlanStep(
                        title: "Understand the request",
                        detail: "Inspect the minimum relevant context needed to avoid guessing."
                    ),
                    BurnBarPlanStep(
                        title: "Execute the next action",
                        detail: "Use the appropriate tool or model step to make concrete progress."
                    ),
                    BurnBarPlanStep(
                        title: "Verify completion",
                        detail: "Confirm the requested outcome was achieved before finalizing the run."
                    )
                ]
            )
        }
    }

    private func intentFromPrompt(
        _ prompt: String,
        metadata: BurnBarRunCreateMetadata
    ) -> BurnBarAgentIntent? {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            return nil
        }

        let activeFilePath = metadata.stringValue(forKey: .activeFilePath)
            ?? metadata.stringValue(forKey: .filePath)
            ?? metadata.stringValue(forKey: .path)
        let activeSelectionText = metadata.stringValue(forKey: .activeSelectionText)

        if let replacement = parseReplacementDirective(from: trimmedPrompt, selectedText: activeSelectionText),
           let activeFilePath {
            return BurnBarAgentIntent(
                kind: .replaceStringInFile,
                objective: trimmedPrompt,
                summary: "Inspect the active file, replace the requested text, and verify the edit.",
                targetPath: activeFilePath,
                replacement: replacement,
                requestedTools: [.readFile, .applyPatch]
            )
        }

        if let command = parseTerminalDirective(from: trimmedPrompt) {
            return BurnBarAgentIntent(
                kind: .runTerminal,
                objective: trimmedPrompt,
                summary: "Run the requested terminal command and verify the result.",
                terminalCommand: BurnBarTerminalCommandIntent(command: command, cwd: activeFilePath.flatMap(parentDirectory)),
                requestedTools: [.runTerminal]
            )
        }

        if let query = parseSearchDirective(from: trimmedPrompt) {
            return BurnBarAgentIntent(
                kind: .inspectWorkspace,
                objective: trimmedPrompt,
                summary: "Search the workspace and inspect the most relevant files.",
                searchQuery: query,
                requestedTools: [.searchWorkspace]
            )
        }

        if let activeFilePath, looksLikeReadRequest(trimmedPrompt) {
            return BurnBarAgentIntent(
                kind: .generic,
                objective: trimmedPrompt,
                summary: "Read the active file and verify the relevant context.",
                targetPath: activeFilePath,
                requestedTools: [.readFile]
            )
        }

        return nil
    }

    private func inferredRequestedTools(for kind: BurnBarAgentIntentKind) -> [BurnBarToolKind] {
        switch kind {
        case .inspectWorkspace:
            return [.searchWorkspace]
        case .replaceStringInFile:
            return [.readFile, .applyPatch]
        case .runTerminal:
            return [.runTerminal]
        case .generic:
            return []
        }
    }
}

private struct BurnBarReplaceStringWorkflowPayload: Codable {
    let type: String
    let path: String
    let from: String
    let to: String
}

private struct BurnBarSearchQueryPayload: Codable {
    let query: String
}

private func parseReplacementDirective(
    from prompt: String,
    selectedText: String?
) -> BurnBarTextReplacement? {
    let patterns = [
        #"(?i)\breplace\s+["']([^"']+)["']\s+with\s+["']([^"']+)["']"#,
        #"(?i)\bchange\s+["']([^"']+)["']\s+to\s+["']([^"']+)["']"#
    ]

    for pattern in patterns {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            continue
        }
        let range = NSRange(prompt.startIndex..<prompt.endIndex, in: prompt)
        guard let match = regex.firstMatch(in: prompt, range: range),
              match.numberOfRanges == 3,
              let fromRange = Range(match.range(at: 1), in: prompt),
              let toRange = Range(match.range(at: 2), in: prompt) else {
            continue
        }
        return BurnBarTextReplacement(
            from: String(prompt[fromRange]),
            to: String(prompt[toRange])
        )
    }

    if let selectedText, !selectedText.isEmpty,
       let regex = try? NSRegularExpression(pattern: #"(?i)\bchange\s+(?:it|this|selection|this selection)\s+to\s+["']([^"']+)["']"#),
       let match = regex.firstMatch(in: prompt, range: NSRange(prompt.startIndex..<prompt.endIndex, in: prompt)),
       let toRange = Range(match.range(at: 1), in: prompt) {
        return BurnBarTextReplacement(from: selectedText, to: String(prompt[toRange]))
    }

    return nil
}

private func parseTerminalDirective(from prompt: String) -> String? {
    let patterns = [
        #"(?i)^\s*run\s+(.+)$"#,
        #"(?i)^\s*execute\s+(.+)$"#
    ]

    for pattern in patterns {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: prompt, range: NSRange(prompt.startIndex..<prompt.endIndex, in: prompt)),
              let commandRange = Range(match.range(at: 1), in: prompt) else {
            continue
        }
        let command = String(prompt[commandRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !command.isEmpty {
            return command
        }
    }

    return nil
}

private func parseSearchDirective(from prompt: String) -> String? {
    let patterns = [
        #"(?i)\bsearch\s+for\s+(.+)$"#,
        #"(?i)\bfind\s+(.+)$"#,
        #"(?i)\blook\s+for\s+(.+)$"#
    ]

    for pattern in patterns {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: prompt, range: NSRange(prompt.startIndex..<prompt.endIndex, in: prompt)),
              let queryRange = Range(match.range(at: 1), in: prompt) else {
            continue
        }
        let query = String(prompt[queryRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            return query
        }
    }

    return nil
}

private func looksLikeReadRequest(_ prompt: String) -> Bool {
    let lowercased = prompt.lowercased()
    return lowercased.contains("read ") || lowercased.contains("inspect ") || lowercased.contains("open ")
}

private func parentDirectory(of path: String) -> String? {
    let nsPath = path as NSString
    let parent = nsPath.deletingLastPathComponent
    return parent.isEmpty ? nil : parent
}
