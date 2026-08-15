import FirebaseCore
import FirebaseFunctions
import Foundation

// MARK: - Usage Curation Cloud Client (U5)
//
// Typed invoker for the U4 callable `curateUsageMemoryBatch` — the metered,
// entitlement-gated gateway for BurnBar-cloud usage-memory curation. Mirrors
// the repo's existing callable adapters (`FirebaseKnowledgeSyncCallable`,
// `MacHostedQuotaPurchaseStore`): `Functions.functions(region: "us-central1")`,
// dictionary payloads, defensive response parsing.
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
        let callable = Functions.functions(region: "us-central1").httpsCallable("curateUsageMemoryBatch")
        let result: HTTPSCallableResult
        do {
            result = try await callable.call(
                Self.payload(lane: lane, candidates: candidates, requestId: requestId)
            )
        } catch {
            throw Self.mapCallableError(error)
        }
        guard let dict = result.data as? [String: Any] else {
            throw UsageCurationCloudError.malformedResponse
        }
        return try Self.response(from: dict)
        // cov:ignore-end
    }

    // MARK: Payload (pure)

    static func payload(
        lane: UsageCurationLane,
        candidates: [UsageCurationCloudCandidate],
        requestId: String
    ) -> [String: Any] {
        [
            "lane": lane.rawValue,
            "requestId": requestId,
            "candidates": candidates.map { candidate -> [String: Any] in
                var entry: [String: Any] = [
                    "id": candidate.id,
                    "sourceKind": candidate.sourceKind,
                    "text": candidate.text
                ]
                if let imageRefs = candidate.imageRefs, imageRefs.isEmpty == false {
                    entry["imageRefs"] = imageRefs
                }
                return entry
            }
        ]
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
            let details = nsError.userInfo[FunctionsErrorDetailsKey] as? [String: Any]
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

    static func response(from dict: [String: Any]) throws -> UsageCurationBatchResponse {
        guard let promptVersion = dict["promptVersion"] as? String,
              let usageDict = dict["usage"] as? [String: Any],
              let allowanceDict = dict["allowance"] as? [String: Any],
              let rawResults = dict["results"] as? [[String: Any]],
              let promptTokens = intValue(usageDict["promptTokens"]),
              let outputTokens = intValue(usageDict["outputTokens"]),
              let lane = (usageDict["lane"] as? String).flatMap(UsageCurationLane.init(rawValue:)),
              let textRemainingMonth = intValue(allowanceDict["textRemainingMonth"]),
              let multimodalRemainingMonth = intValue(allowanceDict["multimodalRemainingMonth"]),
              let resetsAt = allowanceDict["resetsAt"] as? String
        else {
            throw UsageCurationCloudError.malformedResponse
        }

        // Individual malformed result entries are dropped rather than failing
        // the batch — the server already sanitized them, so a shape mismatch
        // here means a contract skew we degrade around, not user data loss
        // (candidates without a result simply stay queued).
        let results: [UsageCurationCuratedMemory] = rawResults.compactMap { raw in
            guard let text = raw["text"] as? String,
                  let kind = raw["kind"] as? String,
                  let candidateId = raw["candidateId"] as? String
            else { return nil }
            return UsageCurationCuratedMemory(
                text: text,
                kind: kind,
                confidence: doubleValue(raw["confidence"]) ?? 0.5,
                keywords: stringArray(raw["keywords"]),
                tags: stringArray(raw["tags"]),
                context: raw["context"] as? String ?? "",
                candidateId: candidateId
            )
        }

        return UsageCurationBatchResponse(
            results: results,
            promptVersion: promptVersion,
            usage: UsageCurationTokenUsage(
                promptTokens: promptTokens,
                outputTokens: outputTokens,
                cachedTokens: intValue(usageDict["cachedTokens"]) ?? 0,
                lane: lane
            ),
            allowance: UsageCurationAllowance(
                textRemainingMonth: textRemainingMonth,
                multimodalRemainingMonth: multimodalRemainingMonth,
                resetsAt: resetsAt
            )
        )
    }

    private static func intValue(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? NSNumber { return value.intValue }
        return nil
    }

    private static func doubleValue(_ raw: Any?) -> Double? {
        if let value = raw as? Double { return value }
        if let value = raw as? NSNumber { return value.doubleValue }
        return nil
    }

    private static func stringArray(_ raw: Any?) -> [String] {
        (raw as? [Any])?.compactMap { $0 as? String } ?? []
    }
}
