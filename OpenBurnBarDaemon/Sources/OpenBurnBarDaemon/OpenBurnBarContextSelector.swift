import OpenBurnBarCore
import Foundation

public enum BurnBarContextSelectorError: Error, LocalizedError {
    case missingTargetPath
    case missingReplacement
    case missingReadContent
    case replacementNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .missingTargetPath:
            return "OpenBurnBar context selection requires a target path."
        case .missingReplacement:
            return "OpenBurnBar context selection requires replacement text."
        case .missingReadContent:
            return "OpenBurnBar context selection requires previously-read file content."
        case .replacementNotFound(let needle):
            return "OpenBurnBar could not find '\(needle)' in the previously-read file."
        }
    }
}

public struct BurnBarContextSelectionState: Hashable, Sendable {
    public let workflowStep: Int
    public let lastReadContent: String?
    public let toolAlreadyCompleted: Bool

    public init(workflowStep: Int, lastReadContent: String?, toolAlreadyCompleted: Bool) {
        self.workflowStep = workflowStep
        self.lastReadContent = lastReadContent
        self.toolAlreadyCompleted = toolAlreadyCompleted
    }
}

public struct BurnBarContextAction: Hashable, Sendable {
    public let tool: BurnBarToolKind
    public let arguments: BurnBarJSONValue

    public init(tool: BurnBarToolKind, arguments: BurnBarJSONValue) {
        self.tool = tool
        self.arguments = arguments
    }
}

public struct BurnBarContextSelector {
    public init() {}

    public func makeContextSnapshot(
        for intent: BurnBarAgentIntent,
        state: BurnBarContextSelectionState,
        lastReadFilePath: String?,
        searchResultPaths: [String]
    ) -> BurnBarAgentContextSnapshot {
        var candidatePaths: [String] = []
        if let targetPath = intent.targetPath {
            candidatePaths.append(targetPath)
        }
        if let lastReadFilePath {
            candidatePaths.append(lastReadFilePath)
        }
        candidatePaths.append(contentsOf: searchResultPaths)

        var dedupedCandidatePaths: [String] = []
        var seen = Set<String>()
        for path in candidatePaths where !path.isEmpty && !seen.contains(path) {
            seen.insert(path)
            dedupedCandidatePaths.append(path)
        }

        var searchHints: [String] = []
        if let searchQuery = intent.searchQuery, !searchQuery.isEmpty {
            searchHints.append(searchQuery)
        }
        if !intent.objective.isEmpty {
            searchHints.append(intent.objective)
        }
        if !intent.summary.isEmpty {
            searchHints.append(intent.summary)
        }

        return BurnBarAgentContextSnapshot(
            candidatePaths: dedupedCandidatePaths,
            activeFilePath: intent.targetPath,
            lastReadFilePath: lastReadFilePath,
            lastReadContent: state.lastReadContent,
            searchHints: searchHints,
            replacementTargetPath: intent.kind == .replaceStringInFile ? intent.targetPath : nil,
            searchResultPaths: searchResultPaths
        )
    }

    public func nextAction(
        for intent: BurnBarAgentIntent,
        state: BurnBarContextSelectionState
    ) throws -> BurnBarContextAction? {
        switch intent.kind {
        case .replaceStringInFile:
            return try nextReplaceStringAction(intent: intent, state: state)
        case .runTerminal:
            guard !state.toolAlreadyCompleted else {
                return nil
            }
            let terminal = try terminalArguments(for: intent)
            return BurnBarContextAction(tool: .runTerminal, arguments: terminal)
        case .inspectWorkspace:
            guard !state.toolAlreadyCompleted else {
                return nil
            }
            if let query = intent.searchQuery, !query.isEmpty {
                return BurnBarContextAction(
                    tool: .searchWorkspace,
                    arguments: .object(["query": .string(query)])
                )
            }
            if let targetPath = intent.targetPath {
                return BurnBarContextAction(
                    tool: .readFile,
                    arguments: .object(["path": .string(targetPath)])
                )
            }
            return nil
        case .generic:
            guard !state.toolAlreadyCompleted, let firstTool = intent.requestedToolsOrEmpty.first else {
                return nil
            }
            switch firstTool {
            case .readFile:
                guard let targetPath = intent.targetPath else {
                    throw BurnBarContextSelectorError.missingTargetPath
                }
                return BurnBarContextAction(
                    tool: .readFile,
                    arguments: .object(["path": .string(targetPath)])
                )
            case .searchWorkspace:
                let query = intent.searchQuery ?? intent.objective
                return BurnBarContextAction(
                    tool: .searchWorkspace,
                    arguments: .object(["query": .string(query)])
                )
            case .applyPatch, .runTerminal,
                 .browserClick, .browserFill, .browserGoto, .browserKey,
                 .browserSelect, .browserScreenshot, .browserExtract,
                 .macInputClick, .macInputType, .macInputKey,
                 .macInputShortcut, .macInputDragDrop, .macInspectAccessibility:
                guard let arguments = intent.toolArguments else {
                    return nil
                }
                return BurnBarContextAction(tool: firstTool, arguments: arguments)
            }
        }
    }

    private func nextReplaceStringAction(
        intent: BurnBarAgentIntent,
        state: BurnBarContextSelectionState
    ) throws -> BurnBarContextAction? {
        guard let targetPath = intent.targetPath else {
            throw BurnBarContextSelectorError.missingTargetPath
        }
        guard let replacement = intent.replacement else {
            throw BurnBarContextSelectorError.missingReplacement
        }

        switch state.workflowStep {
        case 0:
            return BurnBarContextAction(
                tool: .readFile,
                arguments: .object(["path": .string(targetPath)])
            )
        case 1:
            guard let lastReadContent = state.lastReadContent else {
                throw BurnBarContextSelectorError.missingReadContent
            }
            let updatedContent = lastReadContent.replacingOccurrences(of: replacement.from, with: replacement.to)
            guard updatedContent != lastReadContent else {
                throw BurnBarContextSelectorError.replacementNotFound(replacement.from)
            }
            return BurnBarContextAction(
                tool: .applyPatch,
                arguments: .object([
                    "changes": .array([
                        .object([
                            "path": .string(targetPath),
                            "text": .string(updatedContent)
                        ])
                    ])
                ])
            )
        default:
            return nil
        }
    }

    private func terminalArguments(for intent: BurnBarAgentIntent) throws -> BurnBarJSONValue {
        if let toolArguments = intent.toolArguments {
            return toolArguments
        }
        guard let terminal = intent.terminalCommand else {
            return .object([:])
        }
        var arguments: [String: BurnBarJSONValue] = [
            "command": .string(terminal.command)
        ]
        if let cwd = terminal.cwd {
            arguments["cwd"] = .string(cwd)
        }
        if let name = terminal.name {
            arguments["name"] = .string(name)
        }
        if let preserveFocus = terminal.preserveFocus {
            arguments["preserveFocus"] = .bool(preserveFocus)
        }
        return .object(arguments)
    }
}
