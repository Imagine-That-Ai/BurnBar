import Foundation
import OpenBurnBarInsights
import OpenBurnBarKernel

/// The only value permitted to leave the device.
///
/// Deliberately narrower than `RecapFacts`: no raw series, no per-session rows,
/// no file paths, no project names (tokenized by `RecapRedaction`). Numbers
/// travel as their *formatted* strings rather than as raw doubles, which is both
/// smaller and exactly the vocabulary the numeric guard will hold the reply to.
public struct RecapPromptPayload: Encodable, Sendable {

    public struct Metric: Encodable, Sendable {
        public let label: String
        public let value: String
    }

    public struct Comparison: Encodable, Sendable {
        public let comparedTo: String
        public let now: String
        public let then: String
    }

    public struct Candidate: Encodable, Sendable {
        public let id: String
        public let kind: String
        public let suggestedTone: String
        public let draftHeadline: String
        public let draftBody: String
        public let metrics: [Metric]
        public let comparison: Comparison?
    }

    public let month: String
    public let monthsOfHistoryAvailable: Int
    /// Signals that totals and records are not being claimed, so the model does
    /// not write "your biggest month ever" around a partial read.
    public let monthWasReadInFull: Bool
    public let candidates: [Candidate]

    // MARK: - Build

    /// Builds the payload plus the mapping needed to interpret the reply.
    ///
    /// Candidate ids are replaced with opaque tokens (`c1`, `c2`, …) rather
    /// than sent as-is. Rule ids embed their subject — `headline-project:burnbar`
    /// — so shipping them would leak exactly the private names the rest of this
    /// type is careful to tokenize. Opaque ids close that off structurally, so a
    /// future rule cannot reintroduce the leak by naming itself after its subject.
    public static func build(
        context: RecapContext,
        candidates: [RecapCandidate]
    ) -> (payload: RecapPromptPayload, mapping: RecapPromptMapping) {

        var redaction = RecapRedaction()
        for project in context.facts.projects {
            redaction.register(project.label)
        }
        if let sessionProject = context.facts.longestSession?.projectName {
            redaction.register(sessionProject)
        }

        var idByToken: [String: String] = [:]
        let encoded = candidates.enumerated().map { index, candidate in
            let token = "c\(index + 1)"
            idByToken[token] = candidate.id
            return Candidate(
                id: token,
                kind: candidate.kind.rawValue,
                suggestedTone: candidate.tone.rawValue,
                draftHeadline: redaction.redact(candidate.headline),
                draftBody: redaction.redact(candidate.body),
                metrics: candidate.metrics.map { metric in
                    Metric(
                        label: redaction.redact(metric.label),
                        value: metric.formatted
                    )
                },
                comparison: candidate.comparison.map { comparison in
                    Comparison(
                        comparedTo: redaction.redact(comparison.referenceLabel),
                        now: RecapMetric.format(comparison.currentValue, comparison.unit),
                        then: RecapMetric.format(comparison.referenceValue, comparison.unit)
                    )
                }
            )
        }

        let payload = RecapPromptPayload(
            month: context.window.displayLabel(calendar: context.calendar),
            monthsOfHistoryAvailable: context.monthsOfHistory,
            monthWasReadInFull: context.allowsAbsoluteClaims,
            candidates: encoded
        )
        return (payload, RecapPromptMapping(redaction: redaction, idByToken: idByToken))
    }

    /// Compact JSON for the prompt. Sorted keys so the same month always builds
    /// the same prompt — which is what makes the LLM call cacheable and the
    /// pipeline reproducible.
    public func json() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}

// MARK: - Mapping

/// What the caller needs to turn a model reply back into real cards: the
/// private-name tokens and the opaque candidate ids.
public struct RecapPromptMapping: Sendable {
    public let redaction: RecapRedaction
    /// Opaque token -> real candidate id.
    public let idByToken: [String: String]

    public init(redaction: RecapRedaction, idByToken: [String: String]) {
        self.redaction = redaction
        self.idByToken = idByToken
    }

    /// Resolves an id from the reply. Falls through to the raw value so a model
    /// that echoes a real id (rather than the token it was given) still works.
    public func realID(for token: String) -> String {
        idByToken[token] ?? token
    }

    public static let identity = RecapPromptMapping(redaction: RecapRedaction(), idByToken: [:])
}
