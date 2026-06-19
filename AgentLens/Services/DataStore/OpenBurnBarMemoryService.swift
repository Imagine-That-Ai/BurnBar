import OpenBurnBarCore

actor OpenBurnBarMemoryService: MemoryServing {
    private let store: ControlPlaneStore
    private var events: [MemoryEventID: MemoryEventStatus] = [:]
    private var sequence = 0

    init(store: ControlPlaneStore) {
        self.store = store
    }

    private func nextEvent(_ status: MemoryEventStatus = .succeeded) -> MemoryEventID {
        sequence += 1
        let id = "memory-event-\(sequence)"
        events[id] = status
        return id
    }

    func add(_ request: MemoryAddRequest) async throws -> MemoryEventID {
        _ = try await store.addChatMemoryAuthorityRecord(request, enabled: true)
        return nextEvent(.succeeded)
    }

    func search(_ query: MemoryQuery) async throws -> [Memory] {
        try await store.searchChatMemoryAuthorityRecords(query)
    }

    func get(id: MemoryID) async throws -> Memory? {
        try await store.fetchChatMemoryAuthorityRecord(id: id)
    }

    func getAll(_ page: MemoryPageRequest) async throws -> MemoryPage {
        try await store.chatMemoryPage(page)
    }

    func update(id: MemoryID, _ patch: MemoryPatch) async throws -> MemoryEventID {
        let updated = try await store.updateChatMemoryAuthorityRecord(id: id, patch: patch)
        return nextEvent(updated ? .succeeded : .failed)
    }

    func delete(id: MemoryID) async throws -> MemoryEventID {
        let deleted = try await store.deleteChatMemoryAuthorityRecord(id: id)
        return nextEvent(deleted ? .succeeded : .failed)
    }

    func deleteAll(scope: MemoryScope) async throws -> MemoryEventID {
        _ = try await store.deleteChatMemoryAuthorityRecords(scope: scope)
        return nextEvent(.succeeded)
    }

    func listEntities() async throws -> [MemoryEntity] {
        try await store.listChatMemoryEntities()
    }

    func eventStatus(_ id: MemoryEventID) async throws -> MemoryEventStatus {
        events[id] ?? .succeeded
    }

    func recallForPrompt(_ request: MemoryRecallRequest) async throws -> [MemorySnippet] {
        try await store.recallChatMemorySnippets(request)
    }

    func approve(id: MemoryID) async throws -> MemoryEventID {
        let updated = try await store.setChatMemoryReviewStatus(id: id, status: .approved)
        return nextEvent(updated ? .succeeded : .failed)
    }

    func reject(id: MemoryID) async throws -> MemoryEventID {
        let updated = try await store.setChatMemoryReviewStatus(id: id, status: .rejected)
        return nextEvent(updated ? .succeeded : .failed)
    }

    func enqueueExtraction(_ intent: ExtractionIntent) async throws {
        _ = try await store.enqueueMemoryExtraction(intent)
    }
}
