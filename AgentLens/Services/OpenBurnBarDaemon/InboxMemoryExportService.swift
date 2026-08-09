import Foundation
import OpenBurnBarKernel

/// Pushes the approved inbox-scoped memory snippets to the daemon (loophole
/// L21: the Chat Memory Authority lives in the app's store; the daemon ticks
/// headless and cannot read it).
///
/// Contract: FULL-SET replacement on every push. The daemon replaces its
/// `ai_inbox_memory_export` table with exactly what the app sends, so a
/// memory the user rejects or forgets disappears from the daemon by omission
/// on the next push — no tombstone protocol needed at this scale.
///
/// Only memories whose citations carry an `ai-inbox:` provenance are exported.
/// General chat memories stay app-side: the inbox cites what the inbox
/// produced, nothing broader.
@MainActor
struct InboxMemoryExportService {
    static let exportLimit = 64

    private let store: ControlPlaneStore
    private let scope: MemoryScope
    private let socketURL: URL

    init(store: ControlPlaneStore, scope: MemoryScope, socketURL: URL) {
        self.store = store
        self.scope = scope
        self.socketURL = socketURL
    }

    /// Best-effort by design: approval must not fail because the daemon is
    /// down. The next successful push heals any missed one because the set is
    /// always complete.
    func pushApprovedSnippets() async {
        do {
            let entries = try await approvedInboxEntries()
            let socketURL = self.socketURL
            // Socket I/O off the main actor: the approval already succeeded,
            // and a slow/absent daemon must not beachball the UI for a
            // best-effort push.
            _ = try await Task.detached(priority: .utility) {
                try OpenBurnBarDaemonSocketClient.inboxMemoryExport(entries: entries, at: socketURL)
            }.value
        } catch {
            // The daemon self-heals on the next push; nothing durable is lost.
            AppLogger.daemon.info(
                "inbox_memory_export_deferred",
                metadata: ["error": "\(error)"]
            )
        }
    }

    func approvedInboxEntries() async throws -> [BurnBarInboxMemoryExportEntry] {
        let page = try await store.chatMemoryPage(
            MemoryPageRequest(scope: scope, page: 1, pageSize: 500, includeQuarantined: false)
        )
        let entries = page.items
            .compactMap { memory -> BurnBarInboxMemoryExportEntry? in
                guard let provenance = memory.citations
                    .map(\.id)
                    .first(where: { $0.hasPrefix("ai-inbox:") }) else { return nil }
                let snippet = memory.bodyRedacted.trimmingCharacters(in: .whitespacesAndNewlines)
                guard snippet.isEmpty == false else { return nil }
                return BurnBarInboxMemoryExportEntry(
                    memoryID: memory.id,
                    provenance: provenance,
                    snippetMarkdown: String(snippet.prefix(500)),
                    approvedAt: memory.updatedAt
                )
            }
        return Array(entries.prefix(Self.exportLimit))
    }
}
