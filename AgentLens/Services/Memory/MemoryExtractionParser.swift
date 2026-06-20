import Foundation
import OpenBurnBarCore

// MARK: - Memory Extraction Parser
//
// Strict-JSON parser for the model's extraction output. Pure value type, `Sendable`,
// no I/O. Mirrors `SummaryLLMClient.parseSummaryPayload` (clean-JSON-first, then a
// bounded brace-slice fallback for models that wrap JSON in prose) and hardens it for
// the memory schema: per-candidate validation, confidence clamping, kind mapping,
// length bounds, and a hard candidate ceiling.
//
// The parser is deliberately strict and lossy: a malformed candidate is DROPPED, not
// repaired. An empty / unparseable body yields `[]` (a benign empty — the job still
// succeeds; see the failure taxonomy in `ChatTranscriptExtractor`).

/// One validated candidate the model proposed. `claimedMessageID` is the lookup key
/// the worker resolves against the transcript (PR-D1 must-fix #1) — the parser never
/// treats it as trusted provenance, only as a string the model copied.
struct ExtractedMemoryCandidate: Sendable, Equatable {
    let text: String
    let kind: MemoryKind
    let confidence: Double
    let claimedMessageID: String?
}

enum MemoryExtractionParser {
    /// Maximum characters retained for a single extracted fact body. A durable
    /// memory is a sentence, not a document; this also bounds the work the G7 gate
    /// does per candidate.
    static let maxFactChars = 1_000

    /// Parse `text` into validated candidates, capped at `maxCandidates`.
    static func parse(_ text: String, maxCandidates: Int) -> [ExtractedMemoryCandidate] {
        guard let payload = decodePayload(from: text) else { return [] }
        let cap = max(0, maxCandidates)
        guard cap > 0 else { return [] }

        var results: [ExtractedMemoryCandidate] = []
        for raw in payload.memories {
            if results.count >= cap { break }
            guard let candidate = validate(raw) else { continue }
            results.append(candidate)
        }
        return results
    }

    // MARK: - Decoding

    private static func decodePayload(from text: String) -> RawExtractionPayload? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }

        if let data = trimmed.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(RawExtractionPayload.self, from: data) { // try?-ok(malformed model JSON falls through)
            return decoded
        }

        // Fallback: slice the outermost JSON object out of a prose-wrapped reply.
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"),
              start < end else {
            return nil
        }
        let candidate = String(trimmed[start ... end])
        guard let data = candidate.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RawExtractionPayload.self, from: data) // try?-ok(prose-wrapped malformed JSON rejected)
    }

    // MARK: - Validation

    private static func validate(_ raw: RawExtractionPayload.Memory) -> ExtractedMemoryCandidate? {
        guard let text = raw.text else { return nil }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.isEmpty == false else { return nil }
        let bounded = String(body.prefix(maxFactChars))

        let kind = MemoryKind(rawValue: raw.kind?.lowercased() ?? "") ?? .fact
        let confidence = clampConfidence(raw.confidence)

        let messageID = raw.messageId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedMessageID = (messageID?.isEmpty == false) ? messageID : nil

        return ExtractedMemoryCandidate(
            text: bounded,
            kind: kind,
            confidence: confidence,
            claimedMessageID: normalizedMessageID
        )
    }

    private static func clampConfidence(_ value: Double?) -> Double {
        guard let value, value.isFinite else { return 0.5 }
        return min(max(value, 0.0), 1.0)
    }

    // MARK: - Raw decodable shapes

    private struct RawExtractionPayload: Decodable {
        struct Memory: Decodable {
            let text: String?
            let kind: String?
            let confidence: Double?
            let messageId: String?

            enum CodingKeys: String, CodingKey {
                case text
                case kind
                case confidence
                case messageId
            }

            init(from decoder: Decoder) throws {
                guard let container = try? decoder.container(keyedBy: CodingKeys.self) else { // try?-ok(non-object memory element is dropped)
                    text = nil
                    kind = nil
                    confidence = nil
                    messageId = nil
                    return
                }
                text = try? container.decode(String.self, forKey: .text) // try?-ok(malformed candidate field is dropped)
                kind = try? container.decode(String.self, forKey: .kind) // try?-ok(malformed optional kind falls back to fact)
                confidence = try? container.decode(Double.self, forKey: .confidence) // try?-ok(malformed optional confidence falls back)
                messageId = try? container.decode(String.self, forKey: .messageId) // try?-ok(malformed optional message id is ignored)
            }
        }

        let memories: [Memory]

        enum CodingKeys: String, CodingKey {
            case memories
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            memories = (try? container.decode([Memory].self, forKey: .memories)) ?? [] // try?-ok(malformed memories array yields benign empty)
        }
    }
}
