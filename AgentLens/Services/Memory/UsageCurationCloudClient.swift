import FirebaseCore
import FirebaseFunctions
import Foundation

// MARK: - Usage Curation Cloud Client (U5)
//
// Typed invoker for the U4 callable `curateUsageMemoryBatch` — the metered,
// entitlement-gated gateway for BurnBar-cloud usage-memory curation. Mirrors
// the repo's existing callable adapters (`FirebaseKnowledgeSyncCallable`,
// `MacHostedQuotaPurchaseStore`): `Functions.functions(region: "us-central1")`,
// with typed Codable request/response wire shapes (strict envelope, lenient
// per-result entries).
//
// PRIVACY INVARIANT: candidate text and image bytes are user usage data. This
// client NEVER logs, prints, or embeds them in errors — the only strings that
// leave through an error path are lane names and server reset timestamps.

// MARK: Contract types

/// The two server curation lanes (U4 contract).
enum UsageCurationLane: String, CaseIterable, Equatable, Sendable {
    case text
    case multimodal
}

/// One extraction candidate in a batch. `imageRefs` entries must be
/// `data:image/...;base64,` URIs or https URLs (multimodal lane only).
struct UsageCurationCloudCandidate: Equatable, Sendable {
    var id: String
    var sourceKind: String
    var text: String
    var imageRefs: [String]?

    init(id: String, sourceKind: String, text: String, imageRefs: [String]? = nil) {
        self.id = id
        self.sourceKind = sourceKind
        self.text = text
        self.imageRefs = imageRefs
    }
}

/// One curated memory in the response (A-MEM atomic-note contract).
struct UsageCurationCuratedMemory: Equatable, Sendable {
    var text: String
    var kind: String
    var confidence: Double
    var keywords: [String]
    var tags: [String]
    var context: String
    var candidateId: String
}

/// Per-call token usage as metered by the server.
struct UsageCurationTokenUsage: Equatable, Sendable {
    var promptTokens: Int
    var outputTokens: Int
    var cachedTokens: Int
    var lane: UsageCurationLane
}

/// Remaining monthly allowance snapshot returned with every successful call.
struct UsageCurationAllowance: Equatable, Sendable {
    var textRemainingMonth: Int
    var multimodalRemainingMonth: Int
    /// ISO-8601 boundary at which the monthly counters reset.
    var resetsAt: String
}

/// Full `curateUsageMemoryBatch` response.
struct UsageCurationBatchResponse: Equatable, Sendable {
    var results: [UsageCurationCuratedMemory]
    var promptVersion: String
    var usage: UsageCurationTokenUsage
    var allowance: UsageCurationAllowance
}

/// Client-side projection of the callable's typed failure modes.
enum UsageCurationCloudError: Error, Equatable {
    /// `resource-exhausted`: the lane's daily or monthly token allowance is
    /// spent. `resetsAt` (ISO-8601) names the boundary that unblocks the lane.
    case budgetExhausted(lane: UsageCurationLane?, resetsAt: String?)
    /// `failed-precondition`: the server kill flag (`usage_curation_enabled`)
    /// halted curation fleet-wide.
    case serverDisabled
    /// `already-exists`: this `requestId` already bought a completed cloud
    /// call; replaying it will never trigger new inference.
    case replayedRequest
    /// The call succeeded transport-wise but the payload did not match the
    /// contract.
    case malformedResponse
    /// Firebase is not configured in this process (no `FirebaseApp`).
    case cloudUnavailable
}

// MARK: Protocol seam

/// Seam over the callable so the pipeline (PR6) and tests inject a fake and no
/// unit test ever touches the network.
protocol UsageCurationCloudClientProtocol: Sendable {
    /// Invoke `curateUsageMemoryBatch`. `requestId` is the idempotency token —
    /// reusing one after a completed call throws `.replayedRequest`.
    func curate(
        lane: UsageCurationLane,
        candidates: [UsageCurationCloudCandidate],
        requestId: String
    ) async throws -> UsageCurationBatchResponse
}

