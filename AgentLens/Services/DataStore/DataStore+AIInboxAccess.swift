import Foundation
import OpenBurnBarCore

/// Thin pass-through to the AI Inbox reads/writes on `ControlPlaneStore`,
/// matching `DataStore+ControlPlaneAccess`. Views talk to `DataStore`; the actor
/// owns the connection.
extension DataStore {
    func fetchAIInboxRows(
        states: [BurnBarInboxItemState]? = BurnBarInboxItemState.openStates,
        limit: Int = 200
    ) async throws -> [ControlPlaneStore.AIInboxRow] {
        try await actor.controlPlaneStore.fetchAIInboxRows(states: states, limit: limit)
    }

    func fetchAIInboxRow(id: String) async throws -> ControlPlaneStore.AIInboxRow? {
        try await actor.controlPlaneStore.fetchAIInboxRow(id: id)
    }

    func aiInboxUnreadCount() async throws -> Int {
        try await actor.controlPlaneStore.aiInboxUnreadCount()
    }

    func aiInboxChangeMarker() async throws -> String {
        try await actor.controlPlaneStore.aiInboxChangeMarker()
    }

    func fetchAIInboxRuns(limit: Int = 20) async throws -> [BurnBarInboxRunTelemetry] {
        try await actor.controlPlaneStore.fetchAIInboxRuns(limit: limit)
    }

    func fetchAIInboxItemStates(limit: Int = 500) async throws -> [ControlPlaneStore.AIInboxItemStateRow] {
        try await actor.controlPlaneStore.fetchAIInboxItemStates(limit: limit)
    }

    @discardableResult
    func applyRemoteAIInboxItemState(_ state: AIInboxMirrorItemState) async throws -> Bool {
        try await actor.controlPlaneStore.applyRemoteAIInboxItemState(state)
    }

    func markAIInboxItemRead(id: String) async throws {
        try await actor.controlPlaneStore.markAIInboxItemRead(id: id)
    }

    func markAIInboxItemUnread(id: String) async throws {
        try await actor.controlPlaneStore.markAIInboxItemUnread(id: id)
    }

    func setAIInboxItemArchived(id: String, archived: Bool) async throws {
        try await actor.controlPlaneStore.setAIInboxItemArchived(id: id, archived: archived)
    }

    func snoozeAIInboxItem(id: String, until: Date?) async throws {
        try await actor.controlPlaneStore.snoozeAIInboxItem(id: id, until: until)
    }

    func setAIInboxItemFeedback(id: String, feedback: String?) async throws {
        try await actor.controlPlaneStore.setAIInboxItemFeedback(id: id, feedback: feedback)
    }

    func markAllAIInboxItemsRead() async throws {
        try await actor.controlPlaneStore.markAllAIInboxItemsRead()
    }
}
