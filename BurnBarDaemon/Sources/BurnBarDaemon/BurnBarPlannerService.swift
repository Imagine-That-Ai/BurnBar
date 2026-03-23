import BurnBarCore
import Foundation

public enum BurnBarPlannerServiceError: Error, LocalizedError {
    case invalidIntent(String)

    public var errorDescription: String? {
        switch self {
        case .invalidIntent(let message):
            return "BurnBar planner could not normalize the requested intent: \(message)"
        }
    }
}

public struct BurnBarPlannedRun: Sendable {
    public let intent: BurnBarAgentIntent
    public let outline: BurnBarPlanOutline

    public init(intent: BurnBarAgentIntent, outline: BurnBarPlanOutline) {
        self.intent = intent
        self.outline = outline
    }
}

public struct BurnBarPlannerService {
    public init() {}

    public func plan(for request: BurnBarRunCreateRequest) throws -> BurnBarPlannedRun {
        let intent = try normalizeIntent(from: request)
        return BurnBarPlannedRun(
            intent: intent,
            outline: makePlanOutline(for: intent)
        )
    }

    public func normalizeIntent(from request: BurnBarRunCreateRequest) throws -> BurnBarAgentIntent {
        if let providedIntent = request.metadata["agentIntent"] {
            return try providedIntent.decode(BurnBarAgentIntent.self)
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
        let workflowValue = request.metadata["workspaceWorkflow"] ?? request.metadata["workflow"]
        guard let workflowValue else {
            return nil
        }

        let workflow = try workflowValue.decode(BurnBarReplaceStringWorkflowPayload.self)
        guard workflow.type == "replace_string_in_file" else {
            throw BurnBarPlannerServiceError.invalidIntent("Unsupported workflow type '\(workflow.type)'.")
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
        guard let toolKind = request.metadata.toolKindValue(forKey: "toolKind") else {
            return nil
        }

        let toolArguments = request.metadata["toolArguments"]
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
            let query = try? toolArguments?.decode(BurnBarSearchQueryPayload.self)
            return BurnBarAgentIntent(
                kind: .inspectWorkspace,
                objective: request.prompt,
                summary: "Search the workspace and inspect the most relevant matches.",
                targetPath: nil,
                searchQuery: query?.query,
                requestedTools: [.searchWorkspace],
                toolArguments: toolArguments
            )
        case .readFile, .applyPatch:
            return BurnBarAgentIntent(
                kind: .generic,
                objective: request.prompt,
                summary: "Execute the requested workspace tool and verify the result.",
                targetPath: request.metadata.stringValue(forKey: "filePath") ?? request.metadata.stringValue(forKey: "path"),
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
        metadata: [String: BurnBarJSONValue]
    ) -> BurnBarAgentIntent? {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            return nil
        }

        let activeFilePath = metadata.stringValue(forKey: "activeFilePath")
            ?? metadata.stringValue(forKey: "filePath")
            ?? metadata.stringValue(forKey: "path")
        let activeSelectionText = metadata.stringValue(forKey: "activeSelectionText")

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

private extension Dictionary where Key == String, Value == BurnBarJSONValue {
    func stringValue(forKey key: String) -> String? {
        guard case .string(let value)? = self[key] else {
            return nil
        }
        return value
    }

    func toolKindValue(forKey key: String) -> BurnBarToolKind? {
        guard let rawValue = stringValue(forKey: key) else {
            return nil
        }
        return BurnBarToolKind(rawValue: rawValue)
    }
}