extension UsageCurationCloudClientProtocol {
    /// Convenience overload minting a fresh idempotency token per attempt.
    func curate(
        lane: UsageCurationLane,
        candidates: [UsageCurationCloudCandidate]
    ) async throws -> UsageCurationBatchResponse {
        try await curate(lane: lane, candidates: candidates, requestId: UsageCurationCloudClient.newRequestID())
    }
}

// MARK: Live client

/// Live Firebase adapter. All translation logic (payload building, response
/// parsing, error mapping) is in static pure helpers so tests cover it without
/// a Firebase app or network.
struct UsageCurationCloudClient: UsageCurationCloudClientProtocol {
    /// Fresh idempotency token (one per cloud attempt).
    static func newRequestID() -> String {
        UUID().uuidString
    }

    func curate(
        lane: UsageCurationLane,
        candidates: [UsageCurationCloudCandidate],
        requestId: String
    ) async throws -> UsageCurationBatchResponse {
        // cov:ignore-start -- live Firebase callable round-trip; payload/response/error translation is unit-tested via the static helpers below
        guard FirebaseApp.app() != nil else { throw UsageCurationCloudError.cloudUnavailable }
        let callable = Functions.functions(region: "us-central1").httpsCallable(
            "curateUsageMemoryBatch",
            requestAs: UsageCurationCallableRequest.self,
            responseAs: UsageCurationCallableResponse.self
        )
        let wire: UsageCurationCallableResponse
        do {
            wire = try await callable.call(
                Self.payload(lane: lane, candidates: candidates, requestId: requestId)
            )
        } catch is DecodingError {
            throw UsageCurationCloudError.malformedResponse
        } catch {
            throw Self.mapCallableError(error)
        }
        return try Self.response(from: wire)
        // cov:ignore-end
    }

    // MARK: Payload (pure)

    static func payload(
        lane: UsageCurationLane,
        candidates: [UsageCurationCloudCandidate],
        requestId: String
    ) -> UsageCurationCallableRequest {
        UsageCurationCallableRequest(
            lane: lane.rawValue,
            requestId: requestId,
            candidates: candidates.map { candidate in
                UsageCurationCallableRequest.Candidate(
                    id: candidate.id,
                    sourceKind: candidate.sourceKind,
                    text: candidate.text,
                    // The server rejects imageRefs outside the multimodal lane,
                    // so an empty list is omitted rather than sent as `[]`.
                    imageRefs: candidate.imageRefs?.isEmpty == false ? candidate.imageRefs : nil
                )
            }
        )
    }

    // MARK: Error mapping (pure)

    /// Map `FunctionsErrorDomain` codes onto the typed contract; every other
    /// error (transport, auth, invalid-argument, …) passes through unchanged
    /// for the caller's generic retry/backoff handling.
    static func mapCallableError(_ error: Error) -> Error {
        let nsError = error as NSError
        guard nsError.domain == FunctionsErrorDomain,
              let code = FunctionsErrorCode(rawValue: nsError.code) else {
            return error
        }
        switch code {
        case .resourceExhausted:
            let details = nsError.userInfo[FunctionsErrorDetailsKey] as? NSDictionary
            let lane = (details?["lane"] as? String).flatMap(UsageCurationLane.init(rawValue:))
            return UsageCurationCloudError.budgetExhausted(
                lane: lane,
                resetsAt: details?["resetsAt"] as? String
            )
        case .failedPrecondition:
            return UsageCurationCloudError.serverDisabled
        case .alreadyExists:
            return UsageCurationCloudError.replayedRequest
        default:
            return error
        }
    }

    // MARK: Response parsing (pure)

    /// Decode a raw callable payload (the JSON object Firebase hands back).
    /// Any shape mismatch in the envelope is `.malformedResponse`.
    static func response(fromJSONObject raw: Any) throws -> UsageCurationBatchResponse {
        guard JSONSerialization.isValidJSONObject(raw) else {
            throw UsageCurationCloudError.malformedResponse
        }
        let wire: UsageCurationCallableResponse
        do {
            let data = try JSONSerialization.data(withJSONObject: raw)
            wire = try JSONDecoder().decode(UsageCurationCallableResponse.self, from: data)
        } catch {
            throw UsageCurationCloudError.malformedResponse
        }
        return try response(from: wire)
    }

