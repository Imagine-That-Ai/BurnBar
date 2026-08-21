import Foundation
import OpenBurnBarCore

/// View-model backing the memory review inbox (`MemoryReviewInboxView`).
///
/// The inbox is the human gate in the quarantine lifecycle (G4): newly extracted
/// memories land as `.quarantined` and cannot be injected or replicated until the
/// user approves them here. This model loads two buckets — pending (quarantined)
/// and approved — opening each sealed body transiently for display only. It never
/// persists or logs the opened body; the string lives only in `Item.body` for the
/// lifetime of the view.
///
/// U7: the inbox serves usage memories (`.safariAsk` / `.agentSession`) alongside
/// chat. Each bucket is loaded once per storage partition — chat with the exact
/// pre-U7 request/paging semantics, usage kinds with the same semantics over the
/// `usage:` partition — and merged in page order, so the chat lane stays
/// byte-identical and neither lane can crowd the other out of its page cap.
/// A second filter axis (`SourceFilter`) narrows the visible rows by source, and
/// every review action routes through the source-kind-guarded store methods with
/// the acted-on row's own kind.
///
/// The closures (`loadPage` / `openBody` / `setStatus` / `forget`) are the seam the
/// integrator wires to the real `MemoryServing` implementation; keeping them injected
/// lets the tests drive the model with in-memory fakes. The init signature and public
/// surface are a frozen contract — coordinate any change with the integrator.
@Observable @MainActor
final class MemoryReviewInboxModel {

    /// One reviewable memory: the authority record plus its transiently-opened body.
    struct Item: Identifiable, Equatable {
        enum BodyLoadState: Equatable {
            case loaded
            case unavailable
        }

        let memory: Memory          // OpenBurnBarCore.Memory
        let body: String            // transiently-opened sealed body (display only)
        let bodyLoadState: BodyLoadState
        var id: MemoryID { memory.id }
        var canApprove: Bool {
            bodyLoadState == .loaded &&
                body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
    }

    /// Which bucket the inbox is showing.
    enum Filter: String, CaseIterable, Identifiable {
        case pending, approved
        var id: String { rawValue }
        var title: String { self == .pending ? "Pending" : "Approved" }
    }

    /// Second filter axis (U7): which extraction source the rows came from.
    /// `.all` admits chat plus both usage kinds; the source-chip row binds here.
    enum SourceFilter: String, CaseIterable, Identifiable {
        case all, chat, safariAsk, agentSession

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: "All"
            case .chat: "Chat"
            case .safariAsk: "Safari asks"
            case .agentSession: "Agent sessions"
            }
        }

