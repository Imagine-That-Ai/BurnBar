import Foundation
import OpenBurnBarCore

/// Executes chat turns for a single backend implementation.
@MainActor
protocol ChatBackendExecuting: AnyObject {
    var backendID: ChatBackendID { get }
}

/// Registry of chat backend executors keyed by ChatBackendID.
@MainActor
final class ChatBackendRegistry {
    static let shared = ChatBackendRegistry()

    private var executors: [ChatBackendID: ChatBackendExecuting] = [:]

    private init() {}

    func register(_ executor: ChatBackendExecuting) {
        executors[executor.backendID] = executor
    }

    func executor(for backend: ChatBackendID) -> ChatBackendExecuting? {
        executors[backend]
    }
}