    static func response(from wire: UsageCurationCallableResponse) throws -> UsageCurationBatchResponse {
        guard let lane = UsageCurationLane(rawValue: wire.usage.lane) else {
            throw UsageCurationCloudError.malformedResponse
        }

        // Individual malformed result entries are dropped rather than failing
        // the batch — the server already sanitized them, so a shape mismatch
        // here means a contract skew we degrade around, not user data loss
        // (candidates without a result simply stay queued).
        let results: [UsageCurationCuratedMemory] = wire.results.compactMap { entry in
            guard let text = entry.text,
                  let kind = entry.kind,
                  let candidateId = entry.candidateId
            else { return nil }
            return UsageCurationCuratedMemory(
                text: text,
                kind: kind,
                confidence: entry.confidence ?? 0.5,
                keywords: entry.keywords ?? [],
                tags: entry.tags ?? [],
                context: entry.context ?? "",
                candidateId: candidateId
            )
        }

        return UsageCurationBatchResponse(
            results: results,
            promptVersion: wire.promptVersion,
            usage: UsageCurationTokenUsage(
                promptTokens: wire.usage.promptTokens,
                outputTokens: wire.usage.outputTokens,
                cachedTokens: wire.usage.cachedTokens ?? 0,
                lane: lane
            ),
            allowance: UsageCurationAllowance(
                textRemainingMonth: wire.allowance.textRemainingMonth,
                multimodalRemainingMonth: wire.allowance.multimodalRemainingMonth,
                resetsAt: wire.allowance.resetsAt
            )
        )
    }
}

// MARK: Wire shapes

/// `curateUsageMemoryBatch` request body (U4 contract).
struct UsageCurationCallableRequest: Encodable, Equatable, Sendable {
    struct Candidate: Encodable, Equatable, Sendable {
        var id: String
        var sourceKind: String
        var text: String
        /// Omitted from the encoded body when `nil`.
        var imageRefs: [String]?
    }

    var lane: String
    var requestId: String
    var candidates: [Candidate]
}

/// `curateUsageMemoryBatch` response body (U4 contract). The envelope is
/// strict; each `results` entry is lenient so one skewed entry is dropped
/// instead of failing the batch.
struct UsageCurationCallableResponse: Decodable, Sendable {
    struct Usage: Decodable, Sendable {
        var promptTokens: Int
        var outputTokens: Int
        var cachedTokens: Int?
        var lane: String
    }

    struct Allowance: Decodable, Sendable {
        var textRemainingMonth: Int
        var multimodalRemainingMonth: Int
        /// ISO-8601 boundary at which the monthly counters reset.
        var resetsAt: String
    }

    struct Entry: Decodable, Sendable {
        var text: String?
        var kind: String?
        var confidence: Double?
        var keywords: [String]?
        var tags: [String]?
        var context: String?
        var candidateId: String?

        private enum CodingKeys: String, CodingKey {
            case text, kind, confidence, keywords, tags, context, candidateId
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            text = Self.lenient(container, .text)
            kind = Self.lenient(container, .kind)
            confidence = Self.lenient(container, .confidence)
            keywords = Self.lenient(container, .keywords)
            tags = Self.lenient(container, .tags)
            context = Self.lenient(container, .context)
            candidateId = Self.lenient(container, .candidateId)
        }

        /// A wrongly-typed field reads as absent rather than failing the entry.
        private static func lenient<T: Decodable>(
            _ container: KeyedDecodingContainer<CodingKeys>,
            _ key: CodingKeys
        ) -> T? {
            do {
                return try container.decodeIfPresent(T.self, forKey: key)
            } catch {
                return nil
            }
        }
    }

    var results: [Entry]
    var promptVersion: String
    var usage: Usage
    var allowance: Allowance
}
