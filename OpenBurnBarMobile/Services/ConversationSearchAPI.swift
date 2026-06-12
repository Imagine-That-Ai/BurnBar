import Foundation
@preconcurrency import FirebaseFunctions

// MARK: - Conversation Search Servicing

/// Conversation-search domain slice of the Firebase callable surface, split
/// out of `FunctionsRepository` (tech-debt finding-67). Covers cockpit stream
/// search, the encrypted conversation index, the faceted `queryConversations`
/// cockpit query, and encrypted session-blob downloads. Method bodies are
/// verbatim moves from `FunctionsRepository`; the repository remains a facade
/// that forwards here, so existing call sites keep compiling unchanged.
///
/// PRIVACY: server-side `queryConversations` filters are operational facets
/// only — never add a `projectName` (or any text-like) filter here. Project,
/// path, title, and body search must flow through
/// `searchEncryptedConversationIndex` with client-keyed hashes. The privacy
/// plaintext scanner (scripts/privacy/scan-chat-cloud-plaintext.mjs) currently
/// pins this rule to the `FunctionsRepository.queryConversations` facade
/// forwarder, which is the chokepoint all call sites use today; migrating that
/// pin to this file must ride in its own scanner PR.
@MainActor
protocol ConversationSearchServicing: AnyObject {
    func searchStreams(query: String, limit: Int) async throws -> [StreamSearchHit]

    func searchEncryptedConversationIndex(
        tokenHashes: [String],
        semanticHashes: [String],
        limit: Int
    ) async throws -> [CloudConversationSearchHit]

    func queryConversations(
        providers: [String],
        models: [String],
        deviceId: String?,
        sourceType: String?,
        dateFrom: Date?,
        dateTo: Date?,
        sort: String,
        direction: String,
        limit: Int,
        cursorDocId: String?,
        includeAggregates: Bool
    ) async throws -> ConversationQueryResponse

    func encryptedSessionBlobDownloadURL(storagePath: String) async throws -> URL
}

// MARK: - Conversation Search API

@MainActor
final class ConversationSearchAPI: ConversationSearchServicing {
    private let client: FunctionsClientProvider

    init(client: FunctionsClientProvider) {
        self.client = client
    }

    private func functionsClient() throws -> Functions {
        try client.client()
    }

    func searchStreams(query: String, limit: Int = 25) async throws -> [StreamSearchHit] {
        let callable = try functionsClient().httpsCallable("searchStreams")
        let result = try await callable.call([
            "query": query,
            "limit": max(1, min(limit, 50))
        ])
        guard let dict = result.data as? [String: Any],
              let rawHits = dict["hits"] else {
            throw FunctionsError.decodingFailed
        }
        let sanitized = FirestoreRepository.shared.sanitizeForJSON(rawHits)
        let data = try JSONSerialization.data(withJSONObject: sanitized)
        return try JSONDecoder().decode([StreamSearchHit].self, from: data)
    }

    func searchEncryptedConversationIndex(
        tokenHashes: [String],
        semanticHashes: [String] = [],
        limit: Int = 25
    ) async throws -> [CloudConversationSearchHit] {
        let callable = try functionsClient().httpsCallable("searchEncryptedConversationIndex")
        let result = try await callable.call([
            "tokenHashes": Array(tokenHashes.prefix(10)),
            "semanticHashes": Array(semanticHashes.prefix(12)),
            "limit": max(1, min(limit, 50))
        ])
        guard let dict = result.data as? [String: Any],
              let rawHits = dict["hits"] else {
            throw FunctionsError.decodingFailed
        }
        let sanitized = FirestoreRepository.shared.sanitizeForJSON(rawHits)
        let data = try JSONSerialization.data(withJSONObject: sanitized)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([CloudConversationSearchHit].self, from: data)
    }

    /// Faceted, paginated query over the user's encrypted session-log manifests for the cockpit.
    /// Server-side filters are limited to operational facets. Project/path/title/body search must
    /// use `searchEncryptedConversationIndex`, where the client sends keyed hashes and decrypts
    /// result labels locally. Pass `cursorDocId` from a prior `nextCursor` to page; request
    /// aggregates only on the first page (`includeAggregates`) since they cover the whole filtered
    /// set.
    func queryConversations(
        providers: [String] = [],
        models: [String] = [],
        deviceId: String? = nil,
        sourceType: String? = nil,
        dateFrom: Date? = nil,
        dateTo: Date? = nil,
        sort: String = "updatedAt",
        direction: String = "desc",
        limit: Int = 30,
        cursorDocId: String? = nil,
        includeAggregates: Bool = true
    ) async throws -> ConversationQueryResponse {
        let callable = try functionsClient().httpsCallable("queryConversations")
        var payload: [String: Any] = [
            "sort": sort,
            "direction": direction,
            "limit": max(1, min(limit, 100)),
            "includeAggregates": includeAggregates
        ]
        if !providers.isEmpty { payload["providers"] = Array(providers.prefix(20)) }
        if !models.isEmpty { payload["models"] = Array(models.prefix(20)) }
        if let deviceId, !deviceId.isEmpty { payload["deviceId"] = deviceId }
        if let sourceType, !sourceType.isEmpty { payload["sourceType"] = sourceType }
        let iso = ISO8601DateFormatter()
        if let dateFrom { payload["dateFrom"] = iso.string(from: dateFrom) }
        if let dateTo { payload["dateTo"] = iso.string(from: dateTo) }
        if let cursorDocId, !cursorDocId.isEmpty { payload["cursorDocId"] = cursorDocId }

        let result = try await callable.call(payload)
        return try Self.decodeConversationQueryResponse(result.data)
    }

    static func decodeConversationQueryResponse(_ raw: Any?) throws -> ConversationQueryResponse {
        guard let dict = raw as? [String: Any] else {
            throw FunctionsError.decodingFailed
        }
        let sanitized = FirestoreRepository.shared.sanitizeForJSON(dict)
        let data = try JSONSerialization.data(withJSONObject: sanitized)
        return try JSONDecoder().decode(ConversationQueryResponse.self, from: data)
    }

    func encryptedSessionBlobDownloadURL(storagePath: String) async throws -> URL {
        let callable = try functionsClient().httpsCallable("getEncryptedSessionBlobDownloadUrl")
        let result = try await callable.call(["storagePath": storagePath])
        guard let dict = result.data as? [String: Any],
              let raw = dict["downloadURL"] as? String,
              let url = URL(string: raw) else {
            throw FunctionsError.decodingFailed
        }
        return url
    }
}
