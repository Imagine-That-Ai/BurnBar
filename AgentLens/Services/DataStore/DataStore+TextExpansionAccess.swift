import Foundation
import OpenBurnBarCore

extension DataStoreCoordinator {
    nonisolated func upsertTextExpansionSnippet(_ snippet: TextExpansionSnippet) throws {
        try textExpansionSnippetStore.upsert(snippet)
    }

    nonisolated func saveRemoteTextExpansionSnippet(_ snippet: TextExpansionSnippet, syncedAt: Date = Date()) throws {
        try textExpansionSnippetStore.saveFromRemote(snippet, syncedAt: syncedAt)
    }

    nonisolated func fetchTextExpansionSnippets(includeDeleted: Bool = false) throws -> [TextExpansionSnippet] {
        try textExpansionSnippetStore.fetchAll(includeDeleted: includeDeleted)
    }

    nonisolated func fetchEnabledTextExpansionSnippets(
        surface: TextExpansionSurface? = nil,
        bundleIdentifier: String? = nil,
        threadID: String? = nil
    ) throws -> [TextExpansionSnippet] {
        try textExpansionSnippetStore.fetchEnabled(
            surface: surface,
            bundleIdentifier: bundleIdentifier,
            threadID: threadID
        )
    }

    nonisolated func fetchUnsyncedTextExpansionSnippets(limit: Int = 200) throws -> [TextExpansionSnippet] {
        try textExpansionSnippetStore.fetchUnsynced(limit: limit)
    }

    nonisolated func markTextExpansionSnippetsSynced(ids: [String], at date: Date = Date()) throws {
        try textExpansionSnippetStore.markSynced(ids: ids, at: date)
    }

    nonisolated func deleteTextExpansionSnippet(id: String, at date: Date = Date()) throws {
        try textExpansionSnippetStore.delete(id: id, at: date)
    }
}
