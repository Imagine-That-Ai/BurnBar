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
/// The closures (`loadPage` / `openBody` / `setStatus`) are the seam the integrator
/// wires to the real `MemoryServing` implementation; keeping them injected lets the
/// tests drive the model with in-memory fakes. The init signature and public surface
/// are a frozen contract — coordinate any change with the integrator.
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

    typealias LoadPage = (MemoryPageRequest) async throws -> MemoryPage
    typealias OpenBody = (MemoryID) async throws -> String?
    typealias SetStatus = (MemoryID, MemoryReviewStatus) async throws -> Bool

    private(set) var pending: [Item] = []
    private(set) var approved: [Item] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    var filter: Filter = .pending
    var items: [Item] { filter == .pending ? pending : approved }
    var pendingCount: Int { pending.count }

    /// Pending memories grouped by source thread (for bulk-approve affordance).
    var pendingThreadGroups: [(threadLogicalID: String, count: Int)] {
        var counts: [String: Int] = [:]
        for item in pending where item.canApprove {
            guard let threadID = item.memory.citations.first?.threadLogicalID, threadID.isEmpty == false else {
                continue
            }
            counts[threadID, default: 0] += 1
        }
        return counts
            .map { (threadLogicalID: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                if lhs.count == rhs.count { return lhs.threadLogicalID < rhs.threadLogicalID }
                return lhs.count > rhs.count
            }
    }

    private let scope: MemoryScope
    private let loadPage: LoadPage
    private let openBody: OpenBody
    private let setStatus: SetStatus

    /// Largest page we request per bucket. The inbox is a review surface, not a
    /// paginated browser, so a single generous page keeps the UI simple while still
    /// bounding the fetch.
    private let pageSize = 200

    private static let defaultErrorMessage = "Something went wrong loading your memories. Please try again."
    private static let unavailableBodyApprovalMessage = "Memory contents are unavailable. Reject it or reload before approving."

    init(
        scope: MemoryScope,
        loadPage: @escaping LoadPage,
        openBody: @escaping OpenBody,
        setStatus: @escaping SetStatus
    ) {
        self.scope = scope
        self.loadPage = loadPage
        self.openBody = openBody
        self.setStatus = setStatus
    }

    /// Loads both buckets: pending keeps only `.quarantined` (requesting quarantined
    /// rows), approved keeps only `.approved`. Each kept memory's sealed body is opened
    /// best-effort for display. Drives `isLoading` and surfaces failures via
    /// `errorMessage`.
    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let pendingItems = try await loadBucket(
                includeQuarantined: true,
                keep: .quarantined
            )
            let approvedItems = try await loadBucket(
                includeQuarantined: false,
                keep: .approved
            )
            pending = pendingItems
            approved = approvedItems
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

    /// Approves every pending memory cited from the same thread.
    func approveAllPending(threadLogicalID: String) async {
        let ids = pending
            .filter {
                $0.canApprove &&
                    $0.memory.citations.contains { $0.threadLogicalID == threadLogicalID }
            }
            .map(\.id)
        guard ids.isEmpty == false else { return }
        for id in ids {
            do {
                _ = try await setStatus(id, .approved)
            } catch {
                errorMessage = friendlyMessage(for: error)
                break
            }
        }
        await load()
    }

    // MARK: - Private

    private func transition(_ id: MemoryID, to status: MemoryReviewStatus) async {
        do {
            _ = try await setStatus(id, status)
            await load()
        } catch {
            errorMessage = friendlyMessage(for: error)
        }
    }

    private func loadBucket(
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
            let page = try await loadPage(request)
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
