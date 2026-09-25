import Foundation
import OpenBurnBarCore
import Security

// MARK: - Tool Use Loop

extension PiService: MobileToolContext {
    /// Install / replace the navigator the `burnbar_atom_open` tool uses.
    /// Same contract as `HermesService.setToolAtomNavigator`.
    public func setToolAtomNavigator(_ navigator: HermesAtomNavigator?) {
        if let navigator {
            let weakRef = navigator as AnyObject
            self.toolAtomNavigatorReference = weakRef
            self.atomNavigatorAccessor = { [weak weakRef] in
                weakRef as? HermesAtomNavigator
            }
        } else {
            self.toolAtomNavigatorReference = nil
            self.atomNavigatorAccessor = nil
        }
    }

    public var atomNavigator: HermesAtomNavigator? {
        atomNavigatorAccessor?()
    }

    public var availableSessions: [MobileToolSessionSummary] {
        // Pi doesn't (yet) maintain a session list mirror — keep the
        // surface honest by returning empty. The tool reports
        // `total_available: 0` and the model recovers gracefully.
        []
    }

    public var runtimeStatusSnapshot: MobileToolRuntimeStatus {
        MobileToolRuntimeStatus(
            runtime: "pi",
            isReachable: isReachable,
            connectionName: selectedConnection.displayName.nilIfBlank,
            connectionMode: selectedConnection.mode.rawValue,
            selectedModelID: selectedModelID?.nilIfBlank,
            advertisedModel: selectedConnection.advertisedModel?.nilIfBlank,
            lastError: lastError?.nilIfBlank
        )
    }

    /// Execute the streamed tool calls on `message`, append matching
    /// `role: .tool` replies to `messages`, and stamp the call statuses
    /// for the pill UI.
    @discardableResult
    func executeToolCalls(
        for message: inout PiChatMessage
    ) async -> [MobileToolExecutionResult] {
        guard !message.toolCalls.isEmpty else { return [] }
        let pending = message.toolCalls.map { call in
            PendingToolCall(id: call.id, name: call.name, arguments: call.arguments)
        }
        let executor = MobileToolExecutor(catalog: toolCatalog)
        let results = await executor.execute(pending, context: self)

        var updated = message
        var statusByID: [String: String] = [:]
        for r in results {
            statusByID[r.toolCallID] = r.isError ? "failed" : "done"
        }
        updated.toolCalls = updated.toolCalls.map { call in
            PiToolCall(
                id: call.id,
                name: call.name,
                status: statusByID[call.id] ?? call.status,
                arguments: call.arguments,
                detail: call.detail ?? PiService.summarizeToolArguments(call.arguments)
            )
        }
        message = updated

        if let idx = messages.firstIndex(where: { $0.id == message.id }) {
            messages[idx] = message
        }

        for r in results {
            let reply = PiChatMessage(
                role: .tool,
                text: r.content,
                isError: r.isError,
                toolCallID: r.toolCallID
            )
            messages.append(reply)
        }
        return results
    }
}
