import GRDB
import OpenBurnBarCore

actor OpenBurnBarMemoryService: MemoryServing {
    struct ScopeAuthorization: Sendable, Equatable {
        let appID: String
        let userID: String?
        let allowsAppOnlyLocalScope: Bool

        init(
            appID: String = "openburnbar",
            userID: String?,
            allowsAppOnlyLocalScope: Bool = true
        ) {
            self.appID = appID
            self.userID = userID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            self.allowsAppOnlyLocalScope = allowsAppOnlyLocalScope
        }
    }

    enum ScopeAuthorizationError: Error, LocalizedError, Equatable {
        case unauthorizedScope

        var errorDescription: String? {
            switch self {
            case .unauthorizedScope:
                "Memory scope is outside the authorized OpenBurnBar app/account boundary."
            }
        }
    }

    typealias ScopeAuthorizationProvider = @MainActor @Sendable () -> ScopeAuthorization?

    private let store: ControlPlaneStore
    private let authorityWritesEnabled: @Sendable () -> Bool
    private let scopeAuthorizationProvider: ScopeAuthorizationProvider?
    private var events: [MemoryEventID: MemoryEventStatus] = [:]
    private var sequence = 0

    init(
        store: ControlPlaneStore,
        authorityWritesEnabled: @escaping @Sendable () -> Bool = {
            ControlPlaneStore.chatMemoryAuthorityWritesEnabledByDefault
        },
        scopeAuthorizationProvider: ScopeAuthorizationProvider? = nil
    ) {
        self.store = store
        self.authorityWritesEnabled = authorityWritesEnabled
        self.scopeAuthorizationProvider = scopeAuthorizationProvider
    }

    private func nextEvent(_ status: MemoryEventStatus = .succeeded) -> MemoryEventID {
        sequence += 1
        let id = "memory-event-\(sequence)"
        events[id] = status
        return id
    }

    private func currentScopeAuthorization() async -> ScopeAuthorization? {
        await scopeAuthorizationProvider?()
    }

    private static func authorizeScope(_ scope: MemoryScope, using authorization: ScopeAuthorization) throws {
        let requestedAppID = scope.appID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        guard requestedAppID == authorization.appID else {
            throw ScopeAuthorizationError.unauthorizedScope
        }

        let requestedUserID = scope.userID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        if let requestedUserID {
            guard requestedUserID == authorization.userID else {
                throw ScopeAuthorizationError.unauthorizedScope
            }
        } else if authorization.allowsAppOnlyLocalScope == false {
            throw ScopeAuthorizationError.unauthorizedScope
        }

        guard scope.projectID == nil else {
            throw ScopeAuthorizationError.unauthorizedScope
        }
    }

    private func authorizeScope(_ scope: MemoryScope) async throws {
        guard let authorization = await currentScopeAuthorization() else { return }
        try Self.authorizeScope(scope, using: authorization)
    }

    private func authorizedMemory(id: MemoryID) async throws -> Memory? {
        guard let memory = try await store.fetchChatMemoryAuthorityRecord(id: id) else { return nil }
        try await authorizeScope(memory.scope)
        return memory
    }

    private static func authorizedScopes(for authorization: ScopeAuthorization) -> [MemoryScope] {
        var scopes = [MemoryScope(appID: authorization.appID)]
        if let userID = authorization.userID {
            scopes.append(MemoryScope(userID: userID, appID: authorization.appID))
        }
        return scopes
    }

    func add(_ request: MemoryAddRequest) async throws -> MemoryEventID {
        try await authorizeScope(request.scope)
        _ = try await store.addChatMemoryAuthorityRecord(request, enabled: authorityWritesEnabled())
        return nextEvent(.succeeded)
    }

    func search(_ query: MemoryQuery) async throws -> [Memory] {
        try await authorizeScope(query.scope)
        return try await store.searchChatMemoryAuthorityRecords(query)
    }

    func get(id: MemoryID) async throws -> Memory? {
        try await authorizedMemory(id: id)
    }

    func getAll(_ page: MemoryPageRequest) async throws -> MemoryPage {
        try await authorizeScope(page.scope)
        return try await store.chatMemoryPage(page)
    }

    func update(id: MemoryID, _ patch: MemoryPatch) async throws -> MemoryEventID {
        guard try await authorizedMemory(id: id) != nil else { return nextEvent(.failed) }
        let updated = try await store.updateChatMemoryAuthorityRecord(id: id, patch: patch)
        return nextEvent(updated ? .succeeded : .failed)
    }

    func delete(id: MemoryID) async throws -> MemoryEventID {
        guard try await authorizedMemory(id: id) != nil else { return nextEvent(.failed) }
        let deleted = try await store.deleteChatMemoryAuthorityRecord(id: id)
        return nextEvent(deleted ? .succeeded : .failed)
    }

    func deleteAll(scope: MemoryScope) async throws -> MemoryEventID {
        try await authorizeScope(scope)
        _ = try await store.deleteChatMemoryAuthorityRecords(scope: scope)
        return nextEvent(.succeeded)
    }

    func listEntities() async throws -> [MemoryEntity] {
        guard let authorization = await currentScopeAuthorization() else {
            return try await store.listChatMemoryEntities()
        }
        var records: [Memory] = []
        for scope in Self.authorizedScopes(for: authorization) {
            records.append(contentsOf: try await store.fetchActiveChatMemoryAuthorityRecords(scope: scope))
        }
        var counts: [String: Int] = [:]
        for memory in records where memory.reviewStatus != .rejected {
            if let value = memory.scope.userID { counts["user_id:\(value)", default: 0] += 1 }
            if let value = memory.scope.agentID { counts["agent_id:\(value)", default: 0] += 1 }
            if let value = memory.scope.runID { counts["run_id:\(value)", default: 0] += 1 }
            if let value = memory.scope.appID { counts["app_id:\(value)", default: 0] += 1 }
            if let value = memory.scope.projectID { counts["project_id:\(value)", default: 0] += 1 }
        }
        return counts.map { key, count in
            let parts = key.split(separator: ":", maxSplits: 1)
            return MemoryEntity(
                keyName: String(parts.first ?? ""),
                value: String(parts.last ?? ""),
                count: count
            )
        }
        .sorted { lhs, rhs in
            if lhs.keyName == rhs.keyName { return lhs.value < rhs.value }
            return lhs.keyName < rhs.keyName
        }
    }

    func eventStatus(_ id: MemoryEventID) async throws -> MemoryEventStatus {
        events[id] ?? .succeeded
    }

    func recallForPrompt(_ request: MemoryRecallRequest) async throws -> [MemorySnippet] {
        try await authorizeScope(request.scope)
        return try await store.recallChatMemorySnippets(request)
    }

    func approve(id: MemoryID) async throws -> MemoryEventID {
        guard try await authorizedMemory(id: id) != nil else { return nextEvent(.failed) }
        let updated = try await store.setChatMemoryReviewStatus(id: id, status: .approved)
        return nextEvent(updated ? .succeeded : .failed)
    }

    func reject(id: MemoryID) async throws -> MemoryEventID {
        guard try await authorizedMemory(id: id) != nil else { return nextEvent(.failed) }
        let updated = try await store.setChatMemoryReviewStatus(id: id, status: .rejected)
        return nextEvent(updated ? .succeeded : .failed)
    }

    func enqueueExtraction(_ intent: ExtractionIntent) async throws {
        try await authorizeScope(intent.scope)
        _ = try await store.enqueueMemoryExtraction(intent)
    }
}

// MARK: - Atomic extraction enqueue (G3/P1b)

extension OpenBurnBarMemoryService: TransactionalMemoryExtractionServing {
    /// Enqueue the extraction-outbox row inside the caller's chat-message transaction so it
    /// commits atomically with the assistant reply (G3/P1b). `nonisolated` so it can run
    /// synchronously within GRDB's `write { db in … }`; it touches only the Sendable `store`,
    /// never actor-isolated state.
    nonisolated func enqueueExtraction(_ intent: ExtractionIntent, in db: Database) throws {
        try Self.authorizeScope(
            intent.scope,
            using: ScopeAuthorization(userID: nil, allowsAppOnlyLocalScope: true)
        )
        _ = try store.enqueueMemoryExtraction(intent, in: db)
    }
}
