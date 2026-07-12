// FakeMemoryService.swift
//
// Deterministic in-memory MemoryServing for the frontend track to build and test
// against before the backend's real implementation (PR-5) lands. Swap via DI at the
// PR-5 rendezvous — no frontend rewrite. NOT for production use.

import Foundation

public actor FakeMemoryService: MemoryServing {
    private var memories: [MemoryID: Memory] = [:]
    private var memoryText: [MemoryID: String] = [:]
    private var extractionMemoryIDsByKey: [String: MemoryID] = [:]
    private var events: [MemoryEventID: MemoryEventStatus] = [:]
    private var seq: Int = 0

    public init(seeded: Bool = true) {
        if seeded {
            for fixture in Self.seedFixtures() {
                memories[fixture.id] = fixture
                memoryText[fixture.id] = Self.fixtureText[fixture.id]
            }
        }
    }

    private func nextEvent(_ status: MemoryEventStatus = .succeeded) -> MemoryEventID {
        seq += 1
        let id = "evt_fake_\(seq)"
        events[id] = status
        return id
    }

    private static func fixedDate(_ offset: TimeInterval) -> Date {
        // Stable, non-wall-clock base so fixtures are deterministic across runs.
        Date(timeIntervalSince1970: 1_750_000_000 + offset)
    }

    @discardableResult
    private func insertMemory(_ request: MemoryAddRequest) -> MemoryID {
        seq += 1
        let id = "mem_fake_\(seq)"
        let now = Self.fixedDate(TimeInterval(seq))
        memories[id] = Memory(
            id: id,
            sourceKind: .chat,
            kind: request.kind,
            scope: request.scope,
            confidence: request.confidence,
            bodyRedacted: "fake-snapshot-ref:\(id)",
            reviewStatus: request.reviewStatus,
            citations: request.citations,
            validFrom: now,
            createdAt: now,
            updatedAt: now
        )
        memoryText[id] = request.text
        return id
    }

    public func add(_ request: MemoryAddRequest) async throws -> MemoryEventID {
        insertMemory(request)
        return nextEvent()
    }

    public func search(_ query: MemoryQuery) async throws -> [Memory] {
        Array(
            memories.values
                .filter { $0.validTo == nil }
                .filter { Self.scope($0.scope, matches: query.scope) }
                .sorted { $0.confidence > $1.confidence }
                .prefix(query.limit)
        )
    }

    public func get(id: MemoryID) async throws -> Memory? {
        memories[id]
    }

    public func getAll(_ page: MemoryPageRequest) async throws -> MemoryPage {
        let all = memories.values
            .filter { Self.scope($0.scope, matches: page.scope) }
            .filter { page.includeQuarantined || $0.reviewStatus == .approved }
            .sorted { $0.updatedAt > $1.updatedAt }
        let start = max(0, (page.page - 1) * page.pageSize)
        let slice = Array(all.dropFirst(start).prefix(page.pageSize))
        return MemoryPage(items: slice, page: page.page, pageSize: page.pageSize, total: all.count)
    }

    public func update(id: MemoryID, _ patch: MemoryPatch) async throws -> MemoryEventID {
        guard var mem = memories[id] else { return nextEvent(.failed) }
        if let kind = patch.kind { mem.kind = kind }
        if let confidence = patch.confidence { mem.confidence = confidence }
        if let text = patch.text {
            memoryText[id] = text
            mem.bodyRedacted = "fake-snapshot-ref:\(id):updated"
        }
        mem.updatedAt = Self.fixedDate(TimeInterval(seq + 1))
        memories[id] = mem
        return nextEvent()
    }

    public func delete(id: MemoryID) async throws -> MemoryEventID {
        memories[id] = nil
        memoryText[id] = nil
        return nextEvent()
    }

    public func deleteAll(scope: MemoryScope) async throws -> MemoryEventID {
        let removedIDs = memories.values.filter { $0.scope == scope }.map(\.id)
        memories = memories.filter { $0.value.scope != scope }
        for id in removedIDs {
            memoryText[id] = nil
        }
        return nextEvent()
    }

    public func listEntities() async throws -> [MemoryEntity] {
        var counts: [String: Int] = [:]
        for mem in memories.values {
            if let user = mem.scope.userID { counts["user_id:\(user)", default: 0] += 1 }
        }
        return counts.map { key, count in
            let parts = key.split(separator: ":", maxSplits: 1)
            return MemoryEntity(keyName: String(parts.first ?? ""), value: String(parts.last ?? ""), count: count)
        }
    }

    public func eventStatus(_ id: MemoryEventID) async throws -> MemoryEventStatus {
        events[id] ?? .succeeded
    }

    public func recallForPrompt(_ request: MemoryRecallRequest) async throws -> [MemorySnippet] {
        let approved = memories.values
            .filter { $0.reviewStatus == .approved && $0.validTo == nil }
            .filter { Self.scope($0.scope, matches: request.scope) }
            .sorted { $0.confidence > $1.confidence }
        var out: [MemorySnippet] = []
        var spent = 0
        for mem in approved {
            let text = memoryText[mem.id] ?? "User preference recalled for \(mem.kind.rawValue)."
            let est = max(1, text.count / 4)
            if spent + est > request.tokenBudget || out.count >= request.limit { break }
            spent += est
            out.append(
                MemorySnippet(
                    memoryID: mem.id,
                    text: text,
                    kind: mem.kind,
                    confidence: mem.confidence,
                    citations: mem.citations,
                    trustTier: .untrusted,
                    tokenCountEstimate: est
                )
            )
        }
        return out
    }

    public func approve(id: MemoryID) async throws -> MemoryEventID {
        guard var mem = memories[id] else { return nextEvent(.failed) }
        mem.reviewStatus = .approved
        memories[id] = mem
        return nextEvent()
    }

    public func reject(id: MemoryID) async throws -> MemoryEventID {
        guard var mem = memories[id] else { return nextEvent(.failed) }
        mem.reviewStatus = .rejected
        memories[id] = mem
        return nextEvent()
    }

    public func enqueueExtraction(_ intent: ExtractionIntent) async throws {
        guard extractionMemoryIDsByKey[intent.idempotencyKey] == nil else { return }
        // Fake: synthesize one approved memory citing the source so the frontend can
        // exercise recall + citation rendering end to end.
        let now = Self.fixedDate(TimeInterval(seq + 1))
        let citation = MemoryCitation(
            id: "cite_\(intent.idempotencyKey)",
            threadLogicalID: intent.threadLogicalID,
            messageID: intent.messageID,
            role: "assistant",
            authoredAt: now,
            contentHash: intent.idempotencyKey,
            crossDeviceHMAC: "hmac_\(intent.idempotencyKey)"
        )
        let memoryID = insertMemory(
            MemoryAddRequest(
                text: "Fact extracted from thread \(intent.threadID).",
                scope: intent.scope,
                confidence: 0.7,
                citations: [citation],
                reviewStatus: .approved
            )
        )
        extractionMemoryIDsByKey[intent.idempotencyKey] = memoryID
    }

    private static func scope(_ candidate: MemoryScope, matches query: MemoryScope) -> Bool {
        if let value = query.userID, candidate.userID != value { return false }
        if let value = query.agentID, candidate.agentID != value { return false }
        if let value = query.runID, candidate.runID != value { return false }
        if let value = query.appID, candidate.appID != value { return false }
        if let value = query.projectID, candidate.projectID != value { return false }
        return true
    }

    // MARK: - Fixtures

    private static let fixtureText: [MemoryID: String] = [
        "mem_fixture_1": "User prefers terse answers without preamble.",
        "mem_fixture_2": "User's primary project is OpenBurnBar, a local-first macOS app."
    ]

    private static func seedFixtures() -> [Memory] {
        let scope = MemoryScope(userID: "fixture-user", appID: "openburnbar")
        let now = fixedDate(0)
        return [
            Memory(
                id: "mem_fixture_1",
                kind: .preference,
                scope: scope,
                confidence: 0.92,
                bodyRedacted: "fake-snapshot-ref:mem_fixture_1",
                reviewStatus: .approved,
                citations: [
                    MemoryCitation(
                        id: "cite_fixture_1",
                        threadLogicalID: "thread-logical-A",
                        messageID: "msg-A1",
                        role: "user",
                        authoredAt: now,
                        contentHash: "hash-A1",
                        crossDeviceHMAC: "hmac-A1"
                    )
                ],
                validFrom: now,
                createdAt: now,
                updatedAt: now
            ),
            Memory(
                id: "mem_fixture_2",
                kind: .fact,
                scope: scope,
                confidence: 0.81,
                bodyRedacted: "fake-snapshot-ref:mem_fixture_2",
                reviewStatus: .approved,
                citations: [
                    MemoryCitation(
                        id: "cite_fixture_2",
                        threadLogicalID: "thread-logical-B",
                        messageID: nil,    // cross-device-only: exercises the "source on another device" path
                        role: "user",
                        authoredAt: now,
                        contentHash: "hash-B1",
                        crossDeviceHMAC: "hmac-B1"
                    )
                ],
                validFrom: now,
                createdAt: now,
                updatedAt: now
            )
        ]
    }
}