        /// Kinds this chip admits; `nil` means no restriction.
        var sourceKinds: Set<MemorySourceKind>? {
            switch self {
            case .all: nil
            case .chat: [.chat]
            case .safariAsk: [.safariAsk]
            case .agentSession: [.agentSession]
            }
        }
    }

    typealias LoadPage = (MemoryPageRequest, Set<MemorySourceKind>) async throws -> MemoryPage
    typealias OpenBody = (MemoryID) async throws -> String?
    typealias SetStatus = (MemoryID, MemoryReviewStatus, Set<MemorySourceKind>) async throws -> Bool
    typealias Forget = (MemoryID, Set<MemorySourceKind>) async throws -> Bool

    /// Every source kind the inbox serves. Daemon-owned `.code` rows are not
    /// review-inbox material and stay invisible here.
    static let servedSourceKinds: Set<MemorySourceKind> =
        Set([MemorySourceKind.chat]).union(MemorySourceKind.usageKinds)

    private(set) var pending: [Item] = []
    private(set) var approved: [Item] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    var filter: Filter = .pending
    var sourceFilter: SourceFilter
    var items: [Item] {
        let bucket = filter == .pending ? pending : approved
        guard let kinds = sourceFilter.sourceKinds else { return bucket }
        return bucket.filter { kinds.contains($0.memory.sourceKind) }
    }
    /// Pending across every served source — usage rows count toward the badge.
    var pendingCount: Int { pending.count }

    private let scope: MemoryScope
    private let loadPage: LoadPage
    private let openBody: OpenBody
    private let setStatus: SetStatus
    private let forgetRecord: Forget

    /// Largest page we request per bucket and per source partition. The inbox is
    /// a review surface, not a paginated browser, so a single generous page keeps
    /// the UI simple while still bounding the fetch.
    private let pageSize = 200

    private static let defaultErrorMessage = "Something went wrong loading your memories. Please try again."
    private static let unavailableBodyApprovalMessage = "Memory contents are unavailable. Reject it or reload before approving."

    init(
        scope: MemoryScope,
        sourceFilter: SourceFilter = .all,
        loadPage: @escaping LoadPage,
        openBody: @escaping OpenBody,
        setStatus: @escaping SetStatus,
        forget: @escaping Forget
    ) {
        self.scope = scope
        self.sourceFilter = sourceFilter
        self.loadPage = loadPage
        self.openBody = openBody
        self.setStatus = setStatus
        self.forgetRecord = forget
    }

    /// Loads both buckets: pending keeps only `.quarantined` (requesting quarantined
    /// rows), approved keeps only `.approved`. Each bucket loads chat and usage
    /// partitions separately — the chat call is the exact pre-U7 fetch — and merges
    /// them in page order. Each kept memory's sealed body is opened best-effort for
    /// display. Drives `isLoading` and surfaces failures via `errorMessage`.
    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let pendingChat = try await loadBucket(
                sourceKinds: [.chat],
                includeQuarantined: true,
                keep: .quarantined
            )
            let pendingUsage = try await loadBucket(
                sourceKinds: MemorySourceKind.usageKinds,
                includeQuarantined: true,
                keep: .quarantined
            )
            let approvedChat = try await loadBucket(
                sourceKinds: [.chat],
                includeQuarantined: false,
                keep: .approved
            )
            let approvedUsage = try await loadBucket(
                sourceKinds: MemorySourceKind.usageKinds,
                includeQuarantined: false,
                keep: .approved
            )
            pending = Self.mergedInPageOrder(pendingChat, pendingUsage)
            approved = Self.mergedInPageOrder(approvedChat, approvedUsage)
        } catch {
            errorMessage = friendlyMessage(for: error)
        }
    }

    /// Approves a memory, then reloads so it moves from pending to approved.
    func approve(_ id: MemoryID) async {
        guard pending.first(where: { $0.id == id })?.canApprove == true else {
            errorMessage = Self.unavailableBodyApprovalMessage
            return
        }
        await transition(id, to: .approved)
    }

    /// Rejects a memory, then reloads so it leaves the pending bucket.
    func reject(_ id: MemoryID) async {
        await transition(id, to: .rejected)
    }

    /// Hard-deletes a memory (member-visible "forget this"): the authority row,
    /// sealed body, and provenance are removed; an approved row leaves a fact
    /// tombstone behind so the deletion replicates (PR1 semantics). Reloads so
    /// the row leaves whichever bucket held it.
    func forget(_ id: MemoryID) async {
        do {
            _ = try await forgetRecord(id, reviewSourceKinds(for: id))
            await load()
        } catch {
            errorMessage = friendlyMessage(for: error)
        }
    }

    // MARK: - Private

    private func transition(_ id: MemoryID, to status: MemoryReviewStatus) async {
        do {
            _ = try await setStatus(id, status, reviewSourceKinds(for: id))
            await load()
        } catch {
            errorMessage = friendlyMessage(for: error)
        }
    }

    /// The source-kind guard for an action on `id`: exactly the acted-on row's
    /// kind, so a usage action can never touch a chat row (or vice versa). Falls
    /// back to every served kind when the row is no longer loaded — the store's
    /// own kind guard still applies, and a stale action then no-ops safely.
    private func reviewSourceKinds(for id: MemoryID) -> Set<MemorySourceKind> {
        (pending + approved)
            .first { $0.id == id }
            .map { [$0.memory.sourceKind] } ?? Self.servedSourceKinds
    }

    /// Merge two per-partition bucket loads back into page order (updatedAt DESC,
    /// id ASC) — the same comparator `memoryPage` serves pages in, so a chat-only
    /// merge is exactly the pre-U7 chat list.
    private static func mergedInPageOrder(_ lhs: [Item], _ rhs: [Item]) -> [Item] {
        (lhs + rhs).sorted { a, b in
            if a.memory.updatedAt == b.memory.updatedAt { return a.id < b.id }
            return a.memory.updatedAt > b.memory.updatedAt
        }
    }

    private func loadBucket(
        sourceKinds: Set<MemorySourceKind>,
        includeQuarantined: Bool,
        keep status: MemoryReviewStatus
    ) async throws -> [Item] {
        var items: [Item] = []
        items.reserveCapacity(pageSize)

        var nextPage = 1
        while items.count < pageSize {
            let request = MemoryPageRequest(
                scope: scope,
                page: nextPage,
                pageSize: pageSize,
                includeQuarantined: includeQuarantined
            )
            let page = try await loadPage(request, sourceKinds)
            guard page.items.isEmpty == false else { break }

            for memory in page.items where memory.reviewStatus == status {
                let bodyState: (String, Item.BodyLoadState)
                do {
                    if let body = try await openBody(memory.id),
                       body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                        bodyState = (body, .loaded)
                    } else {
                        bodyState = ("", .unavailable)
                    }
                } catch {
                    AppLogger.dataStore.silentFailure("Failed to open memory body for \(memory.id)", error: error)
                    bodyState = ("", .unavailable)
                }
                items.append(Item(memory: memory, body: bodyState.0, bodyLoadState: bodyState.1))
                if items.count >= pageSize { break }
            }

            if nextPage * pageSize >= page.total { break }
            nextPage += 1
        }
        return items
    }

    private func friendlyMessage(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? Self.defaultErrorMessage
    }
}
