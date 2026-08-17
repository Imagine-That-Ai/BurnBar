import Foundation

/// Stage 0 of the usage-memory funnel: the zero-LLM candidate gate.
///
/// Every raw event (a Safari ask, a session-log turn, a synthesized workflow)
/// passes through this pure function before anything is persisted. The entire
/// cost story of usage memory is "don't run a model on most things" — this
/// gate is where most things die. It is pure and `Sendable` so the app, the
/// offline corpus harness, and tests share one implementation, and every drop
/// carries a typed reason so the harness can print an honest histogram.
///
/// Ordering is deliberate: cheap structural drops → hostile-input drops (the
/// G7 secret/PII gate, fail-closed) → junk filters → salience scoring. Page
/// and session text is attacker-controllable data; nothing in this gate
/// interprets it as instructions.
public enum UsageMemoryCandidateGate {
    /// Byte bounds mirror the Safari learning correction contract (8 B – 4 KiB).
    public static let minBytes = 8
    public static let maxBytes = 4096

    public struct Input: Sendable {
        public var sourceKind: MemorySourceKind
        public var text: String
        public var sourceRef: String
        public var threadLogicalID: String
        /// Role of the originating event: "user", "workflow" (synthesized from
        /// repeated tool patterns), anything else is tool/assistant noise.
        public var role: String
        /// The page carried the extension's `sensitive` flag (belt-and-braces;
        /// sensitive asks should never even reach the spool).
        public var sensitivePage: Bool
        /// Prior sightings of this text's SimHash bucket (caller-supplied from
        /// the candidate index; repetition is a keep signal).
        public var repetitionCount: Int

        public init(
            sourceKind: MemorySourceKind,
            text: String,
            sourceRef: String,
            threadLogicalID: String,
            role: String = "user",
            sensitivePage: Bool = false,
            repetitionCount: Int = 0
        ) {
            self.sourceKind = sourceKind
            self.text = text
            self.sourceRef = sourceRef
            self.threadLogicalID = threadLogicalID
            self.role = role
            self.sensitivePage = sensitivePage
            self.repetitionCount = repetitionCount
        }
    }

    public enum DropReason: String, CaseIterable, Sendable {
        case notUsageKind = "not_usage_kind"
        case toolNoise = "tool_noise"
        case sensitivePage = "sensitive_page"
        case tooShort = "too_short"
        case tooLong = "too_long"
        case secretPII = "secret_pii"
        case junk = "junk"
        case noDurableSignal = "no_durable_signal"
    }

    public enum Verdict: Sendable, Equatable {
        case accept(salienceHint: Double)
        case drop(DropReason)
    }

    public static func evaluate(
        _ input: Input,
        policy: UsageMemoryCurationPolicy = .defaults
    ) -> Verdict {
        guard MemorySourceKind.usageKinds.contains(input.sourceKind) else {
            return .drop(.notUsageKind)
        }
        let role = input.role.lowercased()
        guard role == "user" || role == "workflow" else {
            return .drop(.toolNoise)
        }
        if input.sensitivePage {
            return .drop(.sensitivePage)
        }

        let text = input.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let byteCount = text.utf8.count
        if byteCount < minBytes { return .drop(.tooShort) }
        if byteCount > maxBytes { return .drop(.tooLong) }

        // G7 before anything else looks at content. Fail-closed: a missing
        // scanner corpus rejects the candidate rather than letting it through.
        if case .allow = MemorySecretPIIGate.evaluate(text, policy: .reject) {
            // clean — continue
        } else {
            return .drop(.secretPII)
        }

        if isJunk(text) {
            return .drop(.junk)
        }

        let salience = salienceHint(for: text, role: role, input: input, policy: policy)
        guard salience >= policy.thresholds.accept else {
            return .drop(.noDurableSignal)
        }
        return .accept(salienceHint: min(1.0, salience))
    }

    // MARK: - Salience heuristics

    private static let questionPrefixes = [
        "how ", "what ", "why ", "when ", "where ", "who ", "which ",
        "can i ", "could i ", "should i ", "is there ", "do i ", "does "
    ]

    private static let correctionMarkers = [
        "no, i meant", "no i meant", "actually,", "actually ", "i meant",
        "not that", "that's wrong", "thats wrong", "i said", "instead of"
    ]

    private static let firstPersonDurableMarkers = [
        "i prefer", "i use", "i always", "i never", "i want", "i work",
        "we use", "we prefer", "our team", "my project", "my setup", "my "
    ]

    private static func salienceHint(
        for text: String,
        role: String,
        input: Input,
        policy: UsageMemoryCurationPolicy
    ) -> Double {
        let weights = policy.salience
        let lowered = text.lowercased()
        var score = 0.0

        if role == "workflow" {
            score += weights.toolWorkflow
        }
        if lowered.hasSuffix("?") || questionPrefixes.contains(where: { lowered.hasPrefix($0) }) {
            score += weights.questionShape
        }
        if correctionMarkers.contains(where: { lowered.contains($0) }) {
            score += weights.correction
        }
        if firstPersonDurableMarkers.contains(where: { lowered.contains($0) }) {
            score += weights.firstPersonDurable
        }
        if input.repetitionCount > 0 {
            score += min(
                weights.repetitionCap,
                Double(input.repetitionCount) * weights.repetitionPerHit
            )
        }
        return score
    }

    // MARK: - Junk filters

    /// Ephemeral/no-signal shapes: URL-only lines, symbol soup, long
    /// base64/hex runs (already G7-scanned, but unkeyed blobs still carry no
    /// durable fact worth a model call).
    private static func isJunk(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://"),
           lowered.rangeOfCharacter(from: .whitespacesAndNewlines) == nil {
            return true
        }

        var alphanumerics = 0
        var total = 0
        var longestOpaqueRun = 0
        var currentOpaqueRun = 0
        for character in text {
            total += 1
            if character.isLetter || character.isNumber {
                alphanumerics += 1
            }
            let isOpaque = character.isLetter || character.isNumber
                || character == "+" || character == "/" || character == "="
            if isOpaque, character.isWhitespace == false {
                currentOpaqueRun += 1
                longestOpaqueRun = max(longestOpaqueRun, currentOpaqueRun)
            } else {
                currentOpaqueRun = 0
            }
        }
        guard total > 0 else { return true }
        if Double(alphanumerics) / Double(total) < 0.5 { return true }
        // A single unbroken ≥64-char token is a blob/hash/base64 payload, not prose.
        if longestOpaqueRun >= 64, text.contains(" ") == false { return true }
        return false
    }
}
