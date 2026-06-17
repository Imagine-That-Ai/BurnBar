import Foundation
import OpenBurnBarCore

extension DataStoreCoordinator {
    func upsertTextExpansionSnippet(_ snippet: TextExpansionSnippet) async throws {
        try await actor.textExpansionSnippetStore.upsert(snippet)
    }

    func saveRemoteTextExpansionSnippet(_ snippet: TextExpansionSnippet, syncedAt: Date = Date()) async throws {
        try await actor.textExpansionSnippetStore.saveFromRemote(snippet, syncedAt: syncedAt)
    }

    func fetchTextExpansionSnippets(includeDeleted: Bool = false) async throws -> [TextExpansionSnippet] {
        try await actor.textExpansionSnippetStore.fetchAll(includeDeleted: includeDeleted)
    }

    func fetchEnabledTextExpansionSnippets(
        surface: TextExpansionSurface? = nil,
        bundleIdentifier: String? = nil,
        threadID: String? = nil
    ) async throws -> [TextExpansionSnippet] {
        try await actor.textExpansionSnippetStore.fetchEnabled(
            surface: surface,
            bundleIdentifier: bundleIdentifier,
            threadID: threadID
        )
    }

    func fetchUnsyncedTextExpansionSnippets(limit: Int = 200) async throws -> [TextExpansionSnippet] {
        try await actor.textExpansionSnippetStore.fetchUnsynced(limit: limit)
    }

    func markTextExpansionSnippetsSynced(ids: [String], at date: Date = Date()) async throws {
        try await actor.textExpansionSnippetStore.markSynced(ids: ids, at: date)
    }

    func deleteTextExpansionSnippet(id: String, at date: Date = Date()) async throws {
        try await actor.textExpansionSnippetStore.delete(id: id, at: date)
    }
}
