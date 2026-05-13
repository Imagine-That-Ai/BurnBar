import Foundation

// MARK: - burnbar_runtime_status
//
// Lets the model answer "are you online?", "what model are you running?",
// and "which connection am I on?" honestly. The chat service hands the
// tool a `MobileToolRuntimeStatus` snapshot it builds at request time —
// the tool never imports `HermesService` or `PiService` directly so it
// remains shareable across runtimes.

@MainActor
public struct BurnBarRuntimeStatusTool: MobileTool {

    public init() {}

    public static let name = "burnbar_runtime_status"

    public var displayName: String { "Check runtime status" }

    public var description: String {
        """
        Return the current assistant runtime's connection status and \
        selected model. Use when the user asks "are you connected", \
        "what model are you using", "which Mac am I talking to", or any \
        equivalent honesty question about your own runtime.

        Returns a JSON object: `{"runtime": <"hermes"|"pi">, "isReachable": \
        <bool>, "connectionName": <string?>, "connectionMode": <string?>, \
        "selectedModelID": <string?>, "advertisedModel": <string?>, \
        "lastError": <string?>}`.
        """
    }

    public var parametersSchema: [String: Any] {
        MobileToolJSONSchema.object(
            properties: [:],
            required: [],
            description: "No arguments — returns the current runtime snapshot."
        )
    }

    public func execute(
        arguments: String,
        context: any MobileToolContext
    ) async throws -> String {
        let snapshot = context.runtimeStatusSnapshot
        var dict: [String: Any] = [
            "runtime": snapshot.runtime,
            "isReachable": snapshot.isReachable
        ]
        if let connectionName = snapshot.connectionName { dict["connectionName"] = connectionName }
        if let connectionMode = snapshot.connectionMode { dict["connectionMode"] = connectionMode }
        if let selectedModelID = snapshot.selectedModelID { dict["selectedModelID"] = selectedModelID }
        if let advertisedModel = snapshot.advertisedModel { dict["advertisedModel"] = advertisedModel }
        if let lastError = snapshot.lastError, !lastError.isEmpty { dict["lastError"] = lastError }

        let data = try JSONSerialization.data(withJSONObject: dict, options: [])
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
